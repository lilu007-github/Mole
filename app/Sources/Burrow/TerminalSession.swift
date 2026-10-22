import Foundation
import Observation

/// Runs a long `mo` command and turns its terminal output into plain lines.
///
/// `usePTY` runs the command under `/usr/bin/script`, which gives it a real
/// pseudo-terminal. `mo uninstall` only accepts a confirmation from a terminal,
/// so Burrow shows the plan that very process printed and forwards a key only
/// when the user clicks a button. Nothing is ever answered automatically.
@MainActor
@Observable
final class TerminalSession {
    private(set) var lines: [String] = []
    private(set) var currentLine = ""
    private(set) var isRunning = false
    private(set) var exitCode: Int32?
    /// Count of lines ever completed. Unlike `lines.count` it never goes down
    /// when the screen is redrawn, so prompts can tell "new" from "answered".
    private(set) var lineSerial = 0
    /// Every completed line in order, never cleared by screen redraws. Menus
    /// that repaint in place are followed through this, not through `lines`.
    private(set) var transcript: [String] = []

    private var process: Process?
    private var inputPipe: Pipe?
    private var parser = TerminalTextParser()
    private var pendingBytes = Data()

    /// Every line including the one still being written.
    var allLines: [String] {
        currentLine.isEmpty ? lines : lines + [currentLine]
    }

    /// - Parameter columns: terminal width; wider for menus that shorten long paths.
    func start(_ arguments: [String], usePTY: Bool, columns: Int = MoleCLI.terminalColumns) {
        guard !isRunning, let mo = MoleCLI.executableURL else { return }
        lines = []
        currentLine = ""
        exitCode = nil
        lineSerial = 0
        transcript = []
        parser = TerminalTextParser()
        pendingBytes = Data()

        let process = Process()
        if usePTY {
            // A fixed window size keeps Mole's column layout stable.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            process.arguments = ["-q", "/dev/null", "/bin/bash", "-c",
                                 "stty cols \(columns) rows \(MoleCLI.terminalRows) 2>/dev/null; exec \"$0\" \"$@\"",
                                 mo.path] + arguments
        } else {
            process.executableURL = mo
            process.arguments = arguments
        }
        var environment = MoleCLI.environment
        environment["COLUMNS"] = String(columns)
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        process.standardInput = usePTY ? input : FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        inputPipe = usePTY ? input : nil

        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            // DispatchQueue.main keeps chunks in order; unstructured Tasks would not.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.consume(data) }
            }
        }
        process.terminationHandler = { proc in
            let code = proc.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    output.fileHandleForReading.readabilityHandler = nil
                    self.consume(output.fileHandleForReading.readDataToEndOfFile())
                    self.isRunning = false
                    self.exitCode = code
                    self.process = nil
                    self.inputPipe = nil
                }
            }
        }

        do {
            try process.run()
            self.process = process
            isRunning = true
        } catch {
            lines = ["无法启动 mo：\(error.localizedDescription)"]
            exitCode = -1
        }
    }

    /// Sends raw keys to the PTY, e.g. "\r" for Enter or "\u{1b}" for ESC.
    func send(_ keys: String) {
        guard let pipe = inputPipe else { return }
        pipe.fileHandleForWriting.write(Data(keys.utf8))
    }

    func terminate() {
        process?.interrupt()
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        pendingBytes.append(data)
        // Hold back a trailing partial UTF-8 sequence until the next chunk.
        let cut = pendingBytes.count - TerminalTextParser.incompleteUTF8Suffix(pendingBytes)
        let text = String(decoding: pendingBytes.prefix(cut), as: UTF8.self)
        pendingBytes = Data(pendingBytes.suffix(from: pendingBytes.startIndex + cut))
        parser.feed(text, lines: &lines, current: &currentLine)
        lineSerial = parser.committed
        transcript += parser.drainCommitted()
        if transcript.count > 20000 { transcript.removeFirst(transcript.count - 20000) }
        if lines.count > 4000 { lines.removeFirst(lines.count - 4000) }
    }
}

/// A small VT100 subset: enough to replay Mole's spinners, line clears and
/// colors as plain text. Colors and cursor visibility are dropped.
struct TerminalTextParser {
    private enum State { case normal, escape, csi, osc, charset }
    private var state = State.normal
    private var params = ""
    private var pendingCR = false
    private(set) var committed = 0
    private var committedLines: [String] = []

    /// Lines completed since the last call.
    mutating func drainCommitted() -> [String] {
        defer { committedLines = [] }
        return committedLines
    }

    private mutating func commit(_ line: String, into lines: inout [String]) {
        lines.append(line)
        committedLines.append(line)
        committed += 1
    }

    mutating func feed(_ text: String, lines: inout [String], current: inout String) {
        for ch in text.unicodeScalars {
            switch state {
            case .normal:
                if pendingCR {
                    pendingCR = false
                    if ch == "\n" {
                        commit(current, into: &lines)
                        current = ""
                        continue
                    }
                    current = "" // bare \r: the next text overwrites the line
                }
                switch ch {
                case "\u{1b}": state = .escape
                case "\r": pendingCR = true
                case "\n":
                    commit(current, into: &lines)
                    current = ""
                case "\u{8}": if !current.isEmpty { current.removeLast() }
                case "\t": current.append("    ")
                default:
                    if ch.value >= 0x20 { current.unicodeScalars.append(ch) }
                }
            case .escape:
                switch ch {
                case "[": state = .csi; params = ""
                case "]": state = .osc
                case "(", ")": state = .charset
                default: state = .normal
                }
            case .charset:
                state = .normal
            case .osc:
                if ch == "\u{7}" { state = .normal }
                else if ch == "\u{1b}" { state = .escape }
            case .csi:
                if (0x40...0x7E).contains(ch.value) {
                    apply(final: ch, lines: &lines, current: &current)
                    state = .normal
                } else {
                    params.unicodeScalars.append(ch)
                }
            }
        }
    }

    private func apply(final: Unicode.Scalar, lines: inout [String], current: inout String) {
        switch final {
        case "K": current = ""
        case "J" where params == "2": lines.removeAll(); current = ""
        // Cursor home: full-screen menus redraw from the top, so start a fresh screen.
        case "H" where params.isEmpty || params == "1;1": lines.removeAll(); current = ""
        case "A":
            // Cursor up: Mole only uses it to redraw the previous line.
            let count = Int(params) ?? 1
            for _ in 0..<count where !lines.isEmpty { current = lines.removeLast() }
        default: break
        }
    }

    /// Number of bytes at the end of `data` that start an unfinished UTF-8 character.
    static func incompleteUTF8Suffix(_ data: Data) -> Int {
        let bytes = [UInt8](data.suffix(3))
        for (offset, byte) in bytes.reversed().enumerated() {
            let length = offset + 1
            if byte & 0b1100_0000 == 0b1000_0000 { continue } // continuation byte
            let needed: Int
            if byte & 0b1110_0000 == 0b1100_0000 { needed = 2 }
            else if byte & 0b1111_0000 == 0b1110_0000 { needed = 3 }
            else if byte & 0b1111_1000 == 0b1111_0000 { needed = 4 }
            else { return 0 }
            return needed > length ? length : 0
        }
        return 0
    }
}
