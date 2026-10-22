import AppKit
import SwiftUI

struct SettingsView: View {
    @AppStorage(MoleCLI.pathDefaultsKey) private var molePath = ""
    @State private var version = ""
    @AppStorage(MenuBarSettings.showKey) private var showMenuBar = true
    @AppStorage(MenuBarSettings.metricKey) private var metricRaw = MenuBarMetric.saved.rawValue
    @AppStorage(MenuBarSettings.hideDockKey) private var hideDock = false
    @AppStorage(GlobalShortcuts.enabledKey) private var shortcutsEnabled = false
    @AppStorage(AppSettings.commandQClosesKey) private var commandQCloses = false
    @AppStorage(AppSettings.appearanceKey) private var appearance = AppSettings.Appearance.system.rawValue
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginError: String?
    @State private var shortcutsRegistered = 0
    @AppStorage(Notifier.Kind.diskSpace.rawValue) private var notifyDisk = false
    @AppStorage(Notifier.Kind.bluetoothBattery.rawValue) private var notifyBluetooth = false
    @AppStorage(Notifier.Kind.keepAwake.rawValue) private var notifyKeepAwake = false
    @AppStorage(Notifier.Kind.privacy.rawValue) private var notifyPrivacy = false

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("mo / mole 路径", text: $molePath, prompt: Text("留空自动检测"))
                    Button("选择…") { choose() }
                }
                LabeledContent("当前使用") {
                    Text(MoleCLI.executableURL?.path ?? "未找到")
                        .textSelection(.enabled)
                }
                if !version.isEmpty {
                    LabeledContent("版本") { Text(version) }
                }
            } header: {
                Text("Mole CLI")
            } footer: {
                Text("Burrow 的所有操作都通过 Mole CLI 完成，默认使用打包在 App 里的版本（\(Self.bundledVersion)）。留空即可；只有想用另一份 Mole 时才需要填写路径。")
                    .foregroundStyle(.secondary)
            }
            Section("通用") {
                Toggle("登录时自动打开 Burrow", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            try LaunchAtLogin.set(on)
                            loginError = LaunchAtLogin.needsApproval ? "需要在「系统设置 → 通用 → 登录项」里允许 Burrow。" : nil
                        } catch {
                            loginError = "设置失败：\(error.localizedDescription)"
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.orange)
                }
                Picker("外观", selection: $appearance) {
                    ForEach(AppSettings.Appearance.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .onChange(of: appearance) { AppSettings.applyAppearance() }
                Toggle("⌘Q 只关闭窗口，Burrow 留在菜单栏", isOn: $commandQCloses)
                    .disabled(!showMenuBar)
                Toggle("启用全局快捷键", isOn: $shortcutsEnabled)
                    .onChange(of: shortcutsEnabled) {
                        GlobalShortcuts.shared.apply()
                        shortcutsRegistered = GlobalShortcuts.shared.registeredCount
                    }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(GlobalShortcuts.all, id: \.id) { Text($0.label).monospaced() }
                    if shortcutsEnabled && shortcutsRegistered < GlobalShortcuts.all.count {
                        Text("有 \(GlobalShortcuts.all.count - shortcutsRegistered) 个快捷键已被其他 App 占用。")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            TouchIDSection()
            Section("通知") {
                Toggle(Notifier.Kind.diskSpace.title + "（少于 10 GB）", isOn: $notifyDisk)
                Toggle(Notifier.Kind.bluetoothBattery.title + "（低于 20%）", isOn: $notifyBluetooth)
                Toggle(Notifier.Kind.keepAwake.title, isOn: $notifyKeepAwake)
                Toggle(Notifier.Kind.privacy.title, isOn: $notifyPrivacy)
                Text("同一件事一天最多提醒一次。需要 Burrow 在运行（窗口关闭后留在菜单栏即可）。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onChange(of: notifyDisk || notifyBluetooth || notifyKeepAwake || notifyPrivacy) { _, any in
                if any { Notifier.requestPermission() }
            }
            Section("菜单栏") {
                Toggle("在菜单栏显示 Burrow", isOn: $showMenuBar)
                Picker("菜单栏图标旁显示", selection: $metricRaw) {
                    ForEach(MenuBarMetric.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .disabled(!showMenuBar)
                Toggle("隐藏 Dock 图标（只留在菜单栏）", isOn: $hideDock)
                    .disabled(!showMenuBar)
                    .onChange(of: hideDock) { _, hide in DockIcon.apply(hidden: hide) }
                Text("开启时，关闭窗口后 Burrow 会继续留在菜单栏；要退出请在菜单栏面板里点「退出」。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            shortcutsRegistered = GlobalShortcuts.shared.registeredCount
        }
        .task(id: molePath) {
            let data = try? await MoleCLI.run(["--version"])
            version = data.map { String(decoding: $0, as: UTF8.self) }?
                .split(separator: "\n").first.map(String.init) ?? ""
        }
    }

    private static var bundledVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "BundledMoleVersion") as? String ?? "开发模式，未打包"
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            molePath = url.path
        }
    }
}
