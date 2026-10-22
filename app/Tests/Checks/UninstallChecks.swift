import Foundation

@MainActor
enum UninstallChecks {
    static func register() {
        Checks.add("uninstall", "plan parsing takes the latest reprint") {
            let lines = [
                "Files to be removed:", "◎ Example , 508.9MB", "  ✓ /Applications/Example.app , 508.9MB", "",
                "Personal data kept:", "  ⊙ ~/Library/Application Support/Example", "  ⊙ /var/folders/ab/C/com.example",
                "", "D choose personal data",
                "Personal data to remove  1/2 selected",
                "Files to be removed:", "◎ Example , 509.2MB", "  ✓ /Applications/Example.app , 508.9MB", "",
                "Personal data to remove:", "  ✓ /var/folders/ab/C/com.example , 348KB", "",
                "Personal data kept:", "  ⊙ ~/Library/Application Support/Example", "",
                "D choose personal data",
                "➤ Remove 1 app, 509.2MB, including personal data  Enter confirm, ESC cancel: ",
            ]
            let plan = UninstallPlan.parse(lines)
            expect(plan?.personalRemoved == ["/var/folders/ab/C/com.example"], "\(plan?.personalRemoved ?? [])")
            expect(plan?.personalKept == ["~/Library/Application Support/Example"], "\(plan?.personalKept ?? [])")
            expect(UninstallPlan.displayPath("  ⊙ ~/Library/Prefs/a , b.plist") == "~/Library/Prefs/a , b.plist",
                   "a kept row has no size")
            expect(UninstallPlan.parse(["Matched 1 app(s):"]) == nil, "no plan yet")
        }

        Checks.add("uninstall", "personal data choice reaches Mole's reprinted plan", live: true) {
            let apps = try await MoleCLI.json(["uninstall", "--list"], as: [InstalledApp].self)
            for app in apps.filter({ $0.source == "App" }).prefix(6) {
                let session = TerminalSession()
                session.start(["uninstall", "--dry-run", app.uninstallName], usePTY: true)
                _ = await LiveChecks.waitFor(seconds: 90) {
                    session.currentLine.contains(PromptBar.confirmMarker) || !session.isRunning
                }
                guard session.isRunning, let plan = UninstallPlan.parse(session.allLines), plan.personalKept.count >= 2 else {
                    session.send("\u{1b}")
                    await LiveChecks.waitForExit(session, seconds: 20)
                    continue
                }
                let order = plan.personalKept
                let wanted: Set<String> = [order[1]]
                let problem = await PersonalDataDriver.apply(wanted: wanted, order: order, current: [], in: session)
                expect(problem == nil, "\(app.name): \(problem ?? "")")
                let after = UninstallPlan.parse(session.allLines)
                expect(after?.personalRemoved == [order[1]], "\(after?.personalRemoved ?? [])")
                expect(Set(after?.personalKept ?? []) == Set(order).subtracting(wanted), "kept rest")
                expect(session.currentLine.contains("including personal data"), session.currentLine)
                session.send("\u{1b}") // cancel the dry run
                await LiveChecks.waitForExit(session, seconds: 20)
                expect(FileManager.default.fileExists(atPath: app.path), "\(app.name) untouched")
                return
            }
            throw Checks.Skip(reason: "no app with two or more personal data folders among the first six")
        }
    }
}
