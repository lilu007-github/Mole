import Foundation

@MainActor
enum ProcessDetailChecks {
    static func register() {
        Checks.add("process", "elapsed times and warnings") {
            expect(ProcessDetails.seconds(fromEtime: "05:06") == 306, "mm:ss")
            expect(ProcessDetails.seconds(fromEtime: "01:02:03") == 3723, "hh:mm:ss")
            expect(ProcessDetails.seconds(fromEtime: "3-00:00:01") == 259_201, "days")
            var details = ProcessDetails(pid: 9, name: "x", executable: "/gone", executableMissing: true, user: "me",
                                         state: "Z", elapsed: nil, elapsedSeconds: 100 * 86400, ancestors: [],
                                         app: nil, launchdLabel: nil, listening: ["*:8080 (TCP)"])
            expect(details.warnings.count == 4, "\(details.warnings)")
            details.listening = ["127.0.0.1:5432 (TCP)"]
            expect(details.warnings.count == 3, "loopback is not public")
        }

        Checks.add("process", "a live listener shows its path, parent and port") {
            let port = Int.random(in: 40000...49999)
            let listener = Process()
            listener.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
            listener.arguments = ["-l", "127.0.0.1", String(port)]
            listener.standardOutput = FileHandle.nullDevice
            listener.standardError = FileHandle.nullDevice
            try listener.run()
            defer { listener.terminate() }
            try await Task.sleep(for: .milliseconds(400))
            let details = ProcessDetails.load(pid: Int(listener.processIdentifier), name: "nc")
            expect(details.executable == "/usr/bin/nc", details.executable ?? "nil")
            expect(details.ancestors.first?.pid == Int(ProcessInfo.processInfo.processIdentifier), "parent is the runner")
            expect(details.listening.contains("127.0.0.1:\(port) (TCP)"), "\(details.listening)")
            expect(details.warnings.isEmpty, "\(details.warnings)")
            expect(details.user == NSUserName(), details.user ?? "nil")
        }
    }
}
