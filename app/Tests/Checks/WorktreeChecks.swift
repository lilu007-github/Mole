import Foundation

@MainActor
enum WorktreeChecks {
    static func register() {
        Checks.add("ai", "agent worktrees are found and their blockers reported") {
            let root = makeFixtureDir("wt").resolvingSymlinksInPath()
            let repo = root.appendingPathComponent("projects/demo")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            func git(_ args: [String], in dir: URL) throws {
                _ = try runProcess("/usr/bin/git", ["-C", dir.path, "-c", "user.name=t", "-c", "user.email=t@t"] + args)
            }
            try git(["init", "-q", "-b", "main"], in: repo)
            try Data("a".utf8).write(to: repo.appendingPathComponent("a.txt"))
            try git(["add", "."], in: repo)
            try git(["commit", "-q", "-m", "init"], in: repo)
            try git(["worktree", "add", "-q", ".claude/worktrees/agent-1", "-b", "agent-1"], in: repo)
            let tree = repo.appendingPathComponent(".claude/worktrees/agent-1")
            try Data("dirty".utf8).write(to: tree.appendingPathComponent("new.txt"))

            let saved = PurgePaths.fileURL
            PurgePaths.fileURL = root.appendingPathComponent("purge_paths")
            defer { PurgePaths.fileURL = saved }
            try (root.appendingPathComponent("projects").path + "\n").write(to: PurgePaths.fileURL, atomically: true, encoding: .utf8)

            let found = AIWorktrees.scan().filter { $0.path.hasPrefix(root.path) }
            expect(found.count == 1 && found.first?.path == tree.path, "\(found.map(\.path))")
            expect(found.first?.branch == "agent-1" && found.first?.tool == "Claude Code", "\(String(describing: found.first))")
            expect(found.first?.uncommitted == 1 && found.first?.unpushed == nil, "dirty, no upstream")
            expect(found.first?.blockers.count == 2, "\(found.first?.blockers ?? [])")
            expect(found.first?.removeCommand == "git worktree remove \"\(tree.path)\"", "command")
        }
    }
}
