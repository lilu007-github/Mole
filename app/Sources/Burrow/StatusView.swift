import AppKit
import Charts
import SwiftUI

struct StatusView: View {
    private let monitor = StatusMonitor.shared
    @State private var quitting: (process: StatusSnapshot.Process, force: Bool)?
    @State private var quitMessage: String?
    @State private var inspecting: StatusSnapshot.Process?

    var body: some View {
        ScrollView {
            if let snapshot = monitor.snapshot {
                dashboard(snapshot, history: monitor.history)
                    .padding(20)
            } else if let error = monitor.error {
                ContentUnavailableView("读取状态失败", systemImage: "exclamationmark.triangle", description: Text(error))
                    .padding(.top, 80)
            } else {
                ProgressView("正在读取系统状态…").padding(.top, 120)
            }
        }
        .navigationTitle("系统状态")
        // Live 3-second updates while this page is on screen.
        .onAppear { monitor.beginLive() }
        .onDisappear { monitor.endLive() }
    }

    private let columns = [GridItem(.adaptive(minimum: 280), spacing: 16, alignment: .top)]

    @ViewBuilder
    private func dashboard(_ s: StatusSnapshot, history: [StatusSample]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header(s)
            LazyVGrid(columns: columns, spacing: 16) {
                cpuCard(s, history)
                memoryCard(s, history)
                networkCard(s, history)
                ForEach(s.disks ?? []) { diskCard($0, trash: $0.mount == "/" ? s.trashSize : nil) }
                if let battery = s.batteries?.first { batteryCard(battery, thermal: s.thermal) }
                powerCard(s, history)
                if let gpu = s.gpu?.first, let usage = gpu.usage, usage >= 0 { gpuCard(gpu, usage: usage) }
            }
            IdleProcessesSection()
            bluetoothRow(s.bluetooth ?? [])
            processTable(s.topProcesses ?? [])
        }
    }

    // MARK: Header

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
            VStack(alignment: .leading, spacing: 8) {
                Text(s.healthScoreMsg ?? "健康评分").font(.title2.bold())
                HStack(spacing: 6) {
                    ForEach(chips(s), id: \.self) { Chip(text: $0) }
                }
                HStack(spacing: 12) {
                    if let uptime = s.uptime {
                        Text("已运行 \(uptime) · \(s.procs ?? 0) 个进程").foregroundStyle(.secondary)
                    }
                    PrivacyBadges(state: monitor.privacy)
                }
            }
            Spacer()
        }
    }

    private func chips(_ s: StatusSnapshot) -> [String] {
        var items = [s.hardware?.model, s.hardware?.cpuModel, s.hardware?.totalRam, s.hardware?.osVersion]
        if let gpu = s.gpu?.first, let cores = gpu.coreCount, cores > 0 { items.append("\(cores) 核 GPU") }
        return items.compactMap { $0 }.filter { !$0.isEmpty }
    }

    // MARK: Cards

    private func cpuCard(_ s: StatusSnapshot, _ history: [StatusSample]) -> some View {
        let cpu = s.cpu
        let temp = s.thermal?.cpuTemp.flatMap { $0 > 0 ? $0 : nil }
        return Card(title: "CPU", symbol: "cpu", badge: temp.map { String(format: "%.0f°C", $0) }) {
            BigValue(value: Format.percent(cpu?.usage))
            Sparkline(points: history.map { ($0.date, $0.cpu) }, color: .green, maxY: 100)
            if let cores = cpu?.perCore, !cores.isEmpty { CoreBars(values: cores) }
            Text(cpuDetail(cpu)).detailStyle()
        }
    }

    private func cpuDetail(_ cpu: StatusSnapshot.CPU?) -> String {
        guard let cpu else { return "" }
        var parts: [String] = []
        if let p = cpu.pCoreCount, let e = cpu.eCoreCount, p + e > 0 {
            parts.append("\(p) 性能核 + \(e) 能效核")
        } else if let n = cpu.coreCount {
            parts.append("\(n) 核")
        }
        if let l1 = cpu.load1, let l5 = cpu.load5, let l15 = cpu.load15 {
            parts.append(String(format: "负载 %.2f / %.2f / %.2f", l1, l5, l15))
        }
        return parts.joined(separator: " · ")
    }

    private func memoryCard(_ s: StatusSnapshot, _ history: [StatusSample]) -> some View {
        let m = s.memory
        return Card(title: "内存", symbol: "memorychip", badge: pressureText(m?.pressure),
                    badgeColor: pressureColor(m?.pressure)) {
            BigValue(value: Format.percent(m?.usedPercent))
            Sparkline(points: history.map { ($0.date, $0.memory) }, color: .orange, maxY: 100)
            Text(memoryDetail(m)).detailStyle()
        }
    }

    private func memoryDetail(_ m: StatusSnapshot.Memory?) -> String {
        guard let m else { return "" }
        var text = "\(Format.bytes(m.used)) / \(Format.bytes(m.total))"
        if let swap = m.swapUsed, swap > 0 { text += " · 交换 \(Format.bytes(swap))" }
        return text
    }

    private func pressureText(_ pressure: String?) -> String? {
        switch pressure {
        case "normal": "压力正常"
        case "warn": "压力偏高"
        case "critical": "压力很高"
        default: nil
        }
    }

    private func pressureColor(_ pressure: String?) -> Color {
        switch pressure {
        case "warn": .orange
        case "critical": .red
        default: .secondary
        }
    }

    private func networkCard(_ s: StatusSnapshot, _ history: [StatusSample]) -> some View {
        let net = monitor.activeNetwork
        let proxy = s.proxy?.enabled == true ? "代理 \(s.proxy?.type ?? "")" : nil
        return Card(title: "网络", symbol: "network", badge: proxy) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Label(Format.rate(net?.rxRateMbs), systemImage: "arrow.down")
                    .foregroundStyle(.blue)
                Label(Format.rate(net?.txRateMbs), systemImage: "arrow.up")
                    .foregroundStyle(.purple)
            }
            .font(.title3.weight(.semibold).monospacedDigit())
            NetworkChart(samples: history)
            HStack {
                Text(net.map { "\($0.name) · \($0.ip ?? "")" } ?? "无活动网络").detailStyle()
                if let ip = net?.ip, !ip.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ip, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("拷贝 IP 地址")
                }
            }
        }
    }

    private func diskCard(_ disk: StatusSnapshot.Disk, trash: Int64?) -> some View {
        let free = (disk.total ?? 0) - (disk.used ?? 0)
        return Card(title: disk.external == true ? "外置磁盘" : "可用空间", symbol: "internaldrive",
                    badge: disk.mount == "/" ? nil : disk.mount) {
            BigValue(value: Format.bytes(free))
            ProgressView(value: min(max((disk.usedPercent ?? 0) / 100, 0), 1))
                .tint((disk.usedPercent ?? 0) > 85 ? .red : .accentColor)
            Text(diskDetail(disk, trash: trash)).detailStyle()
        }
    }

    private func diskDetail(_ disk: StatusSnapshot.Disk, trash: Int64?) -> String {
        var text = "已用 \(Format.bytes(disk.used)) / \(Format.bytes(disk.total)) · \(Format.percent(disk.usedPercent))"
        if let trash, trash > 0 { text += " · 废纸篓 \(Format.bytes(trash))" }
        return text
    }

    private func batteryCard(_ b: StatusSnapshot.Battery, thermal: StatusSnapshot.Thermal?) -> some View {
        let temp = thermal?.batteryTemp.flatMap { $0 > 0 ? $0 : nil }
        return Card(title: "电池", symbol: "battery.75percent",
                    badge: b.health.map { "健康 \($0)" }) {
            BigValue(value: Format.percent(b.percent))
            ProgressView(value: min(max((b.percent ?? 0) / 100, 0), 1))
                .tint((b.percent ?? 100) < 20 ? .red : .green)
            Text([batteryStatus(b.status), b.timeLeft.flatMap { $0.isEmpty ? nil : "剩余 \($0)" },
                  b.cycleCount.map { "循环 \($0) 次" }, temp.map { String(format: "%.1f°C", $0) }]
                .compactMap { $0 }.joined(separator: " · "))
                .detailStyle()
        }
    }

    private func batteryStatus(_ status: String?) -> String? {
        switch status {
        case "AC": "已接电源"
        case "Charging", "charging": "充电中"
        case "Discharging", "discharging": "使用电池"
        case "Charged", "charged": "已充满"
        default: status
        }
    }

    private func powerCard(_ s: StatusSnapshot, _ history: [StatusSample]) -> some View {
        let t = s.thermal
        let power = t?.systemPower.flatMap { $0 > 0 ? $0 : nil }
        let points = history.compactMap { sample in sample.power.map { (sample.date, $0) } }
        return Card(title: "功耗与温度", symbol: "bolt", badge: fanText(t)) {
            BigValue(value: power.map { String(format: "%.1f W", $0) } ?? "--")
            Sparkline(points: points, color: .yellow, maxY: nil)
            Text(powerDetail(t)).detailStyle()
        }
    }

    private func fanText(_ t: StatusSnapshot.Thermal?) -> String? {
        guard let t, (t.fanCount ?? 0) > 0 else { return nil }
        return "风扇 \(t.fanSpeed ?? 0) RPM"
    }

    private func powerDetail(_ t: StatusSnapshot.Thermal?) -> String {
        guard let t else { return "" }
        var parts: [String] = []
        if let adapter = t.adapterPower, adapter > 0 { parts.append(String(format: "电源适配器 %.0f W", adapter)) }
        if let battery = t.batteryPower, battery > 0 { parts.append(String(format: "电池放电 %.1f W", battery)) }
        if let gpu = t.gpuTemp, gpu > 0 { parts.append(String(format: "GPU %.0f°C", gpu)) }
        return parts.isEmpty ? "系统整机功耗" : parts.joined(separator: " · ")
    }

    private func gpuCard(_ gpu: StatusSnapshot.GPU, usage: Double) -> some View {
        Card(title: "GPU", symbol: "square.stack.3d.up", badge: gpu.coreCount.map { "\($0) 核" }) {
            BigValue(value: Format.percent(usage))
            ProgressView(value: min(max(usage / 100, 0), 1))
            Text(gpu.name ?? "").detailStyle()
        }
    }

    // MARK: Lists

    @ViewBuilder
    private func bluetoothRow(_ devices: [StatusSnapshot.Bluetooth]) -> some View {
        let connected = devices.filter { $0.connected == true }
        if !connected.isEmpty {
            GroupBox {
                HStack(spacing: 18) {
                    ForEach(connected) { device in
                        Label {
                            Text(device.name)
                            if let battery = device.battery, !battery.isEmpty {
                                Text(battery).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "dot.radiowaves.left.and.right")
                        }
                    }
                    Spacer()
                }
            } label: {
                Label("已连接的蓝牙设备", systemImage: "wave.3.right")
            }
        }
    }

    private func processTable(_ processes: [StatusSnapshot.Process]) -> some View {
        GroupBox {
            Table(Array(processes.prefix(10))) {
                TableColumn("进程", value: \.name)
                TableColumn("PID") { Text("\($0.pid)").monospacedDigit() }.width(70)
                TableColumn("CPU") { p in
                    HStack {
                        ProgressView(value: min(max((p.cpu ?? 0) / 100, 0), 1)).frame(width: 50)
                        Text(Format.percent(p.cpu)).monospacedDigit()
                    }
                }
                .width(110)
                TableColumn("内存") { Text(Format.bytes($0.memoryBytes)).monospacedDigit() }.width(90)
            }
            .frame(height: 220)
            .contextMenu(forSelectionType: StatusSnapshot.Process.ID.self) { ids in
                if let process = processes.first(where: { ids.contains($0.id) }) {
                    Button("详情…") { inspecting = process }
                    Divider()
                    Button("退出 \(process.name)") { quitting = (process, false) }
                        .disabled(ProcessControl.refusal(pid: process.pid, name: process.name) != nil)
                    Button("强制退出 \(process.name)") { quitting = (process, true) }
                        .disabled(ProcessControl.refusal(pid: process.pid, name: process.name) != nil)
                    Divider()
                    Button("拷贝 PID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(String(process.pid), forType: .string)
                    }
                }
            }
            if let quitMessage {
                Text(quitMessage).font(.caption).foregroundStyle(.secondary)
            }
        } label: {
            Label("占用最高的进程（右键查看详情或退出）", systemImage: "list.number")
        }
        .sheet(item: $inspecting) { ProcessDetailSheet(process: $0) }
        .confirmationDialog(quitTitle, isPresented: Binding(get: { quitting != nil }, set: { if !$0 { quitting = nil } })) {
            Button(quitting?.force == true ? "强制退出" : "退出", role: .destructive) {
                guard let target = quitting else { return }
                let error = ProcessControl.quit(pid: target.process.pid, name: target.process.name, force: target.force)
                quitMessage = error ?? "已向 \(target.process.name) 发送退出请求。"
                quitting = nil
            }
            Button("取消", role: .cancel) { quitting = nil }
        } message: {
            Text(quitting?.force == true
                ? "强制退出不会给程序保存的机会，未保存的内容会丢失。"
                : "程序会像从 Dock 退出一样正常关闭，可能会提示保存。")
        }
    }

    private var quitTitle: String {
        guard let target = quitting else { return "" }
        return "\(target.force ? "强制退出" : "退出") \(target.process.name)（PID \(target.process.pid)）？"
    }

    private func scoreColor(_ score: Int?) -> Color {
        switch score ?? 0 {
        case 80...: .green
        case 60..<80: .yellow
        default: .red
        }
    }
}

