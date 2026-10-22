import Foundation

@MainActor
enum SlimChecks {
    static func register() {
        Checks.add("slim", "dry-run rows, truncated names and the summary parse") {
            let lines = parse("""
            → DRY RUN MODE, No apps will be changed

              Comet                                   578.4MB
              爱壹帆                                  175.9MB
              A Very Long Application Name That ...     2.7MB
              VooV Meeting                              227KB

            4 apps, 757.2MB of Intel code
            """)
            let apps = SlimApp.parse(lines)
            expect(apps.map(\.name) == ["Comet", "爱壹帆", "A Very Long Application Name That ...", "VooV Meeting"],
                   "\(apps.map(\.name))")
            expect(apps.map(\.size) == ["578.4MB", "175.9MB", "2.7MB", "227KB"], "\(apps.map(\.size))")
            expect(apps[2].isTruncated && apps[2].url == nil, "a cut name maps to no bundle")
            expect(SlimApp.summary(lines) == "4 apps, 757.2MB of Intel code", SlimApp.summary(lines) ?? "nil")
            expect(SlimApp.matches("A Very Long Application Name That ...", "A Very Long Application Name That Keeps Going"),
                   "prefix match for a cut name")
            expect(!SlimApp.matches("Comet", "Comet Beta"), "whole names compare exactly")
        }

        Checks.add("slim", "menu frames and the confirmation list parse") {
            let frame = SlimMenuDriver.frame([
                "Select apps to slim  1/3 selected", "",
                "  ● Comet                                   578.4MB",
                "➤ ○ 爱壹帆                                  175.9MB",
                "  ○ VooV Meeting                              227KB",
                "↑↓ | Space Select | Enter Save | Q Cancel", "S Size | O ↑ | / Search | h/l Page",
            ])
            expect(frame == .init(cursorName: "爱壹帆", total: 3, selected: 1), "\(String(describing: frame))")
            expect(SlimMenuDriver.frame(["Select apps to slim  0/3 selected", "➤ ○ Comet   1MB"]) == nil,
                   "a frame without its key legend is still being drawn")
            let names = SlimMenuDriver.confirmedNames([
                "Apps to slim:", "  ✓ Comet , 578.4MB", "  ✓ VooV Meeting , 227KB", "",
                "Originals move to the Trash. App updates bring the Intel code back.",
                "➤ Slim 2 apps, 578.6MB  Enter confirm, ESC cancel: ",
            ])
            expect(names == ["Comet", "VooV Meeting"], "\(names)")
        }

        Checks.add("slim", "driver selects exactly the chosen apps in Mole's menu", live: true) {
            let root = try makeApps()
            defer { try? FileManager.default.removeItem(at: root) }
            let restore = setSlimEnvironment(root)
            defer { restore() }

            let preview = try await MoleCLI.run(["slim", "--dry-run"])
            let listed = SlimApp.parse(parse(String(decoding: preview, as: UTF8.self), chunk: 4096))
            guard listed.count == 2 else { throw Checks.Skip(reason: "fixture apps not eligible here: \(listed.map(\.name))") }
            let chosen: Set<String> = ["Steam"]

            let session = TerminalSession()
            session.start(["slim"], usePTY: true, columns: SlimMenuDriver.columns)
            let problem = await SlimMenuDriver.select(chosen, among: listed, in: session) { _ in }
            expect(problem == nil, (problem ?? "") + "\n" + session.allLines.suffix(40).joined(separator: "\n"))
            expect(SlimMenuDriver.confirmedNames(session.allLines) == ["Steam"], "\(SlimMenuDriver.confirmedNames(session.allLines))")
            expect(session.currentLine.contains("Slim 1 apps"), session.currentLine)
            session.send("\u{1b}")
            await LiveChecks.waitForExit(session, seconds: 30)
            let executable = root.appendingPathComponent("Applications/Steam.app/Contents/MacOS")
            let files = try FileManager.default.contentsOfDirectory(atPath: executable.path)
            expect(!files.isEmpty, "cancel kept the app")
            expect(SlimApp.parse(parse(String(decoding: try await MoleCLI.run(["slim", "--dry-run"]), as: UTF8.self),
                                       chunk: 4096)).map(\.name).contains("Steam"), "Intel code still there after cancel")
        }

        Checks.add("slim", "driver refuses an app the menu does not offer", live: true) {
            let root = try makeApps()
            defer { try? FileManager.default.removeItem(at: root) }
            let restore = setSlimEnvironment(root)
            defer { restore() }
            let preview = try await MoleCLI.run(["slim", "--dry-run"])
            let listed = SlimApp.parse(parse(String(decoding: preview, as: UTF8.self), chunk: 4096))
            guard listed.count == 2 else { throw Checks.Skip(reason: "fixture apps not eligible here") }

            let session = TerminalSession()
            session.start(["slim"], usePTY: true, columns: SlimMenuDriver.columns)
            let problem = await SlimMenuDriver.select(["Steam", "Gone App"], among: listed, in: session) { _ in }
            await LiveChecks.waitForExit(session, seconds: 30)
            expect(problem?.contains("找不到") == true, problem ?? "nil")
            expect(!session.allLines.contains { $0.hasPrefix("Apps to slim:") }, "never reached confirmation")
        }
    }

    /// Clones of two small universal Developer ID apps in a fixture Applications folder.
    static func makeApps() throws -> URL {
        let root = makeFixtureDir("slim-\(UUID().uuidString.prefix(6))").resolvingSymlinksInPath()
        let apps = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        for name in ["Steam", "Sequel Ace"] {
            let source = "/Applications/\(name).app"
            guard FileManager.default.fileExists(atPath: source) else {
                throw Checks.Skip(reason: "\(name).app is not installed")
            }
            let copy = Process()
            copy.executableURL = URL(fileURLWithPath: "/bin/cp")
            copy.arguments = ["-cR", source, apps.path + "/"] // APFS clone: instant, no extra space
            try copy.run()
            copy.waitUntilExit()
            guard copy.terminationStatus == 0 else { throw Checks.Skip(reason: "could not clone \(name).app") }
        }
        return root
    }

    /// Points mo slim at the fixture folder; the override works only with MOLE_TEST_NO_AUTH.
    static func setSlimEnvironment(_ root: URL) -> () -> Void {
        let names = ["MOLE_SLIM_TEST_APP_ROOTS", "MOLE_TEST_NO_AUTH"]
        let previous = names.map { ProcessInfo.processInfo.environment[$0] }
        setenv("MOLE_SLIM_TEST_APP_ROOTS", root.appendingPathComponent("Applications").path, 1)
        setenv("MOLE_TEST_NO_AUTH", "1", 1)
        return {
            for (name, value) in zip(names, previous) {
                if let value { setenv(name, value, 1) } else { unsetenv(name) }
            }
        }
    }
}
