import AppKit
import SwiftUI

// MARK: - About

struct AboutView: View {
    @State private var update: UpdateChecker.Result?
    @State private var checking = false

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Burrow").font(.title.bold())
            Text("版本 \(Doctor.burrowVersion())").foregroundStyle(.secondary)
            Text("内置 Mole CLI \(Bundle.main.object(forInfoDictionaryKey: "BundledMoleVersion") as? String ?? "（开发模式，未打包）")")
                .foregroundStyle(.secondary)

            UpdateStatusView(result: update, checking: checking) { Task { await check() } }
                .frame(maxWidth: .infinity)
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            Text("Burrow 是基于开源 Mole CLI 的图形界面。所有清理、卸载和优化都由 Mole 执行。Burrow 与 Mole 项目及 Mole Mac 没有隶属关系。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Link("Burrow 源码", destination: URL(string: "https://github.com/lilu007-github/Mole/tree/feature/gui/app")!)
                Link("Mole 项目", destination: URL(string: "https://github.com/tw93/Mole")!)
                Link("GPL-3.0 许可证", destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
            }
            .font(.callout)
        }
        .padding(24)
        .frame(width: 420)
        .task { await check() }
    }

    private func check() async {
        checking = true
        update = await UpdateChecker.check()
        checking = false
    }
}

struct UpdateStatusView: View {
    let result: UpdateChecker.Result?
    let checking: Bool
    let recheck: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            switch (checking, result) {
            case (true, _), (_, nil):
                HStack { ProgressView().controlSize(.small); Text("正在检查 Mole 更新…") }
            case let (_, .upToDate(current)?):
                Label("Mole \(current) 已是最新版本", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case let (_, .available(current, latest, notes)?):
                Label("Mole 有新版本 \(latest)（当前 \(current)）", systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(.orange)
                Text("在仓库里运行 app/scripts/sync-upstream.sh，合并更新、跑检查并重新打包 Burrow。")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack {
                    Link("查看更新内容", destination: notes)
                    Button("拷贝命令") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("app/scripts/sync-upstream.sh", forType: .string)
                    }
                }
                .font(.callout)
            case let (_, .failed(message)?):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            }
            if !checking, result != nil {
                Button("重新检查", action: recheck).buttonStyle(.link).font(.caption)
            }
        }
    }
}

// MARK: - Doctor

struct DoctorView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var report: DoctorReport?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("诊断").font(.title2.bold())
                    Text("检查这台 Mac 和 Burrow 的状态。反馈问题时可以附上这份报告。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(copied ? "已拷贝" : "拷贝报告") {
                    guard let report else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.text, forType: .string)
                    copied = true
                }
                .disabled(report == nil)
                Button("重新检查") { Task { await run() } }
            }
            .padding(16)
            Divider()
            if let report {
                List {
                    ForEach(report.sections) { section in
                        Section(section.title) {
                            ForEach(section.items) { item in row(item) }
                        }
                    }
                }
            } else {
                ProgressView("正在检查…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 560, minHeight: 520)
        .task { await run() }
    }

    private func row(_ item: DoctorReport.Item) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol(item.level)).foregroundStyle(color(item.level)).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                Text(item.value).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            if let action = item.action { actionButton(action) }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func actionButton(_ action: DoctorReport.Action) -> some View {
        switch action {
        case let .page(page):
            Button("前往\(page.title)") {
                UserDefaults.standard.set(page.rawValue, forKey: "lastPage")
                MainWindow.show(openWindow)
            }
        case let .settings(url):
            Button("打开系统设置") { NSWorkspace.shared.open(url) }
        case let .reveal(url):
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    private func symbol(_ level: DoctorReport.Level) -> String {
        switch level {
        case .ok: "checkmark.circle.fill"
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .problem: "xmark.octagon.fill"
        }
    }

    private func color(_ level: DoctorReport.Level) -> Color {
        switch level {
        case .ok: .green
        case .info: .secondary
        case .warning: .orange
        case .problem: .red
        }
    }

    private func run() async {
        copied = false
        async let status = try? MoleCLI.json(["status", "--json"], as: StatusSnapshot.self)
        async let version = try? MoleCLI.run(["--version"])
        let (snapshot, versionData) = await (status, version)
        let versionLine = versionData.map { String(decoding: $0, as: UTF8.self) }?
            .split(separator: "\n").first { $0.hasPrefix("Mole version") }.map(String.init)
        report = await Task.detached { Doctor.run(status: snapshot, moleVersion: versionLine) }.value
    }
}

// MARK: - Menus

/// The "工具" menu in the menu bar and the same actions for the panel.
struct ToolCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("关于 Burrow") { open("about") }
            Button("检查 Mole 更新…") { open("about") }
        }
        CommandGroup(replacing: .help) {
            Link("Burrow 使用说明", destination: URL(string: "https://github.com/lilu007-github/Mole/blob/feature/gui/app/README.md")!)
            Button("欢迎与权限指南") {
                MainWindow.show(openWindow)
                NotificationCenter.default.post(name: OnboardingView.showNotification, object: nil)
            }
            Button("运行诊断并拷贝报告…") { open("doctor") }
            Divider()
            Link("Mole CLI 文档", destination: URL(string: "https://github.com/tw93/Mole#readme")!)
            Link("报告 Mole CLI 的问题（仅限命令行本身）", destination: URL(string: "https://github.com/tw93/Mole/issues")!)
        }
        CommandGroup(before: .windowList) {
            ForEach(Array(SidebarItem.allCases.prefix(9).enumerated()), id: \.offset) { index, page in
                Button(page.title) {
                    UserDefaults.standard.set(page.rawValue, forKey: "lastPage")
                    MainWindow.show(openWindow)
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
            Divider()
        }
        CommandMenu("工具") {
            Menu("清洁屏幕") {
                ForEach(CleanScreen.durations, id: \.label) { option in
                    Button(option.label) { CleanScreen.shared.start(duration: option.seconds) }
                }
            }
            Button("保持常亮") {
                if KeepAwake.shared.isActive {
                    KeepAwake.shared.disable()
                } else {
                    KeepAwake.shared.enable(duration: nil,
                                            allowDisplaySleep: UserDefaults.standard.bool(forKey: MenuBarSettings.allowDisplaySleepKey))
                }
            }
            Divider()
            Button("运行诊断…") { open("doctor") }
                .keyboardShortcut("d", modifiers: [.command, .shift])
        }
    }

    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}
