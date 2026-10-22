import AppKit
import SwiftUI

/// Reads `mo history --json`: what Mole (and Burrow's AI cleanup) changed, and when.
struct HistoryView: View {
    private enum Tab: String, CaseIterable { case sessions = "操作记录", deletions = "删除明细" }

    @State private var report: HistoryReport?
    @State private var error: String?
    @State private var loading = false
    @State private var tab = Tab.sessions
    @State private var limit = 100
    @AppStorage("historyShowsPreviews") private var showPreviews = false
    @AppStorage("historyShowsEmpty") private var showEmpty = false
    @State private var selected: HistoryReport.Session.ID?

    private var sessions: [HistoryReport.Session] {
        (report?.sessions ?? []).filter { s in
            (showPreviews || !s.isDryRun) && (showEmpty || !s.isEmpty)
        }
    }

    private var deletions: [HistoryReport.Deletion] {
        (report?.deletions ?? []).filter { showPreviews || $0.status != "dry-run" }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let error {
                ContentUnavailableView("读取历史失败", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if report == nil {
                ProgressView("正在读取历史…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tab == .sessions {
                sessionsView
            } else {
                deletionsView
            }
        }
        .navigationTitle("历史记录")
        .task(id: limit) { await load() }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Toggle("预览记录", isOn: $showPreviews)
            if tab == .sessions { Toggle("空记录", isOn: $showEmpty) }
            Spacer()
            Text(summary).foregroundStyle(.secondary).lineLimit(1)
            Picker("", selection: $limit) {
                ForEach([50, 100, 200], id: \.self) { Text("最近 \($0) 条").tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(loading)
        }
        .padding(10)
    }

    /// Space released by real (not preview) runs among the visible sessions.
    private var summary: String {
        let real = sessions.filter { !$0.isDryRun }
        let freed = real.reduce(0) { $0 + $1.sizeBytes }
        return freed > 0 ? "共释放 \(Format.bytes(freed))" : ""
    }

    // MARK: Sessions

    private var sessionsView: some View {
        HSplitView {
            List(selection: $selected) {
                ForEach(groupedByDay, id: \.day) { group in
                    Section(group.day) {
                        ForEach(group.sessions) { SessionRow(session: $0).tag($0.id) }
                    }
                }
            }
            .frame(minWidth: 300)
            .overlay {
                if sessions.isEmpty {
                    ContentUnavailableView("没有记录", systemImage: "clock",
                                           description: Text(showPreviews ? "Mole 还没有执行过操作。" : "打开「预览记录」可查看预览和扫描。"))
                }
            }
            SessionDetail(session: sessions.first { $0.id == selected })
                .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var groupedByDay: [(day: String, sessions: [HistoryReport.Session])] {
        var order: [String] = []
        var groups: [String: [HistoryReport.Session]] = [:]
        for session in sessions {
            let day = session.startDate.map { $0.formatted(date: .complete, time: .omitted) } ?? "未知日期"
            if groups[day] == nil { order.append(day) }
            groups[day, default: []].append(session)
        }
        return order.map { ($0, groups[$0]!) }
    }

    // MARK: Deletions

    private var deletionsView: some View {
        Table(deletions) {
            TableColumn("时间") { d in
                Text(d.date?.formatted(date: .abbreviated, time: .shortened) ?? d.timestamp).monospacedDigit()
            }
            .width(140)
            TableColumn("方式") { d in
                Text(d.status == "dry-run" ? "预览" : d.mode == "trash" ? "废纸篓" : "永久删除")
                    .foregroundStyle(d.mode == "trash" || d.status == "dry-run" ? Color.secondary : Color.orange)
            }
            .width(70)
            TableColumn("结果") { d in
                Text(d.status == "ok" ? "成功" : d.status ?? "")
                    .foregroundStyle(d.status == "ok" || d.status == "dry-run" ? Color.secondary : Color.red)
            }
            .width(70)
            TableColumn("大小") { Text(Format.bytes(($0.sizeKb ?? 0) * 1024)).monospacedDigit() }.width(80)
            TableColumn("路径") { d in
                Text(d.path).lineLimit(1).truncationMode(.middle).help(d.path)
            }
        }
        .contextMenu(forSelectionType: HistoryReport.Deletion.ID.self) { ids in
            if let id = ids.first, let d = deletions.first(where: { $0.id == id }) {
                Button("拷贝路径") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(d.path, forType: .string)
                }
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            report = try await MoleCLI.json(["history", "--json", "--limit", String(limit)], as: HistoryReport.self)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct SessionRow: View {
    let session: HistoryReport.Session

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: HistoryReport.symbol(for: session.baseCommand))
                .frame(width: 20)
                .foregroundStyle(session.isDryRun ? Color.secondary : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(HistoryReport.title(for: session.baseCommand)).bold()
                    if session.isDryRun {
                        Text("预览").font(.caption).padding(.horizontal, 4)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                Text(actionsText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                // Without an end marker (mo installer writes none) the size is unknown, not zero.
                Text(session.endedAt?.isEmpty == false ? session.size ?? "" : "—").monospacedDigit()
                Text(session.startDate?.formatted(date: .omitted, time: .shortened) ?? "")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var actionsText: String {
        guard let a = session.actions else { return "" }
        var parts: [String] = []
        if let items = session.items, items > 0 { parts.append("\(items) 项") }
        if a.removed > 0 { parts.append("删除 \(a.removed)") }
        if a.trashed > 0 { parts.append("废纸篓 \(a.trashed)") }
        if a.rebuilt > 0 { parts.append("重建 \(a.rebuilt)") }
        if a.skipped > 0 { parts.append("跳过 \(a.skipped)") }
        if a.failed > 0 { parts.append("失败 \(a.failed)") }
        return parts.isEmpty ? "没有改动" : parts.joined(separator: " · ")
    }
}

/// The log rows of one run, matched by its run id.
private struct SessionDetail: View {
    let session: HistoryReport.Session?
    @State private var entries: [OperationEntry] = []

    var body: some View {
        Group {
            if let session {
                VStack(alignment: .leading, spacing: 8) {
                    Text(HistoryReport.title(for: session.baseCommand) + (session.isDryRun ? "（预览）" : ""))
                        .font(.title3.bold())
                    Text("\(session.startedAt) – \(session.endedAt ?? "未记录结束")")
                        .font(.callout).foregroundStyle(.secondary)
                    Divider()
                    if session.runId?.isEmpty ?? true {
                        Text("这条记录没有逐项明细。").foregroundStyle(.secondary)
                    } else if entries.isEmpty {
                        Text("这次运行没有逐项记录（例如预览或没有需要处理的项目）。").foregroundStyle(.secondary)
                    } else {
                        List(entries) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(entry.actionTitle).bold().foregroundStyle(color(entry.action))
                                    if let detail = entry.detail { Text(detail).foregroundStyle(.secondary) }
                                }
                                .font(.caption)
                                Text(entry.path).lineLimit(1).truncationMode(.middle).help(entry.path)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(14)
                .task(id: session.id) {
                    let runID = session.runId ?? ""
                    entries = runID.isEmpty ? [] : await Task.detached { OperationEntry.entries(runID: runID) }.value
                }
            } else {
                ContentUnavailableView("选择一条记录", systemImage: "list.bullet.rectangle",
                                       description: Text("查看这次运行处理了哪些文件。"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func color(_ action: String) -> Color {
        switch action {
        case "REMOVED", "FAILED": .orange
        case "TRASHED", "REBUILT": .accentColor
        default: .secondary
        }
    }
}
