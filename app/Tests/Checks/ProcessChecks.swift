import Foundation

@MainActor
enum ProcessChecks {
    static func register() {
        Checks.add("process", "quitting a plain process sends SIGTERM") {
            let sleeper = Process()
            sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
            sleeper.arguments = ["300"]
            try sleeper.run()
            let error = ProcessControl.quit(pid: Int(sleeper.processIdentifier), name: "sleep", force: false)
            sleeper.waitUntilExit()
            expect(error == nil, error ?? "")
            expect(sleeper.terminationReason == .uncaughtSignal && sleeper.terminationStatus == SIGTERM,
                   "status \(sleeper.terminationStatus)")
        }

        Checks.add("process", "critical processes and Burrow itself are refused") {
            expect(ProcessControl.refusal(pid: 1, name: "launchd") != nil, "pid 1")
            expect(ProcessControl.refusal(pid: 400, name: "WindowServer") != nil, "WindowServer")
            expect(ProcessControl.refusal(pid: Int(ProcessInfo.processInfo.processIdentifier), name: "checks") != nil, "self")
            expect(ProcessControl.refusal(pid: 4242, name: "Google Chrome") == nil, "ordinary app allowed")
        }

        Checks.add("process", "a root process fails with a clear message, never elevated") {
            let out = try runProcess("/usr/bin/pgrep", ["-x", "-U", "root", "configd"])
            guard let pid = Int(String(decoding: out, as: UTF8.self).split(separator: "\n").first ?? "") else {
                throw Checks.Skip(reason: "configd not found")
            }
            let error = ProcessControl.quit(pid: pid, name: "configd", force: false)
            expect(error?.contains("管理员权限") == true, error ?? "nil")
        }
    }
}
