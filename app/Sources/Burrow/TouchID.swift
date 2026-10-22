import SwiftUI

/// Touch ID for sudo through `mo touchid`: Mole writes `/etc/pam.d/sudo_local`
/// (it survives macOS updates) after asking for the administrator password once.
enum TouchIDSudo {
    enum State: Equatable { case enabled, disabled, unknown }

    static func parse(_ output: String) -> State {
        if output.contains("Touch ID is enabled for sudo") { return .enabled }
        if output.contains("Touch ID is not configured for sudo") { return .disabled }
        return .unknown
    }

    static func status() async -> State {
        guard let data = try? await MoleCLI.run(["touchid", "status"]) else { return .unknown }
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// Mole asks "Continue anyway? [y/N]" when it cannot find Touch ID hardware.
    static let hardwarePrompt = "[y/N]"
}

struct TouchIDSection: View {
    @State private var state: TouchIDSudo.State?
    @State private var job: TouchIDJob?

    var body: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("用 Touch ID 代替管理员密码")
                    Text(stateText).font(.caption).foregroundStyle(state == .enabled ? .green : .secondary)
                }
                Spacer()
                if state == nil { ProgressView().controlSize(.small) }
                Button(state == .enabled ? "关闭…" : "开启…") {
                    job = TouchIDJob(enable: state != .enabled)
                }
                .disabled(state == nil || state == .unknown)
            }
        } header: {
            Text("Touch ID")
        } footer: {
            Text("开启后，终端里的 sudo 和 Burrow 里需要管理员权限的操作都可以按指纹。由 Mole 修改 /etc/pam.d/sudo_local，macOS 更新后依然有效；开启或关闭时要输入一次管理员密码。")
                .foregroundStyle(.secondary)
        }
        .task { state = await TouchIDSudo.status() }
        .sheet(item: $job, onDismiss: { Task { state = nil; state = await TouchIDSudo.status() } }) {
            TouchIDSheet(job: $0)
        }
    }

    private var stateText: String {
        switch state {
        case .enabled: "已开启"
        case .disabled: "未开启"
        case .unknown: "无法读取状态"
        case nil: "正在检查…"
        }
    }
}

struct TouchIDJob: Identifiable {
    let id = UUID()
    let enable: Bool
}

struct TouchIDSheet: View {
    let job: TouchIDJob
    @Environment(\.dismiss) private var dismiss
    @State private var session = TerminalSession()

    private var askingHardware: Bool {
        session.isRunning && session.currentLine.contains(TouchIDSudo.hardwarePrompt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(job.enable ? "开启 Touch ID" : "关闭 Touch ID").font(.title3.bold())
            Text(job.enable ? "Mole 会在 sudo 的设置里加一行 pam_tid.so。" : "Mole 会删掉 sudo 设置里的 pam_tid.so，之后 sudo 只接受密码。")
                .foregroundStyle(.secondary)
            RawOutputView(lines: session.allLines)
                .frame(minHeight: 160)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            if askingHardware {
                HStack {
                    Label("Mole 没有检测到 Touch ID 硬件，仍要继续吗？", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("取消") { session.send("n\r") }
                    Button("仍然继续") { session.send("y\r") }
                }
            }
            PromptBar(session: session) { dismiss() }
        }
        .padding(20)
        .frame(width: 560, height: 380)
        .interactiveDismissDisabled(session.isRunning)
        .task { session.start(["touchid", job.enable ? "enable" : "disable"], usePTY: true) }
        .onDisappear { if session.isRunning { session.terminate() } }
    }
}
