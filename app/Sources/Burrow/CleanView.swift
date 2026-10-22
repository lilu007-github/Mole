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

    private var report: CleanReport { CleanReport(lines: session.allLines) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
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
            Toggle("原始输出", isOn: $showRaw).toggleStyle(.switch).controlSize(.small)
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
                        ForEach(Array(report.summary.enumerated()), id: \.offset) { Text($0.element) }
                    }
                }
                ForEach(report.sections) { section in
                    Section(section.title) {
                        ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
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

/// Groups `mo clean` output into its "➤ Section" blocks and the closing summary.
struct CleanReport {
    struct Item {
        var icon: String
        var text: String

        var color: Color {
            switch icon {
            case "✓": .green
            case "◎", "☻": .orange
            case "⊙": .blue
            default: .secondary
            }
        }
    }

    struct Section: Identifiable {
        var id: Int
        var title: String
        var items: [Item] = []
    }

    var sections: [Section] = []
    var summary: [String] = []

    init(lines: [String]) {
        var inSummary = false
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("====") {
                inSummary.toggle()
                continue
            }
            if inSummary {
                if !line.isEmpty { summary.append(line) }
            } else if line.hasPrefix("➤ ") {
                sections.append(Section(id: sections.count, title: String(line.dropFirst(2))))
            } else if !line.isEmpty, raw.hasPrefix("  "), !sections.isEmpty {
                let icon = String(line.prefix(1))
                let text = line.dropFirst().trimmingCharacters(in: .whitespaces)
                sections[sections.count - 1].items.append(Item(icon: icon, text: text))
            }
        }
    }

    /// "Potential space: 11.09GB+ | Items: …" from the dry-run summary.
    var potentialSpace: String? {
        for line in summary {
            for prefix in ["Potential space:", "Space freed:"] where line.hasPrefix(prefix) {
                return line.dropFirst(prefix.count).split(separator: "|").first?
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

struct RawOutputView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: lines.count) { _, count in
                if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
    }
}
