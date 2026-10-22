import AppKit
import SwiftUI

/// Intel code in universal apps via `mo slim`: preview, choose, then Mole slims
/// a verified copy and moves each original to the Trash.
struct SlimView: View {
    @State private var session = TerminalSession()
    @State private var scanned = false
    @State private var selection = Set<SlimApp.ID>()
    @State private var job: SlimJob?

    private var apps: [SlimApp] { SlimApp.parse(session.allLines) }

    private var headline: String {
        if session.isRunning { return "正在扫描 App…" }
        guard scanned else { return "精简 App" }
        return SlimApp.summary(session.allLines) == nil ? "没有可以精简的 App" : "\(apps.count) 个 App 可以精简"
    }

    private var chosenSize: Int64 {
        apps.filter { selection.contains($0.id) }.reduce(0) { $0 + HistoryReport.parseSize($1.size) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(headline).font(.headline)
                    Spacer()
                    if session.isRunning { ProgressView().controlSize(.small) }
                    Button(scanned ? "重新扫描" : "扫描") { scan() }.disabled(session.isRunning)
                    Button(selection.isEmpty ? "精简所选…" : "精简 \(selection.count) 个（\(Format.bytes(chosenSize))）…") {
                        job = SlimJob(names: selection, listed: apps)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selection.isEmpty || session.isRunning)
                }
                Text("删掉 App 里给 Intel 芯片用的代码，只保留 Apple 芯片的部分。Mole 先在副本上精简并验证签名，原 App 移到废纸篓；App 更新后 Intel 代码会回来。")
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(12)
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("精简 App")
        .sheet(item: $job, onDismiss: { selection.removeAll(); scan() }) { SlimSheet(job: $0) }
    }

    private var content: some View {
        contentBody.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var contentBody: some View {
        if !scanned {
            ContentUnavailableView {
                Label("还没有扫描", systemImage: "scissors")
            } description: {
                Text("只看「应用程序」文件夹里你自己安装、带开发者签名的 App。App Store 的 App、系统 App 和正在运行的 App 不会被改动。扫描只是预览。")
            } actions: {
                Button("扫描") { scan() }.buttonStyle(.borderedProminent)
            }
        } else if !session.isRunning && apps.isEmpty {
            ContentUnavailableView("没有可以精简的 App", systemImage: "checkmark.circle",
                                   description: Text(session.allLines.contains { $0.contains("Apple Silicon") }
                                       ? "精简只适用于 Apple 芯片的 Mac。" : "这台 Mac 上的 App 都已经只含 Apple 芯片代码，或不在 Mole 的处理范围内。"))
        } else {
            List(apps) { app in
                SlimRow(app: app, selection: $selection)
            }
        }
    }

    private func scan() {
        selection.removeAll()
        scanned = true
        session.start(["slim", "--dry-run"], usePTY: false)
    }
}

private struct SlimRow: View {
    let app: SlimApp
    @Binding var selection: Set<SlimApp.ID>

    private var isOn: Binding<Bool> {
        Binding(get: { selection.contains(app.id) },
                set: { on in
                    if on { selection.insert(app.id) } else { selection.remove(app.id) }
                })
    }

    private var isRunning: Bool {
        guard let url = app.url else { return false }
        return NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }
    }

    var body: some View {
        Toggle(isOn: isOn) {
            HStack {
                if let url = app.url {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
                }
                Text(app.name).lineLimit(1)
                if isRunning {
                    Text("运行中，会被跳过").font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Text(app.size).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            if let url = app.url {
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }
}

struct SlimJob: Identifiable {
    let id = UUID()
    let names: Set<String>
    let listed: [SlimApp]
}

/// Runs the real `mo slim` menu, selects exactly the chosen apps, and leaves
/// Mole's final confirmation to the user once its listed apps match.
struct SlimSheet: View {
    let job: SlimJob
    @Environment(\.dismiss) private var dismiss
    @State private var session = TerminalSession()
    @State private var status = "正在扫描…"
    @State private var problem: String?
    @State private var verified = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("精简 \(job.names.count) 个 App").font(.title3.bold())
            Text("每个 App 先在副本上精简，通过签名和 Gatekeeper 检查后才替换；原 App 移到废纸篓，清空废纸篓后才真正腾出空间。正在运行的 App 会被跳过。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if verified {
                Label("Mole 列出的 App 和你的选择完全一致，请确认。", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(status).foregroundStyle(.secondary)
                }
            }
            RawOutputView(lines: verified || problem != nil ? session.allLines : [])
                .frame(minHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            PermissionBanner(lines: session.allLines)
            PromptBar(session: session, confirmLabel: "确认精简") { dismiss() }
                .opacity(verified || problem != nil || !session.isRunning ? 1 : 0)
        }
        .padding(20)
        .frame(width: 800, height: 600)
        .interactiveDismissDisabled(session.isRunning)
        .task {
            session.start(["slim"], usePTY: true, columns: SlimMenuDriver.columns)
            problem = await SlimMenuDriver.select(job.names, among: job.listed, in: session) { status = $0 }
            verified = problem == nil
        }
        .onDisappear { if session.isRunning { session.terminate() } }
    }
}
