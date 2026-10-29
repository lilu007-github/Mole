import AppKit
import Foundation

/// One app `mo slim --dry-run` lists: its name (the .app file name, cut with
/// "..." when long) and the Intel code it would remove.
struct SlimApp: Identifiable, Hashable {
    var name: String
    var size: String
    var id: String { name }

    var isTruncated: Bool { name.hasSuffix("...") }

    /// Mole only looks directly in these two folders and names apps by file name.
    static let roots = ["/Applications", NSHomeDirectory() + "/Applications"]

    /// The bundle this row names, when exactly one folder has it.
    var url: URL? {
        guard !isTruncated else { return nil }
        let matches = Self.roots.map { URL(fileURLWithPath: "\($0)/\(name).app") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Rows are "  <name padded>  <size>"; the summary "15 apps, 2.06GB of Intel code" ends the list.
    static func parse(_ lines: [String]) -> [SlimApp] {
        var apps: [SlimApp] = []
        for line in lines {
            if line.firstMatch(of: #/^\d+ apps?, .+ of Intel code$/#) != nil { break }
            guard line.hasPrefix("  "),
                  let row = line.firstMatch(of: #/^  (.*\S)\s+(\d+(?:\.\d+)?(?:B|KB|MB|GB|TB))$/#)
            else { continue }
            apps.append(SlimApp(name: String(row.1), size: String(row.2)))
        }
        return apps
    }

    static func summary(_ lines: [String]) -> String? {
        lines.last { $0.firstMatch(of: #/^\d+ apps?, .+ of Intel code$/#) != nil }
    }

    /// Mole compares names cut to 36 columns; "Long Name..." stands for any name with that prefix.
    static func matches(_ menuName: String, _ fullName: String) -> Bool {
        menuName.hasSuffix("...") ? fullName.hasPrefix(String(menuName.dropLast(3))) : menuName == fullName
    }
}

/// Drives the real `mo slim` menu so it holds exactly the chosen apps, then lets
/// Mole print its own "Apps to slim" list and checks it before the user confirms.
enum SlimMenuDriver {
    static let columns = 110

    @MainActor
    static func select(_ chosen: Set<String>, among listed: [SlimApp], in session: TerminalSession,
                       progress: @escaping (String) -> Void) async -> String? {
        func quit(_ problem: String) -> String {
            session.send("q")
            return problem
        }
        // Rows are told apart by name only, so two rows with one name cannot be chosen safely.
        let names = listed.map(\.name)
        guard Set(names).count == names.count else {
            return "有两个 App 在 Mole 的列表里同名，Burrow 无法区分它们。请在终端运行 mo slim。"
        }

        guard await wait(in: session, seconds: 180, until: { frame($0) != nil }) else {
            if session.allLines.contains(where: { $0.contains("No apps with Intel code") }) {
                return "Mole 没有找到可以精简的 App。"
            }
            if session.allLines.contains(where: { $0.contains("needs an Apple Silicon Mac") }) {
                return "精简只适用于 Apple 芯片的 Mac。"
            }
            return quit("没有等到 Mole 的选择菜单。")
        }
        guard let first = frame(session.allLines), first.selected == 0 else {
            return quit("Mole 的菜单默认已有选中项，和预期不一致，已取消。")
        }

        var found = Set<String>()
        var previous: String?
        for index in 1...max(first.total, 1) {
            guard let current = frame(session.allLines), current.cursorName != previous else {
                return quit("菜单位置和预期不一致，已取消。")
            }
            progress("正在 Mole 菜单中选择 \(index)/\(first.total)")
            if chosen.contains(current.cursorName) {
                let before = current.selected
                session.send(" ")
                guard await wait(in: session, until: { frame($0)?.selected == before + 1 }) else {
                    return quit("选择 \(current.cursorName) 失败。")
                }
                found.insert(current.cursorName)
            }
            previous = current.cursorName
            if index < first.total {
                session.send("\u{1b}[B")
                guard await wait(in: session, until: { frame($0).map { $0.cursorName != previous } ?? false }) else {
                    return quit("菜单没有响应，已取消。")
                }
            }
        }
        guard found == chosen else {
            let missing = chosen.subtracting(found).sorted()
            return quit("Mole 的菜单里找不到：\(missing.joined(separator: "、"))。列表可能已经变化，请重新扫描。")
        }

        // Enter prints Mole's own "Apps to slim" list before its confirmation.
        session.send("\r")
        guard await wait(in: session, seconds: 60, until: { lines in
            lines.last.map { $0.contains(PromptBar.confirmMarker) } ?? false
        }) else { return "Mole 没有显示确认提示。" }
        let confirmed = confirmedNames(session.allLines)
        let agrees = confirmed.count == chosen.count
            && chosen.allSatisfy { menuName in confirmed.contains { SlimApp.matches(menuName, $0) } }
        guard agrees else {
            session.send("\u{1b}")
            return "Mole 列出的 App 和你的选择不一致，已取消，没有改动任何 App。"
        }
        return nil
    }

    struct Frame: Equatable {
        var cursorName: String
        var total: Int
        var selected: Int
    }

    /// A fully drawn menu: "Select apps to slim  N/M selected", a "➤" row, and the key legend
    /// (drawn last, so a frame without it is still being drawn).
    static func frame(_ lines: [String]) -> Frame? {
        guard lines.contains(where: { $0.contains("Select apps to slim") }),
              lines.contains(where: { $0.contains("Space Select") }),
              let count = lines.lazy.compactMap({ $0.firstMatch(of: #/\b(\d+)/(\d+) selected\s*$/#) }).first,
              let selected = Int(count.1), let total = Int(count.2),
              let cursor = lines.lazy.compactMap({ $0.firstMatch(of: #/^➤ [○●] (.*\S)\s+\S+\s*$/#) }).first
        else { return nil }
        return Frame(cursorName: String(cursor.1), total: total, selected: selected)
    }

    /// Names in Mole's "Apps to slim:" list, rows "◎ Name , 578.4MB", with " [Running]" after an open app.
    static func confirmedNames(_ lines: [String]) -> [String] {
        guard let start = lines.lastIndex(where: { $0.hasPrefix("Apps to slim:") }) else { return [] }
        var names: [String] = []
        for line in lines[(start + 1)...] {
            guard let row = line.firstMatch(of: #/^◎ (.*?)\s*, \S+(?: \[Running\])?\s*$/#) else { break }
            names.append(String(row.1))
        }
        return names
    }

    @MainActor
    private static func wait(in session: TerminalSession, seconds: Double = 10,
                             until condition: ([String]) -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition(session.allLines) { return true }
            if !session.isRunning, session.exitCode != nil { return condition(session.allLines) }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return false
    }
}
