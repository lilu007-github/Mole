import Foundation

/// Runs the real Mole CLI from this checkout. Every command here is read-only
/// or a --dry-run: nothing on the Mac is changed. Skip with BURROW_SKIP_LIVE=1.
@MainActor
enum LiveChecks {
    static func register() {
        Checks.add("live", "status --json decodes", live: true) {
            let s = try await MoleCLI.json(["status", "--json"], as: StatusSnapshot.self)
            expect(s.healthScore != nil, "health score")
            expect(!(s.disks ?? []).isEmpty, "disks")
            expect(s.cpu?.usage != nil && s.memory?.total != nil, "cpu and memory")
        }

        Checks.add("live", "analyze --json measures a known folder", live: true) {
            let dir = makeFixtureDir("analyze")
            try Data(count: 300_000).write(to: dir.appendingPathComponent("big.bin"))
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
            try Data(count: 10_000).write(to: dir.appendingPathComponent("sub/small.bin"))
            let result = try await MoleCLI.json(["analyze", "--json", dir.path], as: AnalyzeResult.self)
            expect(Set(result.entries.map(\.name)) == ["big.bin", "sub"], "\(result.entries.map(\.name))")
            expect(result.entries.first?.name == "big.bin", "largest first")
            expect(result.entries.first { $0.name == "sub" }?.isDir == true, "folder flag")
        }

        Checks.add("live", "uninstall --list decodes", live: true) {
            let apps = try await MoleCLI.json(["uninstall", "--list"], as: [InstalledApp].self)
            expect(!apps.isEmpty, "apps listed")
            expect(apps.allSatisfy { !$0.uninstallName.isEmpty && $0.path.hasSuffix(".app") }, "fields")
        }

        Checks.add("live", "optimize preview through a PTY parses into sections", live: true) {
            let session = TerminalSession()
            session.start(["optimize", "--dry-run"], usePTY: true)
            await waitForExit(session, seconds: 180)
            let report = SectionReport(lines: session.allLines)
            expect(session.exitCode == 0, "exit \(session.exitCode ?? -1)")
            expect(report.sections.count >= 5, "\(report.sections.count) sections")
            expect(report.summary.contains { $0.contains("Dry Run") }, "\(report.summary)")
        }

        Checks.add("live", "uninstall preview: prompt appears, Enter finishes the dry run", live: true) {
            let apps = try await MoleCLI.json(["uninstall", "--list"], as: [InstalledApp].self)
            guard let app = apps.first(where: { $0.source == "App" && !$0.path.hasPrefix("/System") }) else {
                throw Checks.Skip(reason: "no third-party app installed")
            }
            let session = TerminalSession()
            session.start(["uninstall", "--dry-run", app.uninstallName], usePTY: true)
            let prompted = await waitFor(seconds: 120) { session.currentLine.contains(PromptBar.confirmMarker) || !session.isRunning }
            expect(prompted && session.isRunning, "prompt for \(app.name): \(session.allLines.suffix(3))")
            session.send("\r")
            await waitForExit(session, seconds: 120)
            expect(session.exitCode == 0, "exit \(session.exitCode ?? -1)")
            expect(session.allLines.contains { $0.contains("dry run complete") || $0.contains("Dry run complete") },
                   "\(session.allLines.suffix(4))")
            expect(FileManager.default.fileExists(atPath: app.path), "\(app.name) still installed")
        }

        Checks.add("live", "installer preview: the driver selects exactly one row", live: true) {
            let data = try await MoleCLI.run(["installer", "--dry-run"])
            let rows = InstallerRow.parse(parse(String(decoding: data, as: UTF8.self), chunk: 4096))
            guard !rows.isEmpty else { throw Checks.Skip(reason: "no installer files on this Mac") }
            let target = rows.count > 1 ? 1 : 0
            let session = TerminalSession()
            session.start(["installer", "--dry-run"], usePTY: true)
            let problem = await InstallerMenuDriver.select([target], expecting: rows, in: session)
            expect(problem == nil, problem ?? "")
            _ = await waitFor(seconds: 60) { session.currentLine.contains(PromptBar.confirmMarker) || !session.isRunning }
            expect(session.currentLine.contains("Delete 1 installers"), session.currentLine)
            let plan = session.allLines.filter { $0.contains("✓") }
            expect(plan.count == 1 && plan[0].contains(rows[target].name), "\(plan)")
            session.send("\u{1b}") // cancel: nothing is removed even in a dry run
            await waitForExit(session, seconds: 30)
        }

        Checks.add("live", "installer driver refuses a list that changed", live: true) {
            let data = try await MoleCLI.run(["installer", "--dry-run"])
            var rows = InstallerRow.parse(parse(String(decoding: data, as: UTF8.self), chunk: 4096))
            guard !rows.isEmpty else { throw Checks.Skip(reason: "no installer files on this Mac") }
            rows[0].name = "renamed-meanwhile.dmg"
            let session = TerminalSession()
            session.start(["installer", "--dry-run"], usePTY: true)
            let problem = await InstallerMenuDriver.select([0], expecting: rows, in: session)
            await waitForExit(session, seconds: 30)
            expect(problem != nil, "refused")
            expect(!session.allLines.contains { $0.contains("Files to be removed") }, "no plan shown")
        }

        Checks.add("live", "keep awake creates and releases a power assertion", live: true) {
            let awake = KeepAwake.shared
            awake.enable(duration: 2, allowDisplaySleep: false)
            expect(try assertions().contains("PreventUserIdleDisplaySleep"), "display assertion")
            try await Task.sleep(for: .seconds(3))
            let afterExpiry = try assertions()
            expect(!awake.isActive && afterExpiry.isEmpty, "expired")
            awake.enable(duration: nil, allowDisplaySleep: true)
            expect(try assertions().contains("PreventUserIdleSystemSleep"), "system assertion")
            awake.disable()
            expect(try assertions().isEmpty, "released")
        }
    }

    static func assertions() throws -> String {
        let out = try runProcess("/usr/bin/pmset", ["-g", "assertions"])
        return String(decoding: out, as: UTF8.self).split(separator: "\n")
            .filter { $0.contains("Burrow keep awake") }.joined(separator: "\n")
    }

    static func waitFor(seconds: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return condition()
    }

    static func waitForExit(_ session: TerminalSession, seconds: Double) async {
        _ = await waitFor(seconds: seconds) { !session.isRunning && session.exitCode != nil }
    }
}
