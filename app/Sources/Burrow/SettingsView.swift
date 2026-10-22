import AppKit
import SwiftUI

struct SettingsView: View {
    @AppStorage(MoleCLI.pathDefaultsKey) private var molePath = ""
    @State private var version = ""
    @AppStorage(MenuBarSettings.showKey) private var showMenuBar = true
    @AppStorage(MenuBarSettings.speedKey) private var showSpeed = false

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
                Text("Burrow 的所有操作都通过 Mole CLI 完成。自动检测顺序：此设置、构建时记录的仓库、/opt/homebrew/bin/mo、/usr/local/bin/mo、~/.local/bin/mo。")
                    .foregroundStyle(.secondary)
            }
            Section("菜单栏") {
                Toggle("在菜单栏显示 Burrow", isOn: $showMenuBar)
                Toggle("在菜单栏显示网速", isOn: $showSpeed).disabled(!showMenuBar)
                Text("开启时，关闭窗口后 Burrow 会继续留在菜单栏；要退出请在菜单栏面板里点「退出」。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .task(id: molePath) {
            let data = try? await MoleCLI.run(["--version"])
            version = data.map { String(decoding: $0, as: UTF8.self) }?
                .split(separator: "\n").first.map(String.init) ?? ""
        }
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
