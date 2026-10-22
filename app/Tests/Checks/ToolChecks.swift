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

        Checks.add("touchid", "mo touchid status lines map to a state") {
            expect(TouchIDSudo.parse("✓ Touch ID is enabled for sudo\n") == .enabled, "enabled")
            expect(TouchIDSudo.parse("☻ Touch ID is not configured for sudo\n") == .disabled, "disabled")
            expect(TouchIDSudo.parse("Run Mole without sudo") == .unknown, "anything else")
        }

        Checks.add("touchid", "status reads the real mo touchid output", live: true) {
            expect(await TouchIDSudo.status() != .unknown, "mo touchid status gave no known line")
        }

        Checks.add("changelog", "releases and their items parse in order") {
            let releases = Changelog.parse("""
            # Burrow 更新说明

            说明文字，不是条目。
            - 版本标题之前的条目会被忽略

            ## 0.3.0 — 2026-10-22

            - 第一条
            - 第二条，含 — 破折号
            ## 0.2.0 — 2026-10-21
            - 旧版本
            """)
            expect(releases.map(\.version) == ["0.3.0", "0.2.0"], "\(releases.map(\.version))")
            expect(releases.first?.date == "2026-10-22", "\(releases.first?.date ?? "")")
            expect(releases.first?.items == ["第一条", "第二条，含 — 破折号"], "\(releases.first?.items ?? [])")
            expect(releases.last?.items == ["旧版本"], "\(releases.last?.items ?? [])")
        }

        Checks.add("changelog", "app/VERSION matches the newest CHANGELOG release") {
            let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let version = try String(contentsOf: app.appendingPathComponent("VERSION"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let releases = Changelog.parse(try String(contentsOf: app.appendingPathComponent("CHANGELOG.md"), encoding: .utf8))
            expect(releases.first?.version == version, "VERSION \(version) vs CHANGELOG \(releases.first?.version ?? "none")")
            expect(releases.allSatisfy { !$0.items.isEmpty && $0.date.count == 10 }, "every release has a date and items")
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

        Checks.add("doctor", "performance diagnosis block parses with its details") {
            let lines = parse("""
            Optimize

            Performance diagnosis
              ◎ Likely bottleneck: WindowServer (~43.5% CPU sustained)
              ⊙ Desktop composition is busy. When another family is higher, treat this as a symptom.
              ◎ Memory pressure: swap 9.14GB of 9.66GB used (94%), 39% free
                Claude Helper (Renderer)    385.3MB
                Google Chrome               271.1MB

            ➤ Finder Cache Refresh
              → QuickLook thumbnails refreshed

            """)
            let findings = PerformanceDiagnosis.parse(lines)
            expect(findings.count == 3, "\(findings.map(\.text))")
            expect(findings.first?.text.hasPrefix("Likely bottleneck: WindowServer") == true, "\(findings.first?.text ?? "")")
            expect(findings.last?.details == ["Claude Helper (Renderer)    385.3MB", "Google Chrome               271.1MB"],
                   "\(findings.last?.details ?? [])")
            expect(PerformanceDiagnosis.parse(["➤ Finder Cache Refresh"]).isEmpty, "no block")
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
