import Foundation

/// Old-conversation scanning and trashing, entirely inside a fixture home:
/// the real ~/.claude, ~/.codex and Trash are never touched.
@MainActor
enum AIChecks {
    static let fm = FileManager.default
    static let old = Date(timeIntervalSinceNow: -200 * 86400)

    static func register() {
        Checks.add("ai", "scan lists sessions with titles and never memory/") {
            let home = makeFixtureHome()
            AISessionScanner.home = home.path
            defer { AISessionScanner.home = NSHomeDirectory() }

            let sessions = AISessionScanner.scan(olderThan: Date(timeIntervalSinceNow: -30 * 86400))
            let claude = sessions.filter { $0.tool == .claudeCode }
            let codex = sessions.filter { $0.tool == .codex }
            expect(claude.count == 1, "old claude sessions: \(claude.map(\.title))")
            expect(claude.first?.title == "Refactor the parser", "summary wins: \(claude.first?.title ?? "")")
            expect(claude.first?.project == "demo-app", "project from cwd: \(claude.first?.project ?? "")")
            expect(claude.first?.companions.count == 1, "companion folder")
            expect(codex.count == 2, "codex: \(codex.map(\.title))")
            expect(codex.contains { $0.title == "Plan the migration" }, "title from session_index")
            expect(codex.contains { $0.project == "已归档" }, "archived .zst")
            expect(!sessions.contains { $0.file.path.contains("/memory/") }, "memory never listed")
            expect(!sessions.contains { $0.title == "Fresh work" }, "recent session excluded")
        }

        Checks.add("ai", "trash moves only verified old sessions and logs them") {
            let home = makeFixtureHome()
            AISessionScanner.home = home.path
            let trashDir = home.appendingPathComponent("FakeTrash")
            try fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
            AISessionTrash.mover = { url in
                try fm.moveItem(at: url, to: trashDir.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
            }
            let log = home.appendingPathComponent("Library/Logs/mole/operations.log")
            OperationLog.fileURL = log
            defer {
                AISessionScanner.home = NSHomeDirectory()
                AISessionTrash.mover = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
                OperationLog.fileURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/mole/operations.log")
            }

            let cutoff = Date(timeIntervalSinceNow: -30 * 86400)
            var sessions = AISessionScanner.scan(olderThan: cutoff)
            let claude = try require(sessions.first { $0.tool == .claudeCode })
            let codex = try require(sessions.first { $0.tool == .codex && $0.project != "已归档" })

            // Resumed after the scan: must be kept.
            try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: codex.file.path)
            // A forged session outside its root and one whose companion became a symlink.
            let outside = home.appendingPathComponent("outside.jsonl")
            try Data().write(to: outside)
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: outside.path)
            sessions.append(AISession(tool: .claudeCode, file: outside, companions: [], project: "x", title: "x",
                                      modified: old, size: 0, root: AISessionScanner.claudeRoot))

            let outcome = AISessionTrash.trash([claude, codex] + sessions.suffix(1), cutoff: cutoff)
            expect(outcome.moved.map(\.id) == [claude.id], "moved: \(outcome.moved.map(\.title))")
            expect(!fm.fileExists(atPath: claude.file.path) && !fm.fileExists(atPath: claude.companions[0].path),
                   "claude transcript and folder moved")
            expect(fm.fileExists(atPath: codex.file.path), "resumed codex session kept")
            expect(fm.fileExists(atPath: outside.path), "outside file kept")
            expect(fm.fileExists(atPath: AISessionScanner.claudeRoot.appendingPathComponent("-demo-app/memory/MEMORY.md").path),
                   "memory intact")
            expect((try fm.contentsOfDirectory(atPath: trashDir.path)).count == 2, "two items in fake trash")

            let text = try String(contentsOf: log, encoding: .utf8)
            expect(text.contains("burrow-ai run=") && text.contains("session started at"), "session start")
            expect(text.components(separatedBy: "] TRASHED ").count - 1 == 2, "two TRASHED rows")
            expect(text.contains("(recently modified)") && text.contains("(outside root)"), "English skip reasons")
            expect(text.contains("session ended at") && text.contains(", 1 items, "), "session end")

            // Mole's own history reader must understand these rows.
            guard let mole = MoleCLI.executableURL else { throw Checks.Skip(reason: "no mo") }
            let history = try runProcess(mole.path, ["history", "--json"], env: ["HOME": home.path])
            let json = try JSONSerialization.jsonObject(with: history) as? [String: Any]
            let first = (json?["sessions"] as? [[String: Any]])?.first
            let actions = first?["actions"] as? [String: Int]
            expect(first?["command"] as? String == "burrow-ai", "history command: \(first ?? [:])")
            expect(actions?["trashed"] == 2 && actions?["skipped"] == 2, "history actions: \(actions ?? [:])")
        }

