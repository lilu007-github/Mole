import AppKit
import SwiftUI

struct AIDataView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                AIInventorySection()
                AIMoleCacheSection()
                AISessionsSection()
                AIWorktreesSection()
            }
            .padding(20)
        }
        .navigationTitle("AI 数据")
    }
}

// MARK: - Inventory

private struct AIInventorySection: View {
    @State private var sizes: [String: Int64] = [:]
    @State private var measuring = true

    private var groups: [(tool: String, locations: [AILocation])] {
        Dictionary(grouping: AILocation.all, by: \.tool)
            .map { ($0.key, $0.value) }
            .sorted { total($0.locations) > total($1.locations) }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(groups, id: \.tool) { group in
                    DisclosureGroup {
                        ForEach(group.locations) { location in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(location.kind.rawValue)
                                    Text(location.note).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(sizeText(location.path)).monospacedDigit().foregroundStyle(.secondary)
                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: location.path)])
                                } label: {
                                    Image(systemName: "magnifyingglass")
                                }
                                .buttonStyle(.borderless)
                                .help("在访达中显示")
                            }
                            .padding(.vertical, 3)
                        }
                    } label: {
                        HStack {
                            Text(group.tool).bold()
                            Spacer()
                            Text(measuring && total(group.locations) == 0 ? "计算中…" : Format.bytes(total(group.locations)))
                                .monospacedDigit()
                        }
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }
        } label: {
            HStack {
                Label("AI 工具占用", systemImage: "cpu")
                Spacer()
                if measuring { ProgressView().controlSize(.small) }
            }
        }
        .task {
            await withTaskGroup(of: (String, Int64?).self) { group in
                for location in AILocation.all {
                    group.addTask { (location.path, await AILocation.measure(location.path)) }
                }
                for await (path, size) in group {
                    if let size { sizes[path] = size }
                }
            }
            measuring = false
        }
    }

    // Nested folders (~/.codex/sessions inside ~/.codex) are listed once each, never summed twice.
    private func total(_ locations: [AILocation]) -> Int64 {
        locations.filter { location in
            !locations.contains { $0.path != location.path && location.path.hasPrefix($0.path + "/") }
        }
        .reduce(0) { $0 + (sizes[$1.path] ?? 0) }
    }

    private func sizeText(_ path: String) -> String {
        sizes[path].map { Format.bytes($0) } ?? (measuring ? "…" : "--")
    }
}

// MARK: - What `mo clean` already covers

private struct AIMoleCacheSection: View {
    @State private var session = TerminalSession()
    @State private var started = false

    static let keywords = ["claude", "codex", "cursor", "copilot", "gemini", "ollama", "chatgpt", "openai",
                           "kiro", "windsurf", "lm studio", "hugging"]

    private var aiItems: [SectionReport.Item] {
        SectionReport(lines: session.allLines).sections.flatMap(\.items).filter { item in
            let text = item.text.lowercased()
            return Self.keywords.contains { text.contains($0) }
        }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("这些是 AI 工具的缓存、日志和旧版本，由 Mole 判断哪些可以安全删除。Mole 不支持只清理 AI 这一类，要清理请到「清理」页，会和其他缓存一起清。")
                    .font(.callout).foregroundStyle(.secondary)
                if !started {
                    Button("扫描（预览，约 1–2 分钟）") {
                        started = true
                        session.start(["clean", "--dry-run"], usePTY: false)
                    }
                } else if session.isRunning {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(session.allLines.last(where: { !$0.isEmpty }) ?? "扫描中…")
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                } else if aiItems.isEmpty {
                    Text("没有可清理的 AI 缓存。").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(aiItems.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 8) {
                            Text(item.icon).foregroundStyle(item.color).frame(width: 14)
                            Text(item.text)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Mole 可清理的 AI 缓存", systemImage: "sparkles")
        }
    }
}

// MARK: - Old conversations

private struct AISessionsSection: View {
    @State private var days = 90
    @State private var toolFilter: AISession.Tool?
    @State private var sessions: [AISession] = []
    @State private var selection = Set<AISession.ID>()
    @State private var scanning = false
    @State private var scannedDays: Int?
    @State private var confirming = false
    @State private var working = false
    @State private var result: String?

    private static let dayOptions = [30, 60, 90, 180, 365]

    private var cutoff: Date { Calendar.current.date(byAdding: .day, value: -days, to: .now)! }

    private var visible: [AISession] {
        toolFilter.map { tool in sessions.filter { $0.tool == tool } } ?? sessions
    }