// MARK: - Building blocks

private struct Card<Content: View>: View {
    let title: String
    let symbol: String
    var badge: String?
    var badgeColor: Color = .secondary
    @ViewBuilder let content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) { content }
                .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        } label: {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                if let badge { Chip(text: badge, color: badgeColor) }
            }
        }
    }
}

private struct Chip: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
    }
}

private struct BigValue: View {
    let value: String

    var body: some View {
        Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
    }
}

/// A small filled line chart of recent samples; axes hidden.
private struct Sparkline: View {
    let points: [(Date, Double)]
    let color: Color
    var maxY: Double?

    var body: some View {
        Chart {
            ForEach(points, id: \.0) { point in
                AreaMark(x: .value("时间", point.0), y: .value("值", point.1))
                    .foregroundStyle(color.opacity(0.18))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("时间", point.0), y: .value("值", point.1))
                    .foregroundStyle(color)
                    .interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: 0...(maxY ?? max(points.map(\.1).max() ?? 1, 1)))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 44)
        .overlay {
            if points.count < 2 {
                Text("收集数据中…").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Download and upload as two lines on one chart.
private struct NetworkChart: View {
    let samples: [StatusSample]

    var body: some View {
        Chart {
            ForEach(samples) { s in
                LineMark(x: .value("时间", s.date), y: .value("MB/s", s.download), series: .value("方向", "下载"))
                    .foregroundStyle(.blue)
                LineMark(x: .value("时间", s.date), y: .value("MB/s", s.upload), series: .value("方向", "上传"))
                    .foregroundStyle(.purple)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 44)
    }
}

/// One thin bar per CPU core.
private struct CoreBars: View {
    let values: [Double]

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                RoundedRectangle(cornerRadius: 2)
                    .fill(value > 85 ? Color.red : Color.green.opacity(0.75))
                    .frame(height: max(2, 24 * min(value, 100) / 100))
                    .frame(maxWidth: .infinity, maxHeight: 24, alignment: .bottom)
            }
        }
        .frame(height: 24)
    }
}

private extension Text {
    func detailStyle() -> some View {
        font(.callout).foregroundStyle(.secondary).lineLimit(2)
    }
}

/// Camera and microphone use, as macOS shows with its orange and green dots.
struct PrivacyBadges: View {
    let state: PrivacyMonitor.State

    var body: some View {
        HStack(spacing: 8) {
            Label(state.camera ? "摄像头使用中" : "摄像头未使用", systemImage: state.camera ? "video.fill" : "video.slash")
                .foregroundStyle(state.camera ? Color.green : Color.secondary)
            Label(state.microphone ? "麦克风使用中" : "麦克风未使用", systemImage: state.microphone ? "mic.fill" : "mic.slash")
                .foregroundStyle(state.microphone ? Color.orange : Color.secondary)
        }
        .font(.caption)
    }
}
