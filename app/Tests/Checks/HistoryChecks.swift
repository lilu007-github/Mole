import Foundation

@MainActor
enum HistoryChecks {
    static func register() {
        Checks.add("history", "sizes Mole prints parse to bytes") {
            expect(HistoryReport.parseSize("543.4MB") == 543_400_000, "MB")
            expect(HistoryReport.parseSize("12KB") == 12_000, "KB")
            expect(HistoryReport.parseSize("1.2GB+") == 1_200_000_000, "lower bound")
            expect(HistoryReport.parseSize("0B") == 0 && HistoryReport.parseSize("") == 0, "zero")
        }

        Checks.add("history", "timestamps from history and deletions parse") {
            expect(HistoryReport.parseDate("2026-10-22 00:59:13") != nil, "session time")
            let deletion = HistoryReport.Deletion(timestamp: "2026-10-22T00:59:13-0700", path: "/x")
            expect(deletion.date != nil, "deletion time without a colon in the offset")
        }

        Checks.add("history", "operation log rows parse, including odd paths") {
            let trashed = OperationEntry.parse(
                "[2026-10-22 00:59:13] [uninstall run=20261022005845-80299-26427-1778] TRASHED /Applications/Notion Web Clipper.app (8660KB)")
            expect(trashed?.command == "uninstall" && trashed?.runID == "20261022005845-80299-26427-1778", "ids")
            expect(trashed?.path == "/Applications/Notion Web Clipper.app" && trashed?.detail == "8660KB", "path and detail")

            let parens = OperationEntry.parse("[2026-10-22 01:00:00] [clean] REMOVED /Users/me/Library/Caches/App (Beta)/x (3KB)")
            expect(parens?.path == "/Users/me/Library/Caches/App (Beta)/x" && parens?.detail == "3KB",
                   "\(parens?.path ?? "nil") | \(parens?.detail ?? "nil")")
            expect(parens?.runID == nil, "no run id")

            let bare = OperationEntry.parse("[2026-10-22 01:00:00] [installer] REMOVED /Users/me/Downloads/a.dmg")
            expect(bare?.path == "/Users/me/Downloads/a.dmg" && bare?.detail == nil, "no detail")

            expect(OperationEntry.parse("# ========== clean session started at 2026-10-22 01:00:00 ==========") == nil,
                   "session markers are not entries")
        }

        Checks.add("history", "empty and preview sessions are recognised") {
            let json = #"""
            {"sessions":[
              {"command":"uninstall","run_id":"","started_at":"2026-10-22 00:53:37","items":0,"size":"0B",
               "operation_count":0,"failed_tasks":0,
               "actions":{"removed":0,"trashed":0,"skipped":0,"failed":0,"rebuilt":0,"other":0}},
              {"command":"clean-dry-run","run_id":"1","started_at":"2026-10-22 00:08:23","items":3250,"size":"11.09GB",
               "operation_count":0,"failed_tasks":0,
               "actions":{"removed":0,"trashed":0,"skipped":0,"failed":0,"rebuilt":0,"other":0}}],
             "deletions":[]}
            """#
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let report = try decoder.decode(HistoryReport.self, from: Data(json.utf8))
            expect(report.sessions[0].isEmpty && !report.sessions[0].isDryRun, "empty uninstall")
            expect(report.sessions[1].isDryRun && report.sessions[1].baseCommand == "clean", "preview")
            expect(report.sessions[1].sizeBytes == 11_090_000_000, "size")
        }

        Checks.add("history", "history --json decodes and runs resolve to log rows", live: true) {
            let report = try await MoleCLI.json(["history", "--json", "--limit", "200"], as: HistoryReport.self)
            expect(!report.sessions.isEmpty, "sessions")
            guard let run = report.sessions.first(where: { session in
                guard let id = session.runId, !id.isEmpty, let a = session.actions else { return false }
                return a.removed + a.trashed + a.skipped + a.failed > 0
            }) else { throw Checks.Skip(reason: "no run with logged actions yet") }
            let entries = OperationEntry.entries(runID: run.runId!)
            expect(!entries.isEmpty && entries.allSatisfy { $0.runID == run.runId }, "\(run.command): \(entries.count) rows")
        }
    }
}
