import AppKit
import Darwin
import SwiftUI

/// Read-only explanation of one process, like Mole Mac's process detail.
struct ProcessDetails {
    struct Ancestor: Hashable {
        var pid: Int
        var name: String
    }

    var pid: Int
    var name: String
    var executable: String?
    var executableMissing: Bool
    var user: String?
    var state: String?
    var elapsed: String?
    var elapsedSeconds: Int?
    var ancestors: [Ancestor]
    var app: NSRunningApplication?
    var launchdLabel: String?
    var listening: [String]

    var warnings: [String] {
        var list: [String] = []
        if executableMissing { list.append("程序文件在运行期间被替换或删除，通常是更新导致的，重启它即可。") }
        if state?.hasPrefix("Z") == true { list.append("这是僵尸进程，已经结束但没有被回收，不会自己退出。") }
        if listening.contains(where: { $0.hasPrefix("*:") || $0.hasPrefix("0.0.0.0:") || $0.hasPrefix("[::]:") }) {
            list.append("正在监听所有网络接口，局域网里的其他设备也能连接。")
        }
        if let seconds = elapsedSeconds, seconds > 90 * 86400 { list.append("已连续运行超过 90 天。") }
        return list
    }

    var summary: String {
        if let app { return "属于 \(app.localizedName ?? name)。" }
        if let launchdLabel { return "由 launchd 通过 \(launchdLabel) 保持运行。" }
        if let parent = ancestors.first, parent.pid > 1 { return "由 \(parent.name)（PID \(parent.pid)）启动。" }
        if ancestors.first?.pid == 1 { return "由系统（launchd）直接启动。" }
        return "没有找到明确的来源，可能已经脱离启动它的程序，或被系统权限隐藏。"
    }

    static func load(pid: Int, name: String) -> ProcessDetails {
        let path = executablePath(pid)
        let ps = psFields(pid, "user=,stat=,etime=")
        var ancestors: [Ancestor] = []
        var current = pid
        for _ in 0..<12 {
            guard let ppid = Int(psFields(current, "ppid=").first ?? ""), ppid > 0, ppid != current else { break }
            ancestors.append(Ancestor(pid: ppid, name: processName(ppid)))
            if ppid == 1 { break }
            current = ppid
        }
        return ProcessDetails(
            pid: pid, name: name, executable: path,
            executableMissing: path.map { !FileManager.default.fileExists(atPath: $0) } ?? false,
            user: ps.first, state: ps.count > 1 ? ps[1] : nil,
            elapsed: ps.count > 2 ? ps[2] : nil, elapsedSeconds: ps.count > 2 ? seconds(fromEtime: ps[2]) : nil,
            ancestors: ancestors,
            app: NSRunningApplication(processIdentifier: pid_t(pid)),
            launchdLabel: StartupItems.userDomainJobs().first { $0.value == pid }?.key,
            listening: listeningSockets(pid))
    }

    static func executablePath(_ pid: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid_t(pid), &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }

    static func processName(_ pid: Int) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        return proc_name(pid_t(pid), &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : "PID \(pid)"
    }

    private static func psFields(_ pid: Int, _ format: String) -> [String] {
        let out = run("/bin/ps", ["-o", format, "-p", String(pid)]) ?? ""
        return out.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// "3-04:05:06", "04:05:06" or "05:06" → seconds.
    static func seconds(fromEtime text: String) -> Int? {
        let dayParts = text.split(separator: "-")
        let days = dayParts.count == 2 ? Int(dayParts[0]) ?? 0 : 0
        let clock = (dayParts.last ?? "").split(separator: ":").compactMap { Int($0) }
        guard !clock.isEmpty else { return nil }
        return days * 86400 + clock.reduce(0) { $0 * 60 + $1 }
    }

    /// "*:8080 (TCP)", "127.0.0.1:5432 (TCP)": what the process listens on.
    static func listeningSockets(_ pid: Int) -> [String] {
        let tcp = run("/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN"]) ?? ""
        let udp = run("/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid), "-iUDP"]) ?? ""
        var sockets: [String] = []
        for (text, proto) in [(tcp, "TCP"), (udp, "UDP")] {
            for line in text.split(separator: "\n").dropFirst() {
                let fields = line.split(separator: " ", omittingEmptySubsequences: true)
                guard let name = fields.first(where: { $0.contains(":") && !$0.contains("->") && $0 != "TCP" }) else { continue }
                let entry = "\(name) (\(proto))"
                if !sockets.contains(entry) { sockets.append(entry) }
            }
        }
        return sockets
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

struct ProcessDetailSheet: View {
    let process: StatusSnapshot.Process
    @Environment(\.dismiss) private var dismiss
    @State private var details: ProcessDetails?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let icon = details?.app?.icon {
                    Image(nsImage: icon).resizable().frame(width: 32, height: 32)
                } else {
                    Image(systemName: "gearshape.2").font(.title)
                }
                VStack(alignment: .leading) {
                    Text(process.name).font(.title3.bold())
                    Text("PID \(process.pid)").foregroundStyle(.secondary)
                }
            }
            if let details {
                Text(details.summary)
                ForEach(details.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Form {
                    LabeledContent("程序") { Text(details.executable ?? "读取不到（可能属于其他用户）").textSelection(.enabled) }
                    LabeledContent("用户") { Text(details.user ?? "--") }
                    LabeledContent("已运行") { Text(details.elapsed ?? "--") }
                    if let label = details.launchdLabel { LabeledContent("launchd 服务") { Text(label).textSelection(.enabled) } }
                    LabeledContent("启动链") {
                        Text(details.ancestors.map { "\($0.name)（\($0.pid)）" }.joined(separator: " ← "))
                            .textSelection(.enabled)
                    }
                    LabeledContent("监听端口") {
                        Text(details.listening.isEmpty ? "无" : details.listening.joined(separator: "\n")).textSelection(.enabled)
                    }
                }
                .formStyle(.grouped)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            HStack {
                if let path = details?.executable, !(details?.executableMissing ?? true) {
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task {
            let pid = process.pid, name = process.name
            details = await Task.detached { ProcessDetails.load(pid: pid, name: name) }.value
        }
    }
}
