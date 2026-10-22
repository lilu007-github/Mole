import Foundation

@MainActor
enum ToolChecks {
    static func register() {
        Checks.add("update", "versions compare numerically") {
            expect(UpdateChecker.normalize("V1.62.0") == "1.62.0", "strip V")
            expect(UpdateChecker.isNewer("1.62.10", than: "1.62.9"), "10 > 9")
            expect(UpdateChecker.isNewer("1.63", than: "1.62.5"), "minor bump")
            expect(!UpdateChecker.isNewer("1.62.0", than: "1.62.0"), "equal")
            expect(!UpdateChecker.isNewer("1.61.9", than: "1.62.0"), "older")
        }

        Checks.add("update", "GitHub reports a release to compare with", live: true) {
            let result = await UpdateChecker.check()
            if case let .failed(message) = result { throw Checks.Skip(reason: "offline? \(message)") }
            switch result {
            case let .upToDate(current): expect(!current.isEmpty, "current")
            case let .available(current, latest, _): expect(UpdateChecker.isNewer(latest, than: current), "\(latest) > \(current)")
            case .failed: break
            }
        }

        Checks.add("doctor", "each problem in a status snapshot is reported") {
            let json = #"""
            {"uptime":"10d 2h","uptime_seconds":874800,"health_score":52,"health_score_msg":"Fair",
             "memory":{"used_percent":91,"pressure":"warn"},
             "disks":[{"mount":"/","used":470000000000,"total":494000000000,"used_percent":95.1}],
             "batteries":[{"percent":40,"health":"Service","cycle_count":1200,"capacity":70}],
             "trash_size":6000000000,
             "top_processes":[{"pid":1,"name":"mds_stores","cpu":97.0,"memory_bytes":1}]}
            """#
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let status = try decoder.decode(StatusSnapshot.self, from: Data(json.utf8))
            let titles = Set(Doctor.run(status: status, moleVersion: "Mole version 1.62.0").problems.map(\.title))
            for title in ["启动磁盘快满了", "电池老化", "电池循环次数较多", "内存压力偏高", "建议重启", "废纸篓超过 5 GB"] {
                expect(titles.contains(title), "missing \(title): \(titles)")
            }
        }

        Checks.add("doctor", "a healthy snapshot reports no problems and copies as text") {
            let json = #"""
            {"uptime":"1d","uptime_seconds":90000,"memory":{"pressure":"normal"},
             "disks":[{"mount":"/","used_percent":40}],"batteries":[{"cycle_count":60,"capacity":100}],"trash_size":0}
            """#
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let status = try decoder.decode(StatusSnapshot.self, from: Data(json.utf8))
            let report = Doctor.run(status: status, moleVersion: nil)
            let problems = report.problems.filter { $0.level == .problem || ($0.level == .warning && $0.title != "没有完全磁盘访问权限") }
            expect(problems.isEmpty, "\(problems.map(\.title))")
            expect(report.text.contains("[检测到的问题]") && report.text.contains("[Mole 运行环境]"), report.text)
        }
    }
}
