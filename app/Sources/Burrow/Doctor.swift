import ApplicationServices
import Foundation

/// A read-only health report of the Mac and of Burrow's Mole setup, modelled on
/// Mole Mac's Doctor. Nothing here changes the system.
struct DoctorReport {
    enum Level { case ok, info, warning, problem }

    struct Item: Identifiable {
        let id = UUID()
        var title: String
        var value: String
        var level: Level = .info
        /// A sidebar page or settings pane that fixes it.
        var action: Action?
    }

    enum Action: Equatable {
        case page(SidebarItem)
        case settings(URL)
        case reveal(URL)
    }

    struct Section: Identifiable {
        var id: String { title }
        var title: String
        var items: [Item]
    }

    var sections: [Section]
    var generatedAt = Date()

    var problems: [Item] { sections.first { $0.title == Self.issuesTitle }?.items ?? [] }
    static let issuesTitle = "检测到的问题"

    /// Plain text for "拷贝报告": paste it into an issue or a chat.
    var text: String {
        var lines = ["Burrow 诊断报告 · \(generatedAt.formatted(date: .abbreviated, time: .standard))"]
        for section in sections {
            lines.append("")
            lines.append("[\(section.title)]")
            for item in section.items {
                let mark = switch item.level {
                case .ok: "✓"
                case .info: "·"
                case .warning: "!"
                case .problem: "✗"
                }
                lines.append("\(mark) \(item.title): \(item.value)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

enum Doctor {
    static var operationsLog: URL { OperationLog.fileURL }

    /// Builds the report; `status` may be nil when `mo status` failed.
    static func run(status: StatusSnapshot?, moleVersion: String?) -> DoctorReport {
        let fullDisk = hasFullDiskAccess()
        let logWritable = logIsWritable()
        var issues: [DoctorReport.Item] = []

        if let disk = status?.disks?.first(where: { $0.mount == "/" }), let used = disk.usedPercent, used >= 90 {
            issues.append(.init(title: "启动磁盘快满了", value: "已用 \(Format.percent(used))，到「清理」页释放空间",
                                level: .problem, action: .page(.clean)))
        }
        if !fullDisk {
            issues.append(.init(title: "没有完全磁盘访问权限", value: "部分位置（如废纸篓）无法扫描或清理",
                                level: .warning, action: .settings(PermissionHint.fullDiskAccess.settingsURL)))
        }
        if !logWritable {
            issues.append(.init(title: "操作日志无法写入", value: "最近的操作可能没有记录", level: .problem,
                                action: .reveal(operationsLog.deletingLastPathComponent())))
        }
        if let battery = status?.batteries?.first {
            if let capacity = battery.capacity, capacity > 0, capacity < 80 {
                issues.append(.init(title: "电池老化", value: "健康度 \(capacity)%，建议到 Apple Store 检查", level: .warning))
            }
            if let cycles = battery.cycleCount, cycles >= 1000 {
                issues.append(.init(title: "电池循环次数较多", value: "\(cycles) 次", level: .warning, action: .page(.status)))
            }
        }
        if let pressure = status?.memory?.pressure, pressure == "warn" || pressure == "critical" {
            issues.append(.init(title: "内存压力偏高", value: "关闭不用的 App 会有帮助", level: .warning, action: .page(.status)))
        }
        if let uptime = status?.uptimeSeconds, uptime > 7 * 86400,
           let busy = status?.topProcesses?.first(where: { ($0.cpu ?? 0) >= 90 }) {
            issues.append(.init(title: "建议重启", value: "已运行 \(uptime / 86400) 天，\(busy.name) 持续占用大量 CPU",
                                level: .warning))
        }
        if let trash = status?.trashSize, trash > 5_000_000_000 {
            issues.append(.init(title: "废纸篓超过 5 GB", value: Format.bytes(trash), level: .info, action: .page(.clean)))
        }
        if issues.isEmpty {
            issues.append(.init(title: "没有发现问题", value: "一切正常", level: .ok))
        }

        let hardware = status?.hardware
        let system: [DoctorReport.Item] = [
            .init(title: "机型", value: [hardware?.model, hardware?.cpuModel, hardware?.totalRam].compactMap { $0 }.joined(separator: " · ")),
            .init(title: "系统", value: hardware?.osVersion ?? ProcessInfo.processInfo.operatingSystemVersionString),
            .init(title: "已运行", value: status?.uptime ?? "--"),
            .init(title: "健康评分", value: status?.healthScore.map { "\($0) · \(status?.healthScoreMsg ?? "")" } ?? "--"),
        ]

        let mole = MoleCLI.executableURL
        // Mole keeps bin/ next to its entry script (the bundle and a checkout do).
        let bin = mole?.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("bin")
        let knownLayout = bin.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("status.sh").path) } ?? false
        let helpersOK = knownLayout && ["status-go", "analyze-go"].allSatisfy { name in
            bin.map { FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent(name).path) } ?? false
        }
        let runtime: [DoctorReport.Item] = [
            .init(title: "Mole CLI", value: mole?.path ?? "未找到", level: mole == nil ? .problem : .ok),
            .init(title: "版本", value: moleVersion ?? "--"),
            .init(title: "打包版本", value: Bundle.main.object(forInfoDictionaryKey: "BundledMoleVersion") as? String ?? "未打包（开发模式）"),
            .init(title: "Go 组件",
                  value: !knownLayout ? "未检查（非标准安装布局）" : helpersOK ? "status-go、analyze-go 可用" : "缺失，状态和磁盘分析无法使用",
                  level: !knownLayout ? .info : helpersOK ? .ok : .problem),
            .init(title: "Burrow", value: burrowVersion()),
            .init(title: "签名", value: signingSummary()),
        ]

        let permissions: [DoctorReport.Item] = [
            .init(title: "完全磁盘访问权限", value: fullDisk ? "已开启" : "未开启", level: fullDisk ? .ok : .warning,
                  action: fullDisk ? nil : .settings(PermissionHint.fullDiskAccess.settingsURL)),
            .init(title: "辅助功能（清洁屏幕屏蔽按键）", value: AXIsProcessTrusted() ? "已开启" : "未开启",
                  level: AXIsProcessTrusted() ? .ok : .info,
                  action: AXIsProcessTrusted() ? nil : .settings(CleanScreen.accessibilitySettings)),
            .init(title: "App 管理（卸载应用）", value: "macOS 无法提前检测；被拦截时 Burrow 会提示", level: .info,
                  action: .settings(PermissionHint.appManagement.settingsURL)),
        ]

        let config: [DoctorReport.Item] = [
            .init(title: "操作日志", value: logSummary(), level: logWritable ? .ok : .problem, action: .reveal(operationsLog)),
            .init(title: "清理白名单", value: countLines(NSHomeDirectory() + "/.config/mole/whitelist").map { "\($0) 条自定义规则" } ?? "使用默认规则"),
            .init(title: "构建产物扫描位置", value: PurgePaths.load().map { $0.isEmpty ? "未设置" : $0.joined(separator: "、") } ?? "Mole 默认位置",
                  action: .page(.purge)),
        ]

        return DoctorReport(sections: [
            .init(title: DoctorReport.issuesTitle, items: issues),
            .init(title: "系统", items: system),
            .init(title: "Mole 运行环境", items: runtime),
            .init(title: "权限", items: permissions),
            .init(title: "配置", items: config),
        ])
    }

    /// TCC.db is readable only with Full Disk Access; opening it changes nothing.
    static func hasFullDiskAccess() -> Bool {
        let probe = URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db")
        guard let handle = try? FileHandle(forReadingFrom: probe) else { return false }
        try? handle.close()
        return true
    }

    static func logIsWritable() -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: operationsLog.path) { return fm.isWritableFile(atPath: operationsLog.path) }
        return fm.isWritableFile(atPath: operationsLog.deletingLastPathComponent().path)
            || !fm.fileExists(atPath: operationsLog.deletingLastPathComponent().path)
    }

    private static func logSummary() -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: operationsLog.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value
        return "\(PurgePaths.abbreviate(operationsLog.path))" + (size.map { " · \(Format.bytes($0))" } ?? " · 尚未创建")
    }

    private static func countLines(_ path: String) -> Int? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return text.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    static func burrowVersion() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "开发版"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    private static func signingSummary() -> String {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return "未打包" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-d", "-r-", Bundle.main.bundleURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return "未知" }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        if output.contains("certificate leaf") { return "本机证书（重新编译后权限保留）" }
        if output.contains("cdhash") { return "临时签名（重新编译后需重新授权）" }
        return "未知"
    }
}
