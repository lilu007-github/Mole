import Foundation

@MainActor
enum IdleChecks {
    static func register() {
        Checks.add("idle", "build daemons without an IDE and orphaned dev servers are found") {
            let rows: [IdleProcesses.Row] = [
                .init(pid: 10, ppid: 1, elapsed: "2-01:00:00", rssKB: 900_000, user: "me",
                      command: "/usr/bin/java -Xmx2g org.gradle.launcher.daemon.bootstrap.GradleDaemon 8.10"),
                .init(pid: 11, ppid: 1, elapsed: "05:00", rssKB: 120_000, user: "me", command: "node /app/node_modules/.bin/vite --port 5173"),
                .init(pid: 12, ppid: 4000, elapsed: "05:00", rssKB: 120_000, user: "me", command: "node /app/node_modules/.bin/vite"),
                .init(pid: 13, ppid: 1, elapsed: "05:00", rssKB: 50_000, user: "me", command: "node /Applications/Some.app/server.js"),
                .init(pid: 14, ppid: 1, elapsed: "05:00", rssKB: 50_000, user: "root",
                      command: "/usr/bin/java org.gradle.launcher.daemon.bootstrap.GradleDaemon"),
            ]
            let found = IdleProcesses.find(in: rows, user: "me", ideOpen: false)
            expect(found.map(\.pid) == [10, 11], "\(found.map(\.pid))")
            expect(found.first?.name == "Gradle Daemon" && found.first?.memoryBytes == 900_000 * 1024, "\(found)")
            expect(IdleProcesses.find(in: rows, user: "me", ideOpen: true).map(\.pid) == [11], "IDE open keeps daemons")
        }

        Checks.add("idle", "ps snapshot parses", live: true) {
            let rows = IdleProcesses.psRows()
            expect(rows.count > 20 && rows.contains { $0.pid == Int(ProcessInfo.processInfo.processIdentifier) }, "\(rows.count)")
        }
    }
}
