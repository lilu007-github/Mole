import AppKit
import SwiftUI

enum MenuBarSettings {
    static let showKey = "showMenuBar"
    /// Older builds stored a Bool for "show network speed"; read once as a fallback.
    static let speedKey = "menuBarShowsSpeed"
    static let metricKey = "menuBarMetric"
    static let hideDockKey = "hideDockIcon"
    static let allowDisplaySleepKey = "keepAwakeAllowsDisplaySleep"
}

/// What the menu bar icon shows next to it.
enum MenuBarMetric: String, CaseIterable, Identifiable {
    case none, cpu, memory, network, battery
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "只显示图标"
        case .cpu: "CPU"
        case .memory: "内存"
        case .network: "网速"
        case .battery: "电池"
        }
    }

    static var saved: MenuBarMetric {
        if let raw = UserDefaults.standard.string(forKey: MenuBarSettings.metricKey), let metric = MenuBarMetric(rawValue: raw) {
            return metric
        }
        return UserDefaults.standard.bool(forKey: MenuBarSettings.speedKey) ? .network : .none
    }

    /// The short text for the menu bar, or nil when nothing should show.
    func text(_ snapshot: StatusSnapshot?, network: StatusSnapshot.Network?) -> String? {
        switch self {
        case .none: return nil
        case .cpu: return snapshot?.cpu?.usage.map { "CPU \(Int($0.rounded()))%" }
        case .memory: return snapshot?.memory?.usedPercent.map { "内存 \(Int($0.rounded()))%" }
        case .battery: return snapshot?.batteries?.first?.percent.map { "\(Int($0))%" }
        case .network:
            guard let network else { return nil }
            return "↓\(MenuBarLabel.compact(network.rxRateMbs)) ↑\(MenuBarLabel.compact(network.txRateMbs))"
        }
    }
}

/// The menu bar icon: a cup while keep-awake is on, plus the chosen metric.
struct MenuBarLabel: View {
    @AppStorage(MenuBarSettings.metricKey) private var metricRaw = MenuBarMetric.saved.rawValue
    private let monitor = StatusMonitor.shared
    private let keepAwake = KeepAwake.shared

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: keepAwake.isActive ? "cup.and.saucer.fill" : "hare")
            if let text = (MenuBarMetric(rawValue: metricRaw) ?? .none).text(monitor.snapshot, network: monitor.activeNetwork) {
                Text(text).monospacedDigit()
            }
        }
        .task { monitor.start() }
    }

    /// "1.2M" / "340K": short enough for the menu bar.
    static func compact(_ mbPerSecond: Double?) -> String {
        let kb = (mbPerSecond ?? 0) * 1024
        return kb >= 1024 ? String(format: "%.1fM", kb / 1024) : String(format: "%.0fK", kb)
    }
}

/// The panel that opens from the menu bar icon.
struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage(MenuBarSettings.allowDisplaySleepKey) private var allowDisplaySleep = false
    @State private var ejectError: String?
    private let monitor = StatusMonitor.shared
    private let keepAwake = KeepAwake.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let s = monitor.snapshot {
                summary(s)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            Divider()
            keepAwakeSection
            ejectSection
            Divider()
            HStack(spacing: 8) {
                Menu {
                    ForEach(CleanScreen.durations, id: \.label) { option in
                        Button(option.label) { CleanScreen.shared.start(duration: option.seconds) }
                    }
                } label: {
                    Label("清洁屏幕", systemImage: "paintbrush")
                }
                .fixedSize()
                Button {
                    openWindow(id: "doctor")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("诊断", systemImage: "stethoscope")
                }
                Button {
                    openWindow(id: "about")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("关于", systemImage: "info.circle")
                }
            }
            .controlSize(.small)
            Divider()
            HStack {
                Button("打开 Burrow") {
                    MainWindow.show(openWindow)
                }
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                Button("退出") {
                    AppSettings.quitRequested = true
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { monitor.beginLive() }
        .onDisappear { monitor.endLive() }
    }

    private func summary(_ s: StatusSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(s.healthScore ?? 0)").font(.system(size: 28, weight: .bold, design: .rounded))
                Text(s.healthScoreMsg ?? "").foregroundStyle(.secondary).lineLimit(1)
            }
            MiniMeter(title: "CPU", percent: s.cpu?.usage)
            MiniMeter(title: "内存", percent: s.memory?.usedPercent)
            if let disk = s.disks?.first(where: { $0.mount == "/" }) {
                MiniMeter(title: "磁盘", percent: disk.usedPercent,
                          detail: "剩余 \(Format.bytes((disk.total ?? 0) - (disk.used ?? 0)))")
            }
            if let net = monitor.activeNetwork {
                HStack {
                    Text("网络").frame(width: 34, alignment: .leading)
                    Label(Format.rate(net.rxRateMbs), systemImage: "arrow.down")
                    Spacer()
                    Label(Format.rate(net.txRateMbs), systemImage: "arrow.up")
                }
                .font(.callout.monospacedDigit())
            }
        }
    }

    /// External drives with an eject button; hidden when none are mounted.
    @ViewBuilder
    private var ejectSection: some View {
        let volumes = ExternalCleanSheet.mountedVolumes()
        if !volumes.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Label("外置磁盘", systemImage: "externaldrive")
                ForEach(volumes) { volume in
                    HStack {
                        Text(volume.name).lineLimit(1)
                        Spacer()
                        Button("推出") { eject(volume) }.controlSize(.small)
                    }
                }
                if let ejectError { Text(ejectError).font(.caption).foregroundStyle(.orange) }
            }
        }
    }

    private func eject(_ volume: ExternalCleanSheet.Volume) {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
            ejectError = nil
        } catch {
            ejectError = "无法推出 \(volume.name)：可能有 App 正在使用它。"
        }
    }

    private var keepAwakeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("保持常亮", systemImage: "cup.and.saucer")
                Spacer()
                Toggle("", isOn: Binding(
                    get: { keepAwake.isActive },
                    set: { on in
                        on ? keepAwake.enable(duration: nil, allowDisplaySleep: allowDisplaySleep)
                            : keepAwake.disable()
                    }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }
            Text(keepAwake.statusText).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(KeepAwake.durations.dropFirst(), id: \.label) { option in
                    Button(option.label) {
                        keepAwake.enable(duration: option.seconds, allowDisplaySleep: allowDisplaySleep)
                    }
                    .controlSize(.small)
                }
            }
            Toggle("电量低于 20% 时暂停（接电后恢复）", isOn: Binding(
                get: { KeepAwake.pausesOnLowBattery },
                set: { UserDefaults.standard.set($0, forKey: KeepAwake.pauseOnLowBatteryKey) }))
                .controlSize(.small)
            Toggle("允许屏幕关闭（任务继续运行）", isOn: $allowDisplaySleep)
                .controlSize(.small)
                .onChange(of: allowDisplaySleep) { _, allow in
                    // Re-apply with the same end time so the change takes effect now.
                    guard keepAwake.isActive else { return }
                    let remaining = keepAwake.until.map { $0.timeIntervalSinceNow }
                    keepAwake.enable(duration: remaining, allowDisplaySleep: allow)
                }
        }
    }
}

private struct MiniMeter: View {
    let title: String
    let percent: Double?
    var detail: String?

    var body: some View {
        HStack {
            Text(title).frame(width: 34, alignment: .leading)
            ProgressView(value: min(max((percent ?? 0) / 100, 0), 1))
                .tint((percent ?? 0) > 85 ? .red : .accentColor)
            Text(detail ?? Format.percent(percent))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 40, alignment: .trailing)
        }
        .font(.callout)
    }
}
