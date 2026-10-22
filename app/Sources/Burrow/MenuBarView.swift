import AppKit
import SwiftUI

enum MenuBarSettings {
    static let showKey = "showMenuBar"
    static let speedKey = "menuBarShowsSpeed"
    static let allowDisplaySleepKey = "keepAwakeAllowsDisplaySleep"
}

/// The menu bar icon: a cup while keep-awake is on, optional network speed.
struct MenuBarLabel: View {
    @AppStorage(MenuBarSettings.speedKey) private var showSpeed = false
    private let monitor = StatusMonitor.shared
    private let keepAwake = KeepAwake.shared

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: keepAwake.isActive ? "cup.and.saucer.fill" : "hare")
            if showSpeed, let net = monitor.activeNetwork {
                Text("↓\(Self.compact(net.rxRateMbs)) ↑\(Self.compact(net.txRateMbs))")
                    .monospacedDigit()
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
            Divider()
            HStack {
                Button("打开 Burrow") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                Button("退出") { NSApp.terminate(nil) }
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
