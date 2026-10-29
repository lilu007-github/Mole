import Foundation

@MainActor
enum PurgeChecks {
    static func register() {
        Checks.add("purge", "dry-run rows parse and group by project") {
            let lines = [
                "Purge Project Artifacts",
                "✓ [DRY RUN] /Users/me/code/pi-mono/node_modules, 558.3MB",
                "✓ [DRY RUN] /Users/me/code/pi-mono/packages/ai/dist, 3.5MB",
                "✓ [DRY RUN] /Users/me/code/odd, name/build, 12KB",
                "Would free approximately: 1.55GB | Items: 47",
            ]
            let rows = PurgeArtifact.parse(lines, scanPaths: ["/Users/me/code"])
            expect(rows.map(\.path) == ["/Users/me/code/pi-mono/node_modules", "/Users/me/code/pi-mono/packages/ai/dist",
                                       "/Users/me/code/odd, name/build"], "\(rows.map(\.path))")
            expect(rows.map(\.size) == ["558.3MB", "3.5MB", "12KB"], "\(rows.map(\.size))")
            expect(rows.map(\.project) == ["/Users/me/code/pi-mono", "/Users/me/code/pi-mono", "/Users/me/code/odd, name"],
                   "\(rows.map(\.project))")
        }

        Checks.add("purge", "menu frames and the confirmation list parse") {
            let frame = PurgeMenuDriver.frame([
                "Select Artifacts to Purge [12/143]", "1.55GB, 47 selected", "  ● ┌ /p   1MB | dist | 8mo",
                "Project: /p · 1MB · 1/1 selected", "Path: /p/dist", "",
                "↑↓ [] Projects / Find | Space Select | Enter Confirm | A All | I Invert | X Skip Project | Q Quit",
            ])
            expect(frame?.cursor == 12 && frame?.total == 143 && frame?.selected == 47 && frame?.path == "/p/dist",
                   "\(String(describing: frame))")
            expect(PurgeMenuDriver.frame(["Select Artifacts to Purge [1/3]", "0B, 0 selected"]) == nil,
                   "a frame without its key legend is still being drawn")
            let single = PurgeMenuDriver.frame([
                "Select Artifacts to Purge", "393KB, 4 selected  ",
                "  ● ─ /p/alpha     201KB | node_modules | 7mo", "➤ ○ ─ /p/beta      106KB | .venv | 7mo",
                "Path: /p/beta/.venv", "", "↑↓ [] Projects / Find | Space Select | Enter Confirm",
            ])
            expect(single?.cursor == 2 && single?.total == 2 && single?.selected == 4 && single?.path == "/p/beta/.venv",
                   "single page: \(String(describing: single))")
            let listed = PurgeMenuDriver.selectedPaths([
                "Selected paths:", "  /p/dist", "  ~/q/node_modules", "",
                "➤ Remove 2 items, 1MB  Enter confirm, ESC cancel: ",
            ])
            expect(listed == ["/p/dist", NSHomeDirectory() + "/q/node_modules"], "\(listed)")
        }

        Checks.add("purge", "scan paths save keeps Mole's comment header") {
            let dir = makeFixtureDir("purge-paths")
            PurgePaths.fileURL = dir.appendingPathComponent("purge_paths")
            defer { PurgePaths.fileURL = URL(fileURLWithPath: NSHomeDirectory() + "/.config/mole/purge_paths") }
            expect(PurgePaths.load() == nil, "missing file means Mole defaults")
            try "# my notes\n# keep me\n\n~/old\n".write(to: PurgePaths.fileURL, atomically: true, encoding: .utf8)
            try PurgePaths.save(["~/Developer/git", "~/Projects"])
            let text = try String(contentsOf: PurgePaths.fileURL, encoding: .utf8)
            expect(text.hasPrefix("# my notes\n# keep me\n"), text)
            expect(PurgePaths.load() == ["~/Developer/git", "~/Projects"], "\(PurgePaths.load() ?? [])")
        }

        Checks.add("purge", "driver selects exactly the chosen artifacts in Mole's menu", live: true) {
            let (home, projects) = try makeProjects()
            let previousHome = ProcessInfo.processInfo.environment["HOME"]
            setenv("HOME", home.path, 1)
            defer { setenv("HOME", previousHome ?? NSHomeDirectory(), 1) }

            let preview = try await MoleCLI.run(["purge", "--dry-run"])
            let rows = PurgeArtifact.parse(parse(String(decoding: preview, as: UTF8.self), chunk: 4096),
                                           scanPaths: [projects.path])
            expect(rows.count == 4, "\(rows.map(\.path))")
            // Take paths from Mole's own output, as the app does: Mole prints
            // physical paths (/private/var/...), Foundation may not.
            let chosen = Set(rows.map(\.path).filter { $0.hasSuffix("/alpha/node_modules") || $0.hasSuffix("/gamma/dist") })
            expect(chosen.count == 2, "\(chosen)")
            expect(Set(rows.map(\.project).map { ($0 as NSString).lastPathComponent }) == ["alpha", "beta", "gamma"],
                   "projects: \(rows.map(\.project))")

            let session = TerminalSession()
            session.start(["purge", "--dry-run"], usePTY: true, columns: PurgeMenuDriver.columns)
            let problem = await PurgeMenuDriver.select(chosen, in: session) { _ in }
            expect(problem == nil, problem ?? "")
            expect(PurgeMenuDriver.selectedPaths(session.allLines) == chosen,
                   "\(PurgeMenuDriver.selectedPaths(session.allLines))")
            expect(session.currentLine.contains("Remove 2 artifacts"), session.currentLine)
            session.send("\u{1b}")
            await LiveChecks.waitForExit(session, seconds: 30)
            expect(chosen.allSatisfy { FileManager.default.fileExists(atPath: $0) }, "dry run kept files")
        }

        Checks.add("purge", "driver refuses a path the menu does not offer", live: true) {
            let (home, projects) = try makeProjects()
            let previousHome = ProcessInfo.processInfo.environment["HOME"]
            setenv("HOME", home.path, 1)
            defer { setenv("HOME", previousHome ?? NSHomeDirectory(), 1) }
            let preview = try await MoleCLI.run(["purge", "--dry-run"])
            let rows = PurgeArtifact.parse(parse(String(decoding: preview, as: UTF8.self), chunk: 4096),
                                           scanPaths: [projects.path])
            let real = try require(rows.first { $0.path.hasSuffix("/alpha/node_modules") }).path
            let gone = (real as NSString).deletingLastPathComponent + "/../gone/build"
            let session = TerminalSession()
            session.start(["purge", "--dry-run"], usePTY: true, columns: PurgeMenuDriver.columns)
            let problem = await PurgeMenuDriver.select([real, gone], in: session) { _ in }
            await LiveChecks.waitForExit(session, seconds: 30)
            expect(problem?.contains("找不到") == true, problem ?? "nil")
            expect(!session.allLines.contains { $0.hasPrefix("Selected paths:") }, "never reached confirmation")
        }
    }

