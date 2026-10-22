import Foundation

/// Pure parsing: terminal replay, section reports, menus, hints and formatting.
/// The sample output below is hand-written in Mole's format, not captured from a Mac.
@MainActor
enum ParsingChecks {
    static let esc = "\u{1b}"

    static func register() {
        Checks.add("parser", "spinner frames collapse to the final line") {
            let text = "\(esc)[?25l⠋ Scanning...\r\(esc)[2K⠙ Scanning...\r\(esc)[2K\(esc)[0;32m✓\(esc)[0m Done\n"
            expect(parse(text) == ["✓ Done"], "\(parse(text))")
        }
        Checks.add("parser", "PTY line endings") {
            expect(parse("a\r\nb\r\n") == ["a", "b"], "\(parse("a\r\nb\r\n"))")
        }
        Checks.add("parser", "a line split between \\r and \\n stays one line") {
            expect(parse("first\r\nsecond\n", chunk: 6) == ["first", "second"], "\(parse("first\r\nsecond\n", chunk: 6))")
        }
        Checks.add("parser", "cursor up redraws the previous line") {
            let text = "one\ntwo\n\(esc)[1A\r\(esc)[2Kthree\n"
            expect(parse(text) == ["one", "three"], "\(parse(text))")
        }
        Checks.add("parser", "clear screen and cursor home start a new screen") {
            expect(parse("old\n\(esc)[2J\(esc)[Hnew\n") == ["new"], "2J")
            expect(parse("menu v1\n\(esc)[Hmenu v2\n") == ["menu v2"], "H")
        }
        Checks.add("parser", "OSC titles and charset switches are dropped") {
            expect(parse("\(esc)]0;title\u{7}\(esc)(Bx\n") == ["x"], "\(parse("\(esc)]0;title\u{7}\(esc)(Bx\n"))")
        }
        Checks.add("parser", "multibyte characters survive 1-byte chunks") {
            let text = "➤ 清理 · 2.3GB\n✓ 完成\n"
            expect(parse(text, chunk: 1) == ["➤ 清理 · 2.3GB", "✓ 完成"], "\(parse(text, chunk: 1))")
            expect(!parse(text, chunk: 1).joined().contains("\u{FFFD}"), "replacement character")
        }
        Checks.add("parser", "incomplete UTF-8 suffix length") {
            let full = Data("清".utf8) // 3 bytes
            expect(TerminalTextParser.incompleteUTF8Suffix(full) == 0, "complete")
            expect(TerminalTextParser.incompleteUTF8Suffix(full.prefix(2)) == 2, "two of three")
            expect(TerminalTextParser.incompleteUTF8Suffix(full.prefix(1)) == 1, "lead byte only")
            expect(TerminalTextParser.incompleteUTF8Suffix(Data("ab".utf8)) == 0, "ascii")
        }

        Checks.add("report", "clean dry run: sections, items, summary, space") {
            let text = """
            Clean Your Mac

            ➤ User essentials
              → User app cache · 28 items, 2.33GB dry
              ◎ Trash · skipped, grant Full Disk Access to your terminal

            ➤ Browsers
              ✓ Nothing to clean

            ======================================================================
            Dry run complete - no changes made
            Potential space: 11.09GB+ | Items: 3250 | Categories: 6
            ======================================================================

            """
            let report = SectionReport(lines: parse(text))
            expect(report.sections.map(\.title) == ["User essentials", "Browsers"], "\(report.sections.map(\.title))")
            expect(report.sections.first?.items.map(\.icon) == ["→", "◎"], "icons")
            expect(report.sections.first?.items.first?.text == "User app cache · 28 items, 2.33GB dry", "item text")
            expect(report.summary.count == 2, "\(report.summary)")
            expect(report.potentialSpace == "11.09GB+", "\(report.potentialSpace ?? "nil")")
        }
        Checks.add("report", "real clean summary reports freed space") {
            let report = SectionReport(lines: ["====", "Cleanup complete", "Space freed: 1.20GB | Items: 12", "===="])
            expect(report.potentialSpace == "1.20GB", "\(report.potentialSpace ?? "nil")")
        }

        Checks.add("installer", "menu rows parse in order, with and without the cursor") {
            let lines = [
                "Select Installers to Remove , 0B, 0 selected",
                "",
                "➤ ○ Example.dmg                           296.8MB | Downloads ",
                "  ● Tool Setup 2.pkg                       10.4MB | Desktop ",
                "↑↓  |  Space Select  |  Enter Confirm  |  A All  |  I Invert  |  Q Quit",
            ]
            let rows = InstallerRow.parse(lines)
            expect(rows.map(\.name) == ["Example.dmg", "Tool Setup 2.pkg"], "\(rows.map(\.name))")
            expect(rows.map(\.size) == ["296.8MB", "10.4MB"], "\(rows.map(\.size))")
            expect(rows.map(\.source) == ["Downloads", "Desktop"], "\(rows.map(\.source))")
            expect(rows.map(\.index) == [0, 1], "indexes")
            expect(rows[0].sameFile(as: rows[0]) && !rows[0].sameFile(as: rows[1]), "sameFile")
        }

        Checks.add("permissions", "Mole's refusal messages map to the right pane") {
            expect(PermissionHint.detect(in: ["Error: macOS denied Trash access. Try moving the item to Trash in Finder."]) == [.appManagement], "app management")
            expect(PermissionHint.detect(in: ["  ◎ Trash · skipped, grant Full Disk Access to your terminal"]) == [.fullDiskAccess], "full disk access")
            expect(PermissionHint.detect(in: ["Uninstall complete", "Removed 1 app"]).isEmpty, "no false positive")
        }

        Checks.add("format", "byte counts never read Zero") {
            expect(!Format.bytes(0).contains("Zero"), Format.bytes(0))
            expect(Format.bytes(nil) == "--", "nil")
            expect(Format.percent(42.4) == "42%", Format.percent(42.4))
            expect(MenuBarLabel.compact(1.5) == "1.5M" && MenuBarLabel.compact(0.001) == "1K", "compact")
        }

        Checks.add("status", "an idle Wi-Fi missing from one sample keeps showing") {
            let wifi = StatusSnapshot.Network(name: "en0", rxRateMbs: 1.2, txRateMbs: 0.3, ip: "10.0.0.2")
            let idle = StatusSnapshot.Network(name: "en4", rxRateMbs: 0, txRateMbs: 0, ip: "")
            var snapshot = try JSONDecoder().decode(StatusSnapshot.self, from: Data("{}".utf8))
            snapshot.network = [wifi, idle]
            expect(StatusMonitor.activeNetwork(in: snapshot, previous: nil, primary: { nil })?.name == "en0", "current")
            snapshot.network = [idle]
            let kept = StatusMonitor.activeNetwork(in: snapshot, previous: wifi, primary: { nil })
            expect(kept?.name == "en0" && kept?.rxRateMbs == 0, "previous at zero rate")
            let first = StatusMonitor.activeNetwork(in: snapshot, previous: nil, primary: { wifi })
            expect(first?.name == "en0" && first?.txRateMbs == 0, "system primary at zero rate")
            expect(StatusMonitor.activeNetwork(in: snapshot, previous: nil, primary: { nil }) == nil, "nothing known")
        }
    }
}
