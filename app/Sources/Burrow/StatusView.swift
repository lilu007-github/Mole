import SwiftUI

struct StatusView: View {
    @State private var snapshot: StatusSnapshot?
    @State private var error: String?

    var body: some View {
        ScrollView {
            if let snapshot {
                dashboard(snapshot)
                    .padding(20)
            } else if let error {
                ContentUnavailableView("读取状态失败", systemImage: "exclamationmark.triangle", description: Text(error))
                    .padding(.top, 80)
            } else {
                ProgressView("正在读取系统状态…").padding(.top, 120)
            }
        }
        .navigationTitle("系统状态")
        .task {
            // Refresh while the view is on screen; SwiftUI cancels this on disappear.
            while !Task.isCancelled {
                do {
                    snapshot = try await MoleCLI.json(["status", "--json"], as: StatusSnapshot.self)
                    error = nil
                } catch {
                    if snapshot == nil { self.error = error.localizedDescription }
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 260), spacing: 16)]

    @ViewBuilder
    private func dashboard(_ s: StatusSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header(s)
            LazyVGrid(columns: columns, spacing: 16) {
                MetricCard(title: "CPU", symbol: "cpu", percent: s.cpu?.usage) {
                    if let cpu = s.cpu {
                        Text("负载 \(fmt(cpu.load1)) / \(fmt(cpu.load5)) / \(fmt(cpu.load15))")
                        if let cores = cpu.coreCount { Text("\(cores) 核") }
                    }
                }
                MetricCard(title: "内存", symbol: "memorychip", percent: s.memory?.usedPercent) {
                    if let m = s.memory {
                        Text("\(Format.bytes(m.used)) / \(Format.bytes(m.total))")
                        if let swap = m.swapUsed, swap > 0 { Text("交换 \(Format.bytes(swap))") }
                    }
                }
                ForEach(s.disks ?? []) { disk in
                    MetricCard(title: disk.external == true ? "外置磁盘 \(disk.mount)" : "磁盘 \(disk.mount)",
                               symbol: "internaldrive", percent: disk.usedPercent) {
                        Text("已用 \(Format.bytes(disk.used)) / \(Format.bytes(disk.total))")
                        if disk.mount == "/", let trash = s.trashSize, trash > 0 {
                            Text("废纸篓 \(Format.bytes(trash))")
                        }
                    }
                }
                if let battery = s.batteries?.first {
                    MetricCard(title: "电池", symbol: "battery.75percent", percent: battery.percent,
                               higherIsWorse: false) {
                        Text([battery.status, battery.health.map { "健康 \($0)" }]
                            .compactMap { $0 }.joined(separator: " · "))
                        if let cycles = battery.cycleCount { Text("循环 \(cycles) 次") }
                    }
                }
                networkCard(s.network ?? [])
            }
            processTable(s.topProcesses ?? [])
        }
    }

    private func header(_ s: StatusSnapshot) -> some View {
        HStack(spacing: 20) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 10)
                Circle()
                    .trim(from: 0, to: Double(s.healthScore ?? 0) / 100)
                    .stroke(scoreColor(s.healthScore), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(s.healthScore ?? 0)").font(.system(size: 30, weight: .bold, design: .rounded))
            }
            .frame(width: 90, height: 90)
            VStack(alignment: .leading, spacing: 4) {
                Text(s.healthScoreMsg ?? "健康评分").font(.title2.bold())
                Text([s.hardware?.model, s.hardware?.cpuModel, s.hardware?.totalRam, s.hardware?.osVersion]
                    .compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                if let uptime = s.uptime {
                    Text("已运行 \(uptime) · \(s.procs ?? 0) 个进程").foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private func networkCard(_ interfaces: [StatusSnapshot.Network]) -> some View {
        let active = interfaces.filter { !($0.ip ?? "").isEmpty }
        return GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                if active.isEmpty { Text("无活动网络").foregroundStyle(.secondary) }
                ForEach(active) { net in
                    HStack {
                        Text(net.name).bold()
                        Spacer()
                        Label(Format.rate(net.rxRateMbs), systemImage: "arrow.down")
                        Label(Format.rate(net.txRateMbs), systemImage: "arrow.up")
                    }
                    .font(.callout.monospacedDigit())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("网络", systemImage: "network")
        }
    }

    private func processTable(_ processes: [StatusSnapshot.Process]) -> some View {
        GroupBox {
            Table(Array(processes.prefix(10))) {
                TableColumn("进程", value: \.name)
                TableColumn("PID") { Text("\($0.pid)").monospacedDigit() }.width(70)
                TableColumn("CPU") { Text(Format.percent($0.cpu)).monospacedDigit() }.width(70)
                TableColumn("内存") { Text(Format.bytes($0.memoryBytes)).monospacedDigit() }.width(90)
            }
            .frame(height: 300)
        } label: {
            Label("占用最高的进程", systemImage: "list.number")
        }
    }

    private func fmt(_ value: Double?) -> String {
        value.map { String(format: "%.2f", $0) } ?? "--"
    }

    private func scoreColor(_ score: Int?) -> Color {
        switch score ?? 0 {
        case 80...: .green
        case 60..<80: .yellow
        default: .red
        }
    }
}

struct MetricCard<Detail: View>: View {
    let title: String
    let symbol: String
    let percent: Double?
    var higherIsWorse = true
    @ViewBuilder let detail: Detail

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Format.percent(percent)).font(.system(size: 28, weight: .semibold, design: .rounded))
                    Spacer()
                }
                ProgressView(value: min(max((percent ?? 0) / 100, 0), 1))
                    .tint(tint)
                VStack(alignment: .leading, spacing: 2) { detail }
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(title, systemImage: symbol)
        }
    }

    private var tint: Color {
        let p = percent ?? 0
        let level = higherIsWorse ? p : 100 - p
        return level > 85 ? .red : level > 65 ? .orange : .accentColor
    }
}
