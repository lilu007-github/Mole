import Foundation

// MARK: - Inventory (read-only)

/// A folder an AI tool keeps on disk. Burrow only measures these.
struct AILocation: Identifiable, Hashable {
    enum Kind: String {
        case conversations = "对话记录"
        case models = "本地模型"
        case versions = "旧版本与程序"
        case appData = "应用数据"
    }

    let tool: String
    let kind: Kind
    let path: String
    /// What happens to this folder elsewhere, e.g. which parts `mo clean` handles.
    let note: String
    var id: String { path }

    static let all: [AILocation] = {
        let home = NSHomeDirectory()
        let support = home + "/Library/Application Support"
        return [
            AILocation(tool: "Claude Code", kind: .conversations, path: home + "/.claude/projects",
                       note: "可在下方按天数清理旧对话；memory 文件夹始终保留"),
            AILocation(tool: "Claude Code", kind: .versions, path: home + "/.local/share/claude/versions",
                       note: "mo clean 会保留当前和上一个版本，清理更早的"),
            AILocation(tool: "Claude 桌面版", kind: .appData, path: support + "/Claude",
                       note: "mo clean 会清理其中的缓存、日志和内置旧版本"),
            AILocation(tool: "Codex", kind: .conversations, path: home + "/.codex/sessions",
                       note: "可在下方按天数清理旧对话"),
            AILocation(tool: "Codex", kind: .conversations, path: home + "/.codex/archived_sessions",
                       note: "已归档的对话（压缩保存）"),
            AILocation(tool: "ChatGPT", kind: .appData, path: support + "/com.openai.chat",
                       note: "桌面版数据，请在 App 内管理对话"),
            AILocation(tool: "Cursor", kind: .appData, path: support + "/Cursor",
                       note: "mo clean 会清理其中的缓存"),
            AILocation(tool: "Cursor", kind: .appData, path: home + "/.cursor", note: "扩展与配置"),
            AILocation(tool: "Gemini CLI", kind: .appData, path: home + "/.gemini", note: "配置与对话"),
            AILocation(tool: "Kiro", kind: .appData, path: support + "/Kiro", note: "mo clean 会清理其中的缓存"),
            AILocation(tool: "Ollama", kind: .models, path: home + "/.ollama/models",
                       note: "受 Mole 保护；删除模型请用 ollama rm"),
            AILocation(tool: "Hugging Face", kind: .models, path: home + "/.cache/huggingface",
                       note: "下载的模型和数据集"),
            AILocation(tool: "LM Studio", kind: .models, path: home + "/.lmstudio/models",
                       note: "请在 LM Studio 内删除模型"),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
    }()

    /// Allocated size in bytes via /usr/bin/du, or nil when it cannot finish in time.
    static func measure(_ path: String) async -> Int64? {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
            process.arguments = ["-sk", path]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let killer = DispatchWorkItem { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: killer)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            killer.cancel()
            // du exits 1 after unreadable entries but still prints what it could count.
            let field = String(decoding: data, as: UTF8.self).split(separator: "\t").first
            return field.flatMap { Int64($0) }.map { $0 * 1024 }
        }.value
    }
}

// MARK: - Conversations

struct AISession: Identifiable, Hashable {
    enum Tool: String { case claudeCode = "Claude Code", codex = "Codex" }

    let tool: Tool
    /// The transcript file.
    let file: URL
    /// Files that belong to the same conversation (Claude Code's per-session folder).
    let companions: [URL]
    let project: String
    let title: String
    let modified: Date
    let size: Int64
    /// The folder the transcript must stay inside.
    let root: URL

    var id: String { file.path }
}

enum AISessionScanner {
    static var claudeRoot: URL { URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects") }
    static var codexRoots: [URL] {
        ["/.codex/sessions", "/.codex/archived_sessions"].map { URL(fileURLWithPath: NSHomeDirectory() + $0) }
    }

    /// Conversations whose transcript and companions were all last modified before `cutoff`.
    static func scan(olderThan cutoff: Date) -> [AISession] {
        (claudeSessions() + codexSessions())
            .filter { $0.modified < cutoff }
            .sorted { $0.modified < $1.modified }
    }

    // ~/.claude/projects/<project>/<uuid>.jsonl plus an optional <uuid>/ folder.
    // Everything else there (notably memory/) is never listed.
    private static func claudeSessions() -> [AISession] {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(at: claudeRoot, includingPropertiesForKeys: nil) else {
            return []
        }
        var sessions: [AISession] = []
        for project in projects where isRealDirectory(project) {
            guard let items = try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: nil) else { continue }
            for file in items where file.pathExtension == "jsonl" && isRegularFile(file) {
                let stem = file.deletingPathExtension().lastPathComponent
                guard UUID(uuidString: stem) != nil else { continue }
                var companions: [URL] = []
                let folder = project.appendingPathComponent(stem)
                if isRealDirectory(folder) { companions.append(folder) }
                let info = claudeInfo(file)
                sessions.append(AISession(
                    tool: .claudeCode, file: file, companions: companions,
                    project: info.project ?? project.lastPathComponent,
                    title: info.title ?? "（无标题）",
                    modified: newestModification([file] + companions),
                    size: allocatedSize([file] + companions),
                    root: claudeRoot))
            }
        }
        return sessions
    }

    // ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl and archived_sessions/*.jsonl(.zst).
    private static func codexSessions() -> [AISession] {
        let titles = codexTitles()
        var sessions: [AISession] = []
        for root in codexRoots {
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in walker {
                let name = file.lastPathComponent
                guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst"),
                      isRegularFile(file) else { continue }
                let compressed = name.hasSuffix(".zst")
                let info = compressed ? (project: nil, id: nil, title: nil) : codexInfo(file)
                let id = info.id ?? codexID(fromName: name)
                sessions.append(AISession(
                    tool: .codex, file: file, companions: [],
                    project: info.project.map { $0.hasPrefix("g-p-") ? "ChatGPT 项目" : $0 }
                        ?? (compressed ? "已归档" : "—"),
                    title: id.flatMap { titles[$0] } ?? info.title ?? "（无标题）",
                    modified: newestModification([file]),
                    size: allocatedSize([file]),
                    root: root))
            }
        }
        return sessions
    }

    // MARK: Reading titles (first 256 KB only)

    private static func jsonLines(_ file: URL, limit: Int = 256 * 1024) -> [[String: Any]] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: limit)) ?? Data()
        return data.split(separator: UInt8(ascii: "\n")).prefix(200).compactMap {
            try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
        }
    }

    private static func claudeInfo(_ file: URL) -> (project: String?, title: String?) {
        var project: String?
        var summary: String?
        var firstPrompt: String?
        for line in jsonLines(file) {
            if project == nil, let cwd = line["cwd"] as? String { project = (cwd as NSString).lastPathComponent }
            if summary == nil, line["type"] as? String == "summary" { summary = line["summary"] as? String }
            if firstPrompt == nil, line["type"] as? String == "user",
               let message = line["message"] as? [String: Any] {
                firstPrompt = promptText(message["content"])
            }
            if project != nil, summary != nil { break }
        }
        return (project, (summary ?? firstPrompt).map(oneLine))
    }

    private static func codexInfo(_ file: URL) -> (project: String?, id: String?, title: String?) {
        var project: String?
        var id: String?
        var firstPrompt: String?
        for line in jsonLines(file) {
            guard let payload = line["payload"] as? [String: Any] else { continue }
            if line["type"] as? String == "session_meta" {
                id = payload["id"] as? String
                project = (payload["cwd"] as? String).map { ($0 as NSString).lastPathComponent }
            }
            if firstPrompt == nil, payload["type"] as? String == "user_message" {
                firstPrompt = payload["message"] as? String
            }
            if id != nil, firstPrompt != nil { break }
        }
        return (project, id, firstPrompt.map(oneLine))
    }

    /// id → thread name from ~/.codex/session_index.jsonl.
    private static func codexTitles() -> [String: String] {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/.codex/session_index.jsonl")
        var titles: [String: String] = [:]
        for line in jsonLines(url, limit: 4 * 1024 * 1024) {
            if let id = line["id"] as? String, let name = line["thread_name"] as? String { titles[id] = name }
        }
        return titles
    }

    /// "rollout-2026-10-21T10-36-20-<uuid>.jsonl" → "<uuid>".
    private static func codexID(fromName name: String) -> String? {
        let stem = name.replacingOccurrences(of: ".jsonl.zst", with: "").replacingOccurrences(of: ".jsonl", with: "")
        let parts = stem.split(separator: "-")
        guard parts.count >= 5 else { return nil }
        return parts.suffix(5).joined(separator: "-")
    }

    private static func promptText(_ content: Any?) -> String? {
        if let text = content as? String { return text.hasPrefix("<") ? nil : text }
        if let blocks = content as? [[String: Any]] {
            return blocks.lazy.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .first { !$0.hasPrefix("<") }
        }
        return nil
    }

    private static func oneLine(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count > 120 ? String(flat.prefix(120)) + "…" : flat
    }

    // MARK: File facts

    static func isRegularFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true
    }

    static func isRealDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    /// Latest modification time of the items and everything inside them.
    static func newestModification(_ urls: [URL]) -> Date {
        var newest = Date.distantPast
        for url in urls {
            for item in [url] + descendants(url) {
                if let date = try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   date > newest { newest = date }
            }
        }
        return newest
    }

    static func allocatedSize(_ urls: [URL]) -> Int64 {
        var total: Int64 = 0
        for url in urls {
            for item in [url] + descendants(url) {
                let size = try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize
                total += Int64(size ?? 0)
            }
        }
        return total
    }

    private static func descendants(_ url: URL) -> [URL] {
        guard isRealDirectory(url),
              let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }
    }
}

