import SwiftUI

/// Drives `mo optimize`: a dry-run preview, then the real run.
///
/// The real run uses a pseudo-terminal because Mole asks for admin access
/// (Touch ID or password) before its sudo tasks; PromptBar relays that prompt.
struct OptimizeView: View {
    private enum Mode { case preview, optimize }

    @State private var session = TerminalSession()
    @State private var mode: Mode?
    @State private var showRaw = false
    @State private var confirming = false

    private var report: SectionReport { SectionReport(lines: session.allLines) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !session.isRunning {
                PermissionBanner(lines: session.allLines).padding([.horizontal, .top], 12)
            }
            content
            if mode == .optimize {
                Divider()
                PromptBar(session: session) { mode = nil }
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("优化")
        .confirmationDialog("开始优化？", isPresented: $confirming) {
            Button("优化") { run(.optimize) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("Mole 会刷新系统缓存、修复损坏的配置并整理数据库。部分任务需要管理员权限，届时会请你输入密码或使用 Touch ID；拒绝的话这些任务会被跳过。")
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
                if mode == .preview { Button("停止") { session.terminate() } }
            } else {
                Button("检查") { run(.preview) }
                Button("开始优化") { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(mode != .preview || session.exitCode != 0)
            }
        }
        .padding(12)
    }

    private var title: String {
        switch (mode, session.isRunning) {
        case (nil, _): "系统优化"
        case (.preview, true): "正在检查（预览，不会改动系统）…"
        case (.preview, false): "检查完成"
        case (.optimize, true): "正在优化…"
        case (.optimize, false): session.exitCode == 0 ? "优化完成" : "优化结束（退出码 \(session.exitCode ?? -1)）"
        }
    }

    private var subtitle: String {
        if mode == nil { return "刷新缓存、修复配置、整理数据库。先检查，确认后再执行。" }
        return report.summary.dropFirst().first ?? session.allLines.last(where: { !$0.isEmpty }) ?? ""
    }

    @ViewBuilder
    private var content: some View {
        if mode == nil {
            ContentUnavailableView {
                Label("还没有检查", systemImage: "wand.and.stars")
            } description: {
                Text("检查会列出 Mole 打算执行的优化项目，不会改动任何东西。")
            } actions: {
                Button("检查") { run(.preview) }.buttonStyle(.borderedProminent)
            }
        } else if showRaw || report.sections.isEmpty {
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
        if newMode == .preview {
            session.start(["optimize", "--dry-run"], usePTY: false)
        } else {
            session.start(["optimize"], usePTY: true)
        }
    }
}
