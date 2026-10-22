import AppKit
import SwiftUI

struct AppUpdatesView: View {
    @State private var updates: [AppUpdate] = []
    @State private var loading = false
    @State private var checked = false
    @State private var error: String?
    @State private var upgrading: AppUpdate?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(loading ? "正在检查更新…" : checked ? "\(updates.count) 个 App 可以更新" : "App 更新").font(.headline)
                    Text("来自 Homebrew 和 App 自带的更新源（Sparkle）。App Store 的更新请在 App Store 中查看。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button("App Store 更新") {
                    NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!)
                }
                Button("检查") { Task { await load() } }.disabled(loading)
            }
            .padding(12)
            Divider()
            if let error {
                ContentUnavailableView("检查失败", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if checked && updates.isEmpty && !loading {
                ContentUnavailableView("都是最新版本", systemImage: "checkmark.circle")
            } else {
                Table(updates) {
                    TableColumn("App") { update in
                        HStack {
                            if update.source == .sparkle {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: update.reference))
                                    .resizable().frame(width: 18, height: 18)
                            } else {
                                Image(systemName: "shippingbox").frame(width: 18)
                            }
                            Text(update.name)
                        }
                    }
                    TableColumn("来源") { Text($0.source.rawValue).foregroundStyle(.secondary) }.width(100)
                    TableColumn("当前") { Text($0.installed).monospacedDigit() }.width(110)
                    TableColumn("最新") { Text($0.latest).monospacedDigit().bold() }.width(110)
                    TableColumn("") { update in
                        if update.source == .homebrew {
                            Button("更新") { upgrading = update }
                        } else {
                            Button("打开 App 更新") {
                                NSWorkspace.shared.open(URL(fileURLWithPath: update.reference))
                            }
                            .help("在 App 里用它自带的「检查更新」完成升级")
                        }
                    }
                    .width(120)
                }
            }
        }
        .navigationTitle("应用更新")
        .task { if !checked { await load() } }
        .sheet(item: $upgrading, onDismiss: { Task { await load() } }) { BrewUpgradeSheet(update: $0) }
    }

    private func load() async {
        loading = true
        defer { loading = false; checked = true }
        do {
            async let brew = AppUpdates.homebrew()
            async let sparkle = AppUpdates.sparkle()
            let (casks, apps) = try await (brew, sparkle)
            updates = (apps + casks).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// `brew upgrade --cask <token>` in a pseudo-terminal so sudo can ask for a password.
private struct BrewUpgradeSheet: View {
    let update: AppUpdate
    @Environment(\.dismiss) private var dismiss
    @State private var session = TerminalSession()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("更新 \(update.name)：\(update.installed) → \(update.latest)").font(.title3.bold())
            Text("由 Homebrew 下载并安装新版本。如果 App 正在运行，Homebrew 可能会先退出它。")
                .foregroundStyle(.secondary)
            RawOutputView(lines: session.allLines)
                .frame(minHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            PromptBar(session: session) { dismiss() }
        }
        .padding(20)
        .frame(width: 720, height: 500)
        .interactiveDismissDisabled(session.isRunning)
        .onAppear {
            guard let brew = AppUpdates.brew else { return }
            session.start(["upgrade", "--cask", update.reference], usePTY: true, executable: brew)
        }
        .onDisappear { if session.isRunning { session.terminate() } }
    }
}