    /// A home whose purge_paths points at four old artifacts in three projects.
    static func makeProjects() throws -> (home: URL, projects: URL) {
        let root = makeFixtureDir("purge-\(UUID().uuidString.prefix(6))").resolvingSymlinksInPath()
        let projects = root.appendingPathComponent("projects")
        let fm = FileManager.default
        func file(_ path: String, bytes: Int) throws {
            let url = projects.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: url)
        }
        // Mole only offers node_modules that npm installed: a lockfile plus npm's install record.
        try file("alpha/package.json", bytes: 2)
        try file("alpha/package-lock.json", bytes: 2)
        try file("alpha/node_modules/.package-lock.json", bytes: 2)
        try file("alpha/node_modules/pkg/index.js", bytes: 200_000)
        try file("beta/requirements.txt", bytes: 2)
        try file("beta/.venv/pyvenv.cfg", bytes: 20)
        try file("beta/.venv/lib/a.so", bytes: 100_000)
        try file("gamma/package.json", bytes: 2)
        try file("gamma/package-lock.json", bytes: 2)
        try file("gamma/node_modules/.package-lock.json", bytes: 2)
        try file("gamma/dist/app.js", bytes: 50_000)
        try file("gamma/node_modules/x/i.js", bytes: 30_000)
        // Mole skips artifacts touched in the last week.
        let old = Date(timeIntervalSinceNow: -150 * 86400)
        for case let url as URL in fm.enumerator(at: projects, includingPropertiesForKeys: nil)! {
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        let home = root.appendingPathComponent("home")
        try fm.createDirectory(at: home.appendingPathComponent(".config/mole"), withIntermediateDirectories: true)
        try (projects.path + "\n").write(to: home.appendingPathComponent(".config/mole/purge_paths"),
                                         atomically: true, encoding: .utf8)
        return (home, projects)
    }
}
