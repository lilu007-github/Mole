import Foundation

@MainActor
enum ExternalChecks {
    static func register() {
        Checks.add("external", "default whitelist keeps Finder metadata, removes .TemporaryItems", live: true) {
            try await withTestDrive { volume in
                let state = try await Whitelist.load(.clean)
                expect(state.rows.contains { $0.pattern == "FINDER_METADATA" && $0.protected }, "Finder metadata protected by default")
                try await clean(volume)
                expect(!exists(volume, ".TemporaryItems/scratch"), ".TemporaryItems removed")
                expect(exists(volume, ".DS_Store") && exists(volume, "docs/._report.txt"), "metadata kept while protected")
                expect(exists(volume, "docs/report.txt") && exists(volume, ".Trashes/501/old.txt"), "files and drive Trash kept")
            }
        }

        Checks.add("external", "Finder metadata is a hard safety rule: unticking cannot unprotect it", live: true) {
            try await withTestDrive { volume in
                var state = try await Whitelist.load(.clean)
                let row = try require(state.rows.firstIndex { $0.pattern == "FINDER_METADATA" })
                expect(state.rows[row].alwaysProtected, "reported as always protected")
                state.rows[row].protected = false
                try await Whitelist.save(.clean, protectedRows: state.rows.filter(\.protected), custom: state.custom)
                let reloaded = try await Whitelist.load(.clean)
                expect(reloaded.rows.first { $0.pattern == "FINDER_METADATA" }?.protected == true, "Mole re-adds it on load")
                try await clean(volume)
                expect(exists(volume, ".DS_Store") && exists(volume, "docs/._report.txt"), "metadata still kept")
                expect(!exists(volume, ".TemporaryItems/scratch"), ".TemporaryItems removed")
            }
        }

        Checks.add("external", "Mole refuses a path that is not a mounted drive", live: true) {
            let session = TerminalSession()
            session.start(["clean", "--external", NSHomeDirectory(), "--dry-run"], usePTY: false)
            await LiveChecks.waitForExit(session, seconds: 30)
            expect(session.exitCode != 0, "exit \(session.exitCode ?? -1)")
            expect(session.allLines.contains { $0.contains("must be under") || $0.contains("Refusing") }, "\(session.allLines)")
        }
    }

    static func exists(_ volume: URL, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: volume.appendingPathComponent(path).path)
    }

    static func clean(_ volume: URL) async throws {
        let preview = TerminalSession()
        preview.start(["clean", "--external", volume.path, "--dry-run"], usePTY: false)
        await LiveChecks.waitForExit(preview, seconds: 120)
        expect(SectionReport(lines: preview.allLines).sections.contains { $0.title == "External volume" }, "preview section")
        expect(exists(volume, ".TemporaryItems/scratch"), "preview kept files")
        let session = TerminalSession()
        session.start(["clean", "--external", volume.path], usePTY: false)
        await LiveChecks.waitForExit(session, seconds: 120)
        expect(session.exitCode == 0, "exit \(session.exitCode ?? -1): \(session.allLines.suffix(5))")
    }

    /// A fresh 20 MB HFS+ image mounted hidden, in a fixture HOME so the
    /// whitelist and logs of the real account are not touched.
    static func withTestDrive(_ body: (URL) async throws -> Void) async throws {
        try await WhitelistChecks.withHome { home in
            let image = home.appendingPathComponent("drive.dmg").path
            let name = "BurrowCheck\(Int.random(in: 1000...9999))"
            _ = try runProcess("/usr/bin/hdiutil", ["create", "-quiet", "-size", "20m", "-fs", "HFS+", "-volname", name, image])
            _ = try runProcess("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", image])
            let volume = URL(fileURLWithPath: "/Volumes/\(name)")
            defer { _ = try? runProcess("/usr/bin/hdiutil", ["detach", "-quiet", "-force", volume.path]) }
            guard FileManager.default.fileExists(atPath: volume.path) else { throw Checks.Skip(reason: "could not mount a test image") }
            expect(ExternalCleanSheet.mountedVolumes().contains { $0.url.path == volume.path }, "volume listed")

            let fm = FileManager.default
            for folder in ["docs", ".Trashes/501", ".TemporaryItems"] {
                try fm.createDirectory(at: volume.appendingPathComponent(folder), withIntermediateDirectories: true)
            }
            try Data("keep".utf8).write(to: volume.appendingPathComponent("docs/report.txt"))
            try Data("in the drive's Trash".utf8).write(to: volume.appendingPathComponent(".Trashes/501/old.txt"))
            try Data(count: 4000).write(to: volume.appendingPathComponent(".TemporaryItems/scratch"))
            let dsStore = Data([0, 0, 0, 1] + Array("Bud1".utf8) + [0, 0, 16, 0]) + Data(count: 4000)
            let appleDouble = Data([0, 5, 22, 7, 0, 2, 0, 0]) + Data(count: 4000)
            try dsStore.write(to: volume.appendingPathComponent(".DS_Store"))
            try dsStore.write(to: volume.appendingPathComponent("docs/.DS_Store"))
            try appleDouble.write(to: volume.appendingPathComponent("docs/._report.txt"))
            try await body(volume)
        }
    }
}
