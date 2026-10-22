import SwiftUI

/// Drives `mo clean`: a dry run first, then the real cleanup after the user confirms.
///
/// Both runs use Mole's non-interactive mode (no terminal), in which the CLI
/// cleans user-level items only and skips anything that needs sudo.
struct CleanView: View {
    private enum Mode { case preview, clean }

    @State private var session = TerminalSession()
    @State private var mode: Mode?
    @State private var showRaw = false
    @State private var confirming = false
    @State private var editingWhitelist = false
    @State private var cleaningExternal = false

    private var report: SectionReport { SectionReport(lines: session.allLines) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !session.isRunning {
                PermissionBanner(lines: session.allLines).padding([.horizontal, .top], 12)
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $editingWhitelist) { WhitelistSheet(mode: .clean) }
        .sheet(isPresented: $cleaningExternal) { ExternalCleanSheet() }
        .navigationTitle("清理")
        .confirmationDialog("开始清理？", isPresented: $confirming) {
            Button("清理", role: .destructive) { run(.clean) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("""
            Mole 会重新扫描并清理用户级缓存、日志和临时文件，预计释放 \(report.potentialSpace ?? "预览中的空间")。
            注意：默认会清空废纸篓（可在终端用 mo clean --whitelist 保护）。
            需要管理员权限的系统级缓存会被跳过，如需清理请在终端运行 mo clean。
            """)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("外置磁盘…") { cleaningExternal = true }.disabled(session.isRunning)
            Button("白名单…") { editingWhitelist = true }.disabled(session.isRunning)
            Toggle("原始输出", isOn: $showRaw).toggleStyle(.switch).controlSize(.small).fixedSize()
            if session.isRunning {
                ProgressView().controlSize(.small)
                Button("停止") { session.terminate() }
            } else {
                Button("扫描预览") { run(.preview) }
                Button("开始清理") { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(mode != .preview || session.exitCode != 0)
            }
        }
        .padding(12)
    }

    private var title: String {
        switch (mode, session.isRunning) {
        case (nil, _): "扫描可清理的内容"
        case (.preview, true): "正在扫描（预览，不会删除任何文件）…"
        case (.preview, false): "预览完成"
        case (.clean, true): "正在清理…"
        case (.clean, false): session.exitCode == 0 ? "清理完成" : "清理结束（退出码 \(session.exitCode ?? -1)）"
        }
    }

    private var subtitle: String {
        if let space = report.potentialSpace, mode == .preview, !session.isRunning {
            return "可释放约 \(space)。点「开始清理」执行。"
        }
        if mode == nil { return "先预览，确认后再清理。完整扫描大约需要 1–2 分钟。" }
        return report.summary.last ?? session.allLines.last(where: { !$0.isEmpty }) ?? ""
    }

    @ViewBuilder
    private var content: some View {
        if mode == nil {
            ContentUnavailableView {
                Label("还没有扫描", systemImage: "sparkles")
            } description: {
                Text("预览模式会列出 Mole 将要清理的缓存、日志和临时文件，不会删除任何东西。")
            } actions: {
                Button("扫描预览") { run(.preview) }.buttonStyle(.borderedProminent)
            }
        } else if showRaw {
            RawOutputView(lines: session.allLines)
        } else {
            List {
                if !report.summary.isEmpty {
                    Section("摘要") {
                        ForEach(report.summaryRows, id: \.id) { Text($0.text) }
                    }
                }
                ForEach(report.sections) { section in
                    Section(section.title) {
                        ForEach(section.items) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Text(item.icon).foregroundStyle(item.color).frame(width: 14)
                                Text(item.text).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
    }

    private func run(_ newMode: Mode) {
        mode = newMode
        session.start(newMode == .preview ? ["clean", "--dry-run"] : ["clean"], usePTY: false)
    }
}
