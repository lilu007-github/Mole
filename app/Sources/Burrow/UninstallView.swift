import SwiftUI

struct UninstallView: View {
    @State private var apps: [InstalledApp] = []
    @State private var selection = Set<InstalledApp.ID>()
    @State private var search = ""
    @State private var loading = false
    @State private var error: String?
    @State private var job: UninstallJob?

    private var filtered: [InstalledApp] {
        guard !search.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || ($0.bundleId ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    private var selectedApps: [InstalledApp] {
        apps.filter { selection.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("搜索应用", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Spacer()
                Text(selection.isEmpty ? "\(apps.count) 个应用" : "已选 \(selection.count) 个")
                    .foregroundStyle(.secondary)
                Button("预览") { job = UninstallJob(apps: selectedApps, dryRun: true) }
                    .disabled(selection.isEmpty)
                Button("卸载…") { job = UninstallJob(apps: selectedApps, dryRun: false) }
                    .buttonStyle(.borderedProminent)
                    .disabled(selection.isEmpty)
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(loading)
            }
            .padding(10)
            Divider()
            if let error {
                ContentUnavailableView("读取应用列表失败", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if loading && apps.isEmpty {
                ProgressView("正在读取已安装的应用…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(filtered, selection: $selection) {
                    TableColumn("应用") { app in
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                                .resizable()
                                .frame(width: 20, height: 20)
                            Text(app.name)
                        }
                    }
                    TableColumn("来源") { Text($0.source ?? "") }.width(90)
                    TableColumn("大小") { Text($0.size ?? "--").monospacedDigit() }.width(90)
                    TableColumn("路径") { Text($0.path).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
        }
        .navigationTitle("卸载应用")
        .task { if apps.isEmpty { await load() } }
        .sheet(item: $job, onDismiss: {
            selection.removeAll()
            Task { await load() }
        }) { job in
            UninstallSheet(job: job)
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            apps = try await MoleCLI.json(["uninstall", "--list"], as: [InstalledApp].self)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct UninstallJob: Identifiable {
    let id = UUID()
    let apps: [InstalledApp]
    let dryRun: Bool
}

/// Runs `mo uninstall <names>` in a pseudo-terminal. Mole prints the full plan
/// and waits for Enter; Burrow forwards Enter only when the user clicks.
struct UninstallSheet: View {
    let job: UninstallJob
    @Environment(\.dismiss) private var dismiss
    @State private var session = TerminalSession()
    @State private var answered = false
    @State private var password = ""
    @State private var passwordSentAt: Int?

    private var awaitingConfirm: Bool {
        session.isRunning && !answered && session.currentLine.contains("Enter confirm, ESC cancel")
    }

    private var awaitingPassword: Bool {
        guard session.isRunning,
              let index = session.allLines.lastIndex(where: { $0.contains("Enter your credentials") })
        else { return false }
        return passwordSentAt.map { index >= $0 } ?? true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(job.dryRun ? "预览卸载（不会删除任何文件）" : "卸载 \(job.apps.map(\.name).joined(separator: "、"))")
                .font(.title3.bold())
            Text(job.dryRun
                ? "下面是 Mole 生成的卸载计划。"
                : "请核对 Mole 给出的计划。应用会被移到废纸篓；个人数据默认保留。")
                .foregroundStyle(.secondary)
            RawOutputView(lines: session.allLines)
                .frame(minHeight: 320)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            if awaitingPassword {
                HStack {
                    SecureField("管理员密码", text: $password)
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
                    Button("取消") {
                        answered = true
                        session.send("\u{1b}")
                    }
                    Button(job.dryRun ? "继续预览" : "确认卸载", role: .destructive) {
                        answered = true
                        session.send("\r")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else if session.isRunning {
                    Button("停止") { session.terminate() }
                } else {
                    Button("关闭") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 760, height: 560)
        .interactiveDismissDisabled(session.isRunning)
        .onAppear {
            var args = ["uninstall"]
            if job.dryRun { args.append("--dry-run") }
            session.start(args + job.apps.map(\.uninstallName), usePTY: true)
        }
        .onDisappear { if session.isRunning { session.terminate() } }
    }

    private func sendPassword() {
        guard !password.isEmpty else { return }
        session.send(password + "\r")
        password = ""
        passwordSentAt = session.allLines.count
    }
}
