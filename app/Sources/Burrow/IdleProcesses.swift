import AppKit
import SwiftUI

/// Developer processes that keep running after the tool that started them is
/// gone: build daemons with no IDE open, and dev servers whose launcher quit.
struct IdleProcess: Identifiable, Hashable {
    var pid: Int
    var name: String
    var reason: String
    var elapsed: String
    var memoryBytes: Int64
    var id: Int { pid }
}

enum IdleProcesses {
    struct Row {
        var pid: Int
        var ppid: Int
        var elapsed: String
        var rssKB: Int64
        var user: String
        var command: String
    }

    static let ideBundles = ["com.google.android.studio", "com.jetbrains.intellij", "com.jetbrains.intellij.ce",
                             "com.jetbrains.pycharm", "com.jetbrains.goland", "com.jetbrains.WebStorm",
                             "com.jetbrains.fleet", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"]
    static let devServerMarkers = ["vite", "next dev", "next-server", "webpack", "nodemon", "uvicorn", "flask run",
                                   "jupyter", "http.server", "react-scripts start", "astro dev", "nuxt dev"]

    static func scan() -> [IdleProcess] {
        let ideOpen = NSWorkspace.shared.runningApplications.contains { ideBundles.contains($0.bundleIdentifier ?? "") }
        return find(in: psRows(), user: NSUserName(), ideOpen: ideOpen)
    }

    /// Pure classification over a `ps` snapshot.
    static func find(in rows: [Row], user: String, ideOpen: Bool) -> [IdleProcess] {
        rows.compactMap { row in
            guard row.user == user else { return nil }
            let name = (row.command.split(separator: " ").first.map(String.init) ?? "").split(separator: "/").last.map(String.init) ?? ""
            var reason: String?
            if row.command.contains("GradleDaemon") || row.command.contains("org.gradle.launcher.daemon") {
                if !ideOpen { reason = "Gradle 守护进程，没有打开的 IDE" }
            } else if row.command.contains("KotlinCompileDaemon") {
                if !ideOpen { reason = "Kotlin 编译守护进程，没有打开的 IDE" }
            } else if row.ppid == 1, ["node", "bun", "deno", "python", "python3", "ruby"].contains(where: { name.hasPrefix($0) }),
                      let marker = devServerMarkers.first(where: { row.command.contains($0) }) {
                reason = "\(marker) 开发服务器，启动它的终端已经关闭"
            }
            guard let reason else { return nil }
            let display = row.command.contains("Gradle") ? "Gradle Daemon"
                : row.command.contains("Kotlin") ? "Kotlin Daemon" : name
            return IdleProcess(pid: row.pid, name: display, reason: reason, elapsed: row.elapsed,
                               memoryBytes: row.rssKB * 1024)
        }
    }

    static func psRows() -> [Row] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,etime=,rss=,user=,command="]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true).map(String.init)
            guard parts.count == 6, let pid = Int(parts[0]), let ppid = Int(parts[1]), let rss = Int64(parts[3]) else { return nil }
            return Row(pid: pid, ppid: ppid, elapsed: parts[2], rssKB: rss, user: parts[4], command: parts[5])
        }
    }
}

/// Shown on the Status page only when something idle is found.
struct IdleProcessesSection: View {
    @State private var items: [IdleProcess] = []
    @State private var stopping: IdleProcess?
    @State private var message: String?

    var body: some View {
        Group {
            if !items.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(items) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(item.name)（PID \(item.pid)）")
                                    Text("\(item.reason) · 已运行 \(item.elapsed)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(Format.bytes(item.memoryBytes)).monospacedDigit().foregroundStyle(.secondary)
                                Button("结束") { stopping = item }
                            }
                        }
                        if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                    }
                } label: {
                    Label("闲置的开发进程", systemImage: "moon.zzz")
                }
            }
        }
        .task {
            while !Task.isCancelled {
                items = await Task.detached { IdleProcesses.scan() }.value
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .confirmationDialog("结束 \(stopping?.name ?? "")？", isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } })) {
            Button("结束", role: .destructive) {
                guard let item = stopping else { return }
                message = ProcessControl.quit(pid: item.pid, name: item.name, force: false) ?? "已请求 \(item.name) 退出。"
                items.removeAll { $0.pid == item.pid }
                stopping = nil
            }
            Button("取消", role: .cancel) { stopping = nil }
        } message: {
            Text("下次构建或启动开发服务器时会自动重新启动。")
        }
    }
}