// MARK: - Moving to Trash

/// The one place Burrow removes files itself: old AI conversations the user
/// ticked, moved to the Trash (recoverable) and logged in Mole's format.
enum AISessionTrash {
    struct Outcome {
        var moved: [AISession] = []
        var skipped: [(session: AISession, reason: String)] = []
        var freed: Int64 { moved.reduce(0) { $0 + $1.size } }
    }

    static func trash(_ sessions: [AISession], cutoff: Date) -> Outcome {
        var outcome = Outcome()
        let log = OperationLog(command: "burrow-ai")
        log.sessionStarted()
        var movedKB: Int64 = 0
        for session in sessions {
            if let reason = refusal(for: session, cutoff: cutoff) {
                outcome.skipped.append((session, reason.shown))
                log.entry("SKIPPED", session.file.path, detail: reason.logged)
                continue
            }
            var failed: String?
            for url in [session.file] + session.companions {
                let kb = AISessionScanner.allocatedSize([url]) / 1024
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    log.entry("TRASHED", url.path, detail: "\(kb)KB")
                    movedKB += kb
                } catch {
                    failed = error.localizedDescription
                    log.entry("FAILED", url.path, detail: "trash failed")
                    break
                }
            }
            if let failed { outcome.skipped.append((session, failed)) } else { outcome.moved.append(session) }
        }
        log.sessionEnded(items: outcome.moved.count, sizeKB: movedKB)
        return outcome
    }

    /// Why a session is kept: Chinese for the UI, fixed English reasons for the
    /// log, which Mole's own tools parse.
    private struct Refusal {
        let shown: String
        let logged: String
    }

    /// Rechecks right before moving: still a plain file inside its root, the
    /// companion folder is a real folder named after it, and nothing in it
    /// changed since the cutoff (a resumed conversation is no longer old).
    private static func refusal(for session: AISession, cutoff: Date) -> Refusal? {
        let root = session.root.resolvingSymlinksInPath().path + "/"
        let parent = session.file.deletingLastPathComponent().resolvingSymlinksInPath().path + "/"
        guard parent.hasPrefix(root) else { return Refusal(shown: "不在预期的文件夹内", logged: "outside root") }
        guard AISessionScanner.isRegularFile(session.file) else {
            return Refusal(shown: "文件已变化或不存在", logged: "not a regular file")
        }
        let stem = session.file.deletingPathExtension().lastPathComponent
        for companion in session.companions {
            guard companion.lastPathComponent == stem,
                  companion.deletingLastPathComponent() == session.file.deletingLastPathComponent(),
                  AISessionScanner.isRealDirectory(companion)
            else { return Refusal(shown: "关联文件夹已变化", logged: "companion changed") }
        }
        guard AISessionScanner.newestModification([session.file] + session.companions) < cutoff else {
            return Refusal(shown: "最近有更新，已保留", logged: "recently modified")
        }
        return nil
    }
}

/// Appends to ~/Library/Logs/mole/operations.log in the format Mole writes
/// (lib/core/log.sh), so `mo history` and Mole Mac see Burrow's changes too.
struct OperationLog {
    let command: String
    private let runID: String
    /// Mole's log; tests point this elsewhere.
    static var fileURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/mole/operations.log")
    private var url: URL { Self.fileURL }

    init(command: String) {
        self.command = command
        let digits = Self.timestamp().filter(\.isNumber)
        runID = "\(digits)-\(ProcessInfo.processInfo.processIdentifier)-\(Int.random(in: 0..<32768))-\(Int.random(in: 0..<32768))"
    }

    func sessionStarted() {
        append("\n# ========== \(command) run=\(runID) session started at \(Self.timestamp()) ==========")
    }

    func entry(_ action: String, _ path: String, detail: String) {
        append("[\(Self.timestamp())] [\(command) run=\(runID)] \(action) \(path) (\(detail))")
    }

    func sessionEnded(items: Int, sizeKB: Int64) {
        let size = sizeKB > 0 ? Format.bytes(sizeKB * 1024).replacingOccurrences(of: " ", with: "") : "0B"
        append("# ========== \(command) run=\(runID) session ended at \(Self.timestamp()), \(items) items, \(size) ==========")
    }

    private func append(_ line: String) {
        let data = Data((line + "\n").utf8)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: .now)
    }
}
