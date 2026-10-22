import Foundation

/// Every case runs with HOME pointed at a fixture, so ~/.config/mole is never touched.
@MainActor
enum WhitelistChecks {
    static func withHome(_ body: (URL) async throws -> Void) async throws {
        let home = makeFixtureDir("wl-\(UUID().uuidString.prefix(6))")
        let previous = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", home.path, 1)
        defer { setenv("HOME", previous ?? NSHomeDirectory(), 1) }
        try await body(home)
    }

    static func effective(_ state: Whitelist.State) -> Set<String> {
        Set(state.rows.filter(\.protected).map(\.pattern) + state.custom)
    }

    static func register() {
        Checks.add("whitelist", "saving unchanged keeps every default protection", live: true) {
            try await withHome { home in
                let before = try await Whitelist.load(.clean)
                expect(before.rows.count > 40 && !before.rows.filter(\.protected).isEmpty, "defaults: \(before.rows.count)")
                try await Whitelist.save(.clean, protectedRows: before.rows.filter(\.protected), custom: before.custom)
                let file = home.appendingPathComponent(".config/mole/whitelist")
                expect(FileManager.default.fileExists(atPath: file.path), "file written")
                let after = try await Whitelist.load(.clean)
                expect(effective(after) == effective(before),
                       "lost: \(effective(before).subtracting(effective(after))) gained: \(effective(after).subtracting(effective(before)))")
            }
        }

        Checks.add("whitelist", "ticking Trash and adding a path persist; custom survives a later save", live: true) {
            try await withHome { home in
                var state = try await Whitelist.load(.clean)
                let trash = try require(state.rows.firstIndex { $0.name == "Trash" })
                state.rows[trash].protected = true
                try await Whitelist.save(.clean, protectedRows: state.rows.filter(\.protected),
                                         custom: state.custom + ["~/Projects/keep-me/*"])
                var reloaded = try await Whitelist.load(.clean)
                expect(reloaded.rows.first { $0.name == "Trash" }?.protected == true, "Trash protected")
                expect(reloaded.custom.contains("~/Projects/keep-me/*") || reloaded.custom.contains(home.path + "/Projects/keep-me/*"),
                       "custom: \(reloaded.custom)")
                // Untick Trash only; the custom path must stay.
                if let index = reloaded.rows.firstIndex(where: { $0.name == "Trash" }) { reloaded.rows[index].protected = false }
                try await Whitelist.save(.clean, protectedRows: reloaded.rows.filter(\.protected), custom: reloaded.custom)
                let last = try await Whitelist.load(.clean)
                expect(last.rows.first { $0.name == "Trash" }?.protected == false, "Trash unprotected")
                expect(last.custom.contains { $0.hasSuffix("/Projects/keep-me/*") }, "custom kept: \(last.custom)")
            }
        }

        Checks.add("whitelist", "an unreadable file is never overwritten", live: true) {
            try await withHome { home in
                let file = home.appendingPathComponent(".config/mole/whitelist")
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "# mine\n~/precious/*\n".write(to: file, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
                defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
                var loadFailed = false
                do { _ = try await Whitelist.load(.clean) } catch { loadFailed = true }
                expect(loadFailed, "load must fail")
                var saveFailed = false
                do { try await Whitelist.save(.clean, protectedRows: [], custom: []) } catch { saveFailed = true }
                expect(saveFailed, "save must refuse")
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
                expect(try String(contentsOf: file, encoding: .utf8).contains("~/precious/*"), "file untouched")
            }
        }

        Checks.add("whitelist", "optimize whitelist round trip", live: true) {
            try await withHome { _ in
                var state = try await Whitelist.load(.optimize)
                expect(state.rows.count >= 10, "\(state.rows.count) tasks")
                state.rows[0].protected = true
                try await Whitelist.save(.optimize, protectedRows: state.rows.filter(\.protected), custom: state.custom)
                let after = try await Whitelist.load(.optimize)
                expect(Set(after.rows.filter(\.protected).map(\.pattern)) == [state.rows[0].pattern],
                       "\(after.rows.filter(\.protected).map(\.pattern))")
            }
        }
    }
}
