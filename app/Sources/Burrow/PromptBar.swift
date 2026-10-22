import SwiftUI

/// Bottom bar for a command running in a pseudo-terminal.
///
/// It reacts only to prompts Mole itself prints: the "Enter confirm, ESC cancel"
/// line and the sudo "Enter your credentials:" line. Keys go to the process only
/// when the user clicks; nothing is answered automatically.
struct PromptBar: View {
    let session: TerminalSession
    var confirmLabel = "确认"
    var onClose: () -> Void

    @State private var answeredAt: Int?
    @State private var password = ""
    @State private var passwordSentAt: Int?

    static let confirmMarker = "Enter confirm, ESC cancel"

    private var awaitingConfirm: Bool {
        session.isRunning
            && session.currentLine.contains(Self.confirmMarker)
            && answeredAt.map { session.lineSerial > $0 } ?? true
    }

    private var awaitingPassword: Bool {
        guard session.isRunning, session.currentLine.isEmpty,
              let last = session.lines.last(where: { !$0.isEmpty }),
              last.contains("Enter your credentials")
        else { return false }
        return passwordSentAt.map { session.lineSerial > $0 } ?? true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if awaitingPassword {
                HStack {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary)
                    SecureField("需要管理员密码（也可以用 Touch ID）", text: $password)
                        .onSubmit(sendPassword)
                    Button("提交", action: sendPassword).disabled(password.isEmpty)
                }
            }
            HStack {
                if session.isRunning {
                    ProgressView().controlSize(.small)
                }
                if let code = session.exitCode {
                    Text(code == 0 ? "已完成" : "已结束（退出码 \(code)）")
                        .foregroundStyle(code == 0 ? Color.secondary : Color.orange)
                }
                Spacer()
                if awaitingConfirm {
                    Button("取消") { answer("\u{1b}") }
                    Button(confirmLabel, role: .destructive) { answer("\r") }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else if session.isRunning {
                    Button("停止") { session.terminate() }
                } else {
                    Button("关闭", action: onClose).keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func answer(_ key: String) {
        answeredAt = session.lineSerial
        session.send(key)
    }

    private func sendPassword() {
        guard !password.isEmpty else { return }
        session.send(password + "\r")
        password = ""
        passwordSentAt = session.lineSerial
    }
}
