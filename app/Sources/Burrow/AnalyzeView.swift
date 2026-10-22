import AppKit
import SwiftUI

/// Browses `mo analyze --json`. Read-only: Burrow reveals items in Finder and
/// leaves deletion to Finder or `mo analyze` itself, which logs every Trash move.
struct AnalyzeView: View {
    /// nil is the overview scan (`mo analyze` with no path).
    @State private var trail: [String?] = [nil]
    @AppStorage("analyzeShowsTreemap") private var showTreemap = false
    @State private var results: [String: AnalyzeResult] = [:]
    @State private var loading = false
    @State private var error: String?

    private var currentPath: String? { trail.last ?? nil }
    private var cacheKey: String { currentPath ?? "<overview>" }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let result = results[cacheKey] {
                if showTreemap {
                    TreemapView(entries: result.entries.filter { $0.insight != true }) { open($0) }
                } else {
                    list(result)
                }
            } else if let error {
                ContentUnavailableView("扫描失败", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(currentPath == nil ? "正在扫描整个磁盘，首次可能需要十几秒…" : "正在扫描 \(currentPath!)…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("磁盘分析")
        .task(id: cacheKey) { await load(force: false) }
    }

    private var toolbar: some View {
        HStack {
            Button {
                trail.removeLast()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(trail.count <= 1)
            Text(currentPath ?? "概览")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Picker("", selection: $showTreemap) {
                Image(systemName: "list.bullet").tag(false)
                Image(systemName: "square.grid.2x2").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("列表 / 方块图")
            Button("选择文件夹…") { pickFolder() }
            Button {
                Task { await load(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(loading)
        }
        .padding(10)
    }

    private func list(_ result: AnalyzeResult) -> some View {
        let regular = result.entries.filter { $0.insight != true }
        let insights = result.entries.filter { $0.insight == true }
        let largest = max(regular.map(\.size).max() ?? 1, 1)
        return List {
            Section {
                ForEach(regular) { entry in
                    EntryRow(entry: entry, fraction: Double(entry.size) / Double(largest))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { open(entry) }
                        .contextMenu { menu(path: entry.path, isDir: entry.isDir) }
                }
            } header: {
                HStack {
                    Text(result.overview ? "主要位置" : "内容（双击进入文件夹）")
                    Spacer()
                    if let total = result.totalSize, total > 0 { Text("合计 \(Format.bytes(total))") }
                    if result.scanStatus == "partial" { Text("· 部分结果").foregroundStyle(.orange) }
                }
            }
            if !insights.isEmpty {
                Section("值得关注") {
                    ForEach(insights) { entry in
                        EntryRow(entry: entry, fraction: Double(entry.size) / Double(largest))
                            .contextMenu { menu(path: entry.path, isDir: entry.isDir) }
                    }
                }
            }
            if let files = result.largeFiles, !files.isEmpty {
                Section("大文件") {
                    ForEach(files) { file in
                        HStack {
                            Image(systemName: "doc")
                            Text(file.name).lineLimit(1)
                            Spacer()
                            Text(Format.bytes(file.size)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .contextMenu { menu(path: file.path, isDir: false) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func menu(path: String, isDir: Bool) -> some View {
        if isDir { Button("进入") { trail.append(path) } }
        Button("在访达中显示") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        Button("拷贝路径") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        }
    }

    private func open(_ entry: AnalyzeResult.Entry) {
        if entry.isDir { trail.append(entry.path) }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            trail = [nil, url.path]
        }
    }

    private func load(force: Bool) async {
        let key = cacheKey
        if !force, results[key] != nil { return }
        loading = true
        error = nil
        defer { loading = false }
        var args = ["analyze", "--json"]
        if let path = currentPath { args.append(path) }
        do {
            results[key] = try await MoleCLI.json(args, as: AnalyzeResult.self)
        } catch {
            if key == cacheKey { self.error = error.localizedDescription }
        }
    }
}

private struct EntryRow: View {
    let entry: AnalyzeResult.Entry
    let fraction: Double

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isDir ? "folder.fill" : "doc")
                .foregroundStyle(entry.isDir ? Color.accentColor : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).lineLimit(1)
                GeometryReader { geo in
                    Capsule().fill(.quaternary)
                        .overlay(alignment: .leading) {
                            Capsule().fill(Color.accentColor.opacity(0.7))
                                .frame(width: max(geo.size.width * fraction, 2))
                        }
                }
                .frame(height: 5)
            }
            Text(Format.bytes(entry.size))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}