        Checks.add("ai", "a symlinked companion folder is refused") {
            let home = makeFixtureHome()
            let project = home.appendingPathComponent(".claude/projects/-demo-app")
            let id = UUID().uuidString
            let file = project.appendingPathComponent("\(id).jsonl")
            try Data("{}\n".utf8).write(to: file)
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
            let link = project.appendingPathComponent(id)
            try fm.createSymbolicLink(at: link, withDestinationURL: project.appendingPathComponent("memory"))
            var moved: [URL] = []
            AISessionTrash.mover = { moved.append($0) }
            OperationLog.fileURL = home.appendingPathComponent("operations.log")
            defer {
                AISessionTrash.mover = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
                OperationLog.fileURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/mole/operations.log")
            }
            let session = AISession(tool: .claudeCode, file: file, companions: [link], project: "demo", title: "t",
                                    modified: old, size: 0, root: home.appendingPathComponent(".claude/projects"))
            let outcome = AISessionTrash.trash([session], cutoff: Date(timeIntervalSinceNow: -30 * 86400))
            expect(outcome.moved.isEmpty && moved.isEmpty, "nothing moved")
            expect(outcome.skipped.first?.reason == "关联文件夹已变化", "\(outcome.skipped.map(\.reason))")
        }
    }

    /// ~/.claude/projects/-demo-app with one old session (+ folder), one recent
    /// session and memory/; ~/.codex with a dated session, an archived one and an index.
    static func makeFixtureHome() -> URL {
        let home = makeFixtureDir("home-\(UUID().uuidString.prefix(8))")
        let project = home.appendingPathComponent(".claude/projects/-demo-app")
        try! fm.createDirectory(at: project.appendingPathComponent("memory"), withIntermediateDirectories: true)
        try! Data("remember".utf8).write(to: project.appendingPathComponent("memory/MEMORY.md"))
        try! fm.setAttributes([.modificationDate: old], ofItemAtPath: project.appendingPathComponent("memory/MEMORY.md").path)

        let oldID = UUID().uuidString
        write(project.appendingPathComponent("\(oldID).jsonl"), lines: [
            #"{"type":"user","cwd":"/Users/me/demo-app","message":{"role":"user","content":"please refactor"}}"#,
            #"{"type":"summary","summary":"Refactor the parser"}"#,
        ], date: old)
        let folder = project.appendingPathComponent("\(oldID)/subagents")
        try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
        write(folder.appendingPathComponent("agent.jsonl"), lines: ["{}"], date: old)
        for url in [folder, folder.deletingLastPathComponent()] {
            try! fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        write(project.appendingPathComponent("\(UUID().uuidString).jsonl"), lines: [
            #"{"type":"user","cwd":"/Users/me/demo-app","message":{"role":"user","content":"Fresh work"}}"#,
        ], date: Date())

        let codexID = "019c635d-9bc4-7520-996d-7903839d1383"
        let day = home.appendingPathComponent(".codex/sessions/2026/01/02")
        try! fm.createDirectory(at: day, withIntermediateDirectories: true)
        write(day.appendingPathComponent("rollout-2026-01-02T10-00-00-\(codexID).jsonl"), lines: [
            #"{"type":"session_meta","payload":{"id":"\#(codexID)","cwd":"/Users/me/service"}}"#,
        ], date: old)
        let archived = home.appendingPathComponent(".codex/archived_sessions")
        try! fm.createDirectory(at: archived, withIntermediateDirectories: true)
        write(archived.appendingPathComponent("rollout-2025-12-01T09-00-00-019b0000-0000-7000-8000-000000000000.jsonl.zst"),
              lines: ["binary"], date: old)
        write(home.appendingPathComponent(".codex/session_index.jsonl"), lines: [
            #"{"id":"\#(codexID)","thread_name":"Plan the migration","updated_at":"2026-01-02T10:00:00Z"}"#,
        ], date: old)
        return home
    }

    static func write(_ url: URL, lines: [String], date: Date) {
        try! Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        try! fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}

struct Missing: Error {}

func require<T>(_ value: T?) throws -> T {
    guard let value else { throw Missing() }
    return value
}

/// Runs a command to completion and returns stdout.
func runProcess(_ path: String, _ arguments: [String], env: [String: String] = [:]) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.environment = MoleCLI.environment.merging(env) { $1 }
    process.standardInput = FileHandle.nullDevice
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return data
}
