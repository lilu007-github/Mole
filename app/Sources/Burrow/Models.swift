import Foundation

// Decoded from `mo status --json` (cmd/status). Fields are optional so a
// missing sensor or a newer CLI never breaks the dashboard.
struct StatusSnapshot: Decodable {
    struct Hardware: Decodable {
        var model: String?
        var cpuModel: String?
        var totalRam: String?
        var osVersion: String?
    }

    struct CPU: Decodable {
        var usage: Double?
        var perCore: [Double]?
        var load1: Double?
        var load5: Double?
        var load15: Double?
        var coreCount: Int?
        var pCoreCount: Int?
        var eCoreCount: Int?
    }

    struct GPU: Decodable {
        var name: String?
        var usage: Double?
        var coreCount: Int?
    }

    struct Thermal: Decodable {
        var cpuTemp: Double?
        var gpuTemp: Double?
        var batteryTemp: Double?
        var fanSpeed: Int?
        var fanCount: Int?
        var systemPower: Double?
        var adapterPower: Double?
        var batteryPower: Double?
    }

    struct Proxy: Decodable {
        var enabled: Bool?
        var type: String?
        var host: String?
    }

    struct Bluetooth: Decodable, Identifiable {
        var name: String
        var connected: Bool?
        var battery: String?
        var id: String { name }
    }

    struct Memory: Decodable {
        var used: Int64?
        var total: Int64?
        var usedPercent: Double?
        var swapUsed: Int64?
        var swapTotal: Int64?
        /// normal / warn / critical, empty when unknown.
        var pressure: String?
    }

    struct Disk: Decodable, Identifiable {
        var mount: String
        var used: Int64?
        var total: Int64?
        var usedPercent: Double?
        var external: Bool?
        var id: String { mount }
    }

    struct Battery: Decodable {
        var percent: Double?
        var status: String?
        var health: String?
        var cycleCount: Int?
        var timeLeft: String?
    }

    struct Network: Decodable, Identifiable {
        var name: String
        var rxRateMbs: Double?
        var txRateMbs: Double?
        var ip: String?
        var id: String { name }
    }

    struct Process: Decodable, Identifiable {
        var pid: Int
        var name: String
        var cpu: Double?
        var memoryBytes: Int64?
        var id: Int { pid }
    }

    var host: String?
    var uptime: String?
    var procs: Int?
    var hardware: Hardware?
    var healthScore: Int?
    var healthScoreMsg: String?
    var cpu: CPU?
    var gpu: [GPU]?
    var thermal: Thermal?
    var proxy: Proxy?
    var bluetooth: [Bluetooth]?
    var memory: Memory?
    var disks: [Disk]?
    var trashSize: Int64?
    var network: [Network]?
    var batteries: [Battery]?
    var topProcesses: [Process]?
}

// Decoded from `mo analyze --json [path]` (cmd/analyze/json.go).
struct AnalyzeResult: Decodable {
    struct Entry: Decodable, Identifiable {
        var name: String
        var path: String
        var size: Int64
        var isDir: Bool
        var insight: Bool?
        var scanStatus: String?
        var lastAccess: String?
        var id: String { path + (insight == true ? "#insight" : "") }
    }

    struct FileEntry: Decodable, Identifiable {
        var name: String
        var path: String
        var size: Int64
        var id: String { path }
    }

    var scanStatus: String?
    var path: String
    var overview: Bool
    var entries: [Entry]
    var largeFiles: [FileEntry]?
    var totalSize: Int64?
}

// Decoded from `mo uninstall --list`, which prints JSON when stdout is not a terminal.
struct InstalledApp: Decodable, Identifiable, Hashable {
    var name: String
    var bundleId: String?
    var source: String?
    var uninstallName: String
    var path: String
    var size: String?
    var id: String { path }
}

enum Format {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false // "0 KB", not "Zero KB"
        return formatter
    }()

    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "--" }
        return byteFormatter.string(fromByteCount: value)
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.0f%%", value)
    }

    static func rate(_ mbPerSecond: Double?) -> String {
        guard let mbPerSecond else { return "--" }
        return bytes(Int64(mbPerSecond * 1_048_576)) + "/s"
    }
}