    private var chosen: [AISession] { sessions.filter { selection.contains($0.id) } }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("列出超过所选天数没有更新的对话。勾选后才会处理：Burrow 把它们移到废纸篓（可以恢复），并记入 Mole 的操作日志。Claude Code 的 memory 文件夹和项目文件不会被触碰。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Picker("超过", selection: $days) {
                        ForEach(Self.dayOptions, id: \.self) { Text("\($0) 天").tag($0) }
                    }
                    .frame(width: 140)
                    Picker("工具", selection: $toolFilter) {
                        Text("全部").tag(AISession.Tool?.none)
                        Text("Claude Code").tag(AISession.Tool?.some(.claudeCode))
                        Text("Codex").tag(AISession.Tool?.some(.codex))
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 280)
                    Spacer()
                    if scanning || working { ProgressView().controlSize(.small) }
                    Button("全选") { selection = Set(visible.map(\.id)) }.disabled(visible.isEmpty)
                    Button("移到废纸篓…") { confirming = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(selection.isEmpty || working)
                }
                if let result {
                    Label(result, systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
                if scannedDays != nil && visible.isEmpty && !scanning {
                    Text("没有超过 \(days) 天未更新的对话。").foregroundStyle(.secondary).padding(.vertical, 8)
                } else {
                    Table(visible, selection: $selection) {
                        TableColumn("工具") { Text($0.tool.rawValue) }.width(90)
                        TableColumn("项目") { Text($0.project).lineLimit(1) }.width(min: 80, ideal: 120)
                        TableColumn("标题") { Text($0.title).lineLimit(1).help($0.title) }
                        TableColumn("最后更新") {
                            Text($0.modified.formatted(date: .abbreviated, time: .omitted)).monospacedDigit()
                        }
                        .width(100)
                        TableColumn("大小") { Text(Format.bytes($0.size)).monospacedDigit() }.width(80)
                    }
                    .frame(height: 320)
                    .contextMenu(forSelectionType: AISession.ID.self) { ids in
                        if let id = ids.first, let session = sessions.first(where: { $0.id == id }) {
                            Button("在访达中显示") {
                                NSWorkspace.shared.activateFileViewerSelecting([session.file])
                            }
                        }
                    }
                }
            }
        } label: {
            HStack {
                Label("旧对话", systemImage: "bubble.left.and.bubble.right")
                Spacer()
                if !sessions.isEmpty {
                    Text("\(sessions.count) 个，共 \(Format.bytes(sessions.reduce(0) { $0 + $1.size }))")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: days) { await scan() }
        .confirmationDialog("把 \(chosen.count) 个对话移到废纸篓？", isPresented: $confirming) {
            Button("移到废纸篓", role: .destructive) { Task { await trashChosen() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("共 \(Format.bytes(chosen.reduce(0) { $0 + $1.size }))。移走后这些对话无法再继续（resume），需要时可以从废纸篓放回原处。")
        }
    }

    private func scan() async {
        scanning = true
        let cutoff = cutoff
        sessions = await Task.detached(priority: .userInitiated) { AISessionScanner.scan(olderThan: cutoff) }.value
        selection = selection.filter { id in sessions.contains { $0.id == id } }
        scannedDays = days
        scanning = false
    }

    private func trashChosen() async {
        working = true
        let picked = chosen
        let cutoff = cutoff
        let outcome = await Task.detached(priority: .userInitiated) {
            AISessionTrash.trash(picked, cutoff: cutoff)
        }.value
        var text = "已移到废纸篓 \(outcome.moved.count) 个，释放 \(Format.bytes(outcome.freed))"
        if !outcome.skipped.isEmpty {
            let reasons = Set(outcome.skipped.map(\.reason)).joined(separator: "、")
            text += "；跳过 \(outcome.skipped.count) 个（\(reasons)）"
        }
        result = text
        selection.removeAll()
        working = false
        await scan()
    }
}

// MARK: - Worktrees

private struct AIWorktreesSection: View {
    @State private var worktrees: [AIWorktree]?
    @State private var sizes: [String: Int64] = [:]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Claude Code、Codex 为并行任务创建的 git 工作树。是否还需要只有你知道：这里只列出会阻止删除的情况（未提交、未推送），Burrow 不会删除它们。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let worktrees {
                    if worktrees.isEmpty { Text("没有找到工作树。").foregroundStyle(.secondary) }
                    ForEach(worktrees) { tree in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(PurgePaths.abbreviate(tree.path)).lineLimit(1).truncationMode(.middle)
                                Text([tree.tool, tree.branch.map { "分支 \($0)" },
                                      tree.modified.map { "更新于 \($0.formatted(date: .abbreviated, time: .omitted))" }]
                                    .compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                                if tree.blockers.isEmpty {
                                    Text("没有未提交或未推送的内容").font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text(tree.blockers.joined(separator: "，")).font(.caption).foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            Text(sizes[tree.path].map { Format.bytes($0) } ?? "…").monospacedDigit().foregroundStyle(.secondary)
                            Menu {
                                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: tree.path)]) }
                                Button("拷贝删除命令（自己在终端运行）") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(tree.removeCommand, forType: .string)
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                        Divider()
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
        } label: {
            Label("AI 工作树", systemImage: "arrow.triangle.branch")
        }
        .task {
            let found = await Task.detached { AIWorktrees.scan() }.value
            worktrees = found
            for tree in found {
                if let size = await AILocation.measure(tree.path) { sizes[tree.path] = size }
            }
        }
    }
}
