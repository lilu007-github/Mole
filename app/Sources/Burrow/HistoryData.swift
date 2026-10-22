import Foundation

// Decoded from `mo history --json` (lib/core/history.sh).
struct HistoryReport: Decodable {
    struct Session: Decodable, Identifiable {
        struct Actions: Decodable {
            var removed = 0
            var trashed = 0
            var skipped = 0
            var failed = 0
            var rebuilt = 0
            var other = 0
        }

        var command: String
        var runId: String?
        var startedAt: String
        var endedAt: String?
        var items: Int?
        var size: String?
        var operationCount: Int?
        var failedTasks: Int?
        var actions: Actions?

        var id: String { (runId ?? "") + startedAt + command }

        var isDryRun: Bool { command.hasSuffix("-dry-run") }
        var baseCommand: String { isDryRun ? String(command.dropLast("-dry-run".count)) : command }

        /// Nothing happened: listing apps, for example, opens an empty uninstall session.
        var isEmpty: Bool {
            let a = actions ?? Actions()
            return (items ?? 0) == 0 && (operationCount ?? 0) == 0
                && a.removed + a.trashed + a.skipped + a.failed + a.rebuilt + a.other == 0
        }

        var startDate: Date? { HistoryReport.parseDate(startedAt) }
        var sizeBytes: Int64 { HistoryReport.parseSize(size ?? "") }
    }

    struct Deletion: Decodable, Identifiable {
        var timestamp: String
        var mode: String?
        var status: String?
        var sizeKb: Int64?
        var path: String
        var id: String { timestamp + path }
        var date: Date? { ISO8601DateFormatter.mole.date(from: timestamp) }
    }

    var sessions: [Session]
    var deletions: [Deletion]

    /// "543.4MB", "12KB", "0B", "1.2GB+" → bytes (Mole prints decimal units).
    static func parseSize(_ text: String) -> Int64 {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "+", with: "")
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3), ("B", 1)]
        for (unit, factor) in units where trimmed.uppercased().hasSuffix(unit) {
            let number = trimmed.dropLast(unit.count).trimmingCharacters(in: .whitespaces)
            return Int64((Double(number) ?? 0) * factor)
        }
        return 0
    }

    static func parseDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text)
    }

    /// Chinese name for a Mole command, as shown in the list.
    static func title(for command: String) -> String {
        switch command {
        case "clean": "清理"
        case "uninstall": "卸载应用"
        case "optimize": "优化"
        case "installer": "安装包"
        case "purge": "项目构建产物"
        case "analyze": "磁盘分析"
        case "slim": "精简 App"
        case "touchid": "Touch ID"
        case "update": "更新 Mole"
        case "remove": "移除 Mole"
        case "burrow-ai": "AI 旧对话"
        default: command
        }
    }

    static func symbol(for command: String) -> String {
        switch command {
        case "clean": "sparkles"
        case "uninstall": "trash"
        case "optimize": "wand.and.stars"
        case "installer": "shippingbox"
        case "purge": "hammer"
        case "analyze": "chart.pie"
        case "burrow-ai": "brain"
        default: "terminal"
        }
    }
}

extension ISO8601DateFormatter {
    /// Mole writes "2026-10-22T00:59:13-0700".
    static let mole: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

/// One row of ~/Library/Logs/mole/operations.log:
/// "[2026-10-22 00:59:13] [uninstall run=<id>] TRASHED /Applications/X.app (8660KB)".
struct OperationEntry: Identifiable, Hashable {
    var time: String
    var command: String
    var runID: String?
    var action: String
    var path: String
    var detail: String?
    var id: String { time + action + path }

    static func parse(_ line: String) -> OperationEntry? {
        let pattern = #/^\[([^\]]+)\] \[(\S+)(?: run=(\S+))?\] ([A-Z_]+) (.+?)(?: \(([^()]*)\))?$/#
        guard let m = line.firstMatch(of: pattern) else { return nil }
        return OperationEntry(time: String(m.1), command: String(m.2), runID: m.3.map(String.init),
                              action: String(m.4), path: String(m.5), detail: m.6.map(String.init))
    }

    /// Entries written by the run with this id, read from the log (last 8 MB at most).
    static func entries(runID: String, logURL: URL = OperationLog.fileURL) -> [OperationEntry] {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 8 * 1024 * 1024
        try? handle.seek(toOffset: size > window ? size - window : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        return text.split(separator: "\n").compactMap { parse(String($0)) }.filter { $0.runID == runID }
    }

    var actionTitle: String {
        switch action {
        case "REMOVED": "已删除"
        case "TRASHED": "移到废纸篓"
        case "SKIPPED": "已跳过"
        case "FAILED": "失败"
        case "REBUILT": "已重建"
        default: action
        }
    }
}
