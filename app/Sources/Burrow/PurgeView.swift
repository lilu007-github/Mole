import AppKit
import SwiftUI

/// Old project build artifacts (node_modules, .venv, build, dist…) via `mo purge`.
struct PurgeView: View {
    @State private var scanPaths: [String]?
    @State private var session = TerminalSession()
    @State private var scanned = false
    @State private var selection = Set<PurgeArtifact.ID>()
    @State private var job: PurgeJob?
    @State private var saveError: String?

    /// Mole scans its defaults when the config file does not exist.
    private var effectivePaths: [String] { scanPaths ?? [] }

    private var artifacts: [PurgeArtifact] {
        PurgeArtifact.parse(session.allLines, scanPaths: effectivePaths)
    }

    private var groups: [(project: String, items: [PurgeArtifact])] {
        var order: [String] = []
        var map: [String: [PurgeArtifact]] = [:]
        for artifact in artifacts {
            if map[artifact.project] == nil { order.append(artifact.project) }
            map[artifact.project, default: []].append(artifact)
        }
        return order.map { ($0, map[$0]!) }
    }

    private var chosenSize: Int64 {
        artifacts.filter { selection.contains($0.id) }.reduce(0) { $0 + HistoryReport.parseSize($1.size) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            scanPathsBar
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.isRunning ? "正在扫描项目…" : scanned ? "找到 \(artifacts.count) 个可清理的构建产物" : "项目构建产物")
                        .font(.headline)
                    Text("node_modules、.venv、build、dist、__pycache__ 等可以重新生成的目录。最近 7 天内改动过的不会列出。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if session.isRunning { ProgressView().controlSize(.small) }
                Button(scanned ? "重新扫描" : "扫描") { scan() }.disabled(session.isRunning)
                Button("全选") { selection = Set(artifacts.map(\.id)) }.disabled(artifacts.isEmpty)
                Button(selection.isEmpty ? "清理所选…" : "清理 \(selection.count) 项（\(Format.bytes(chosenSize))）…") {
                    job = PurgeJob(paths: Set(selection))
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty || session.isRunning)
            }
            .padding(12)
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("项目构建产物")
        .onAppear { scanPaths = PurgePaths.load() }
        .sheet(item: $job, onDismiss: { selection.removeAll(); scan() }) { PurgeSheet(job: $0) }
    }

    private var scanPathsBar: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("扫描位置").bold()
            if let paths = scanPaths {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(paths, id: \.self) { path in
                            HStack(spacing: 4) {
                                Text(path).lineLimit(1)
                                Button {
                                    update(paths.filter { $0 != path })
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.borderless)
                                .help("从扫描位置中移除")
                            }
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                        }
                    }
                }
            } else {
                Text("Mole 默认位置（~/Projects、~/GitHub、~/Code 等）").foregroundStyle(.secondary)
            }
            Spacer()
            if let saveError { Text(saveError).foregroundStyle(.red).lineLimit(1) }
            Button("添加文件夹…") { addFolder() }
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if !scanned {
            ContentUnavailableView {
                Label("还没有扫描", systemImage: "hammer")
            } description: {
                Text("先确认上面的扫描位置包含你的项目文件夹，再点「扫描」。扫描只是预览，不会删除任何东西。")
            } actions: {
                Button("扫描") { scan() }.buttonStyle(.borderedProminent)
            }
        } else if !session.isRunning && artifacts.isEmpty {
            ContentUnavailableView("没有找到可清理的构建产物", systemImage: "checkmark.circle",
                                   description: Text("可以添加更多扫描位置后再试。"))
        } else {
            List {
                ForEach(groups, id: \.project) { group in
                    Section {
                        ForEach(group.items) { artifact in
                            ArtifactRow(artifact: artifact, project: group.project, selection: $selection)
                        }
                    } header: {
                        HStack {
                            Text(PurgePaths.abbreviate(group.project))
                            Spacer()
                            Button("选中整个项目") { group.items.forEach { selection.insert($0.id) } }
                                .buttonStyle(.borderless).font(.caption)
                        }
                    }
                }
            }
        }
    }

    private func scan() {
        selection.removeAll()
        scanned = true
        session.start(["purge", "--dry-run"], usePTY: false)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.map { PurgePaths.abbreviate($0.path) }
        update((scanPaths ?? []) + added.filter { !(scanPaths ?? []).contains($0) })
    }

    private func update(_ paths: [String]) {
        do {
            try PurgePaths.save(paths)
            scanPaths = PurgePaths.load()
            saveError = nil
        } catch {
            saveError = "保存失败：\(error.localizedDescription)"
        }
    }
}

private struct ArtifactRow: View {
    let artifact: PurgeArtifact
    let project: String
    @Binding var selection: Set<PurgeArtifact.ID>

    private var isOn: Binding<Bool> {
        Binding(get: { selection.contains(artifact.id) },
                set: { on in
                    if on { selection.insert(artifact.id) } else { selection.remove(artifact.id) }
                })
    }

    private var relativePath: String {
        artifact.path.hasPrefix(project + "/") ? String(artifact.path.dropFirst(project.count + 1)) : artifact.path
    }

    var body: some View {
        Toggle(isOn: isOn) {
            HStack {
                Text(relativePath).lineLimit(1)
                Spacer()
                Text(artifact.size).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            Button("在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: artifact.path)])
            }
        }
    }
}

struct PurgeJob: Identifiable {
    let id = UUID()
    let paths: Set<String>
}

/// Runs the real `mo purge` menu, selects exactly the chosen paths, and leaves
/// Mole's final confirmation to the user once its listed paths match.
struct PurgeSheet: View {
    let job: PurgeJob
    @Environment(\.dismiss) private var dismiss
    @State private var session = TerminalSession()
    @State private var status = "正在扫描…"
    @State private var problem: String?
    @State private var verified = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("清理 \(job.paths.count) 个构建产物").font(.title3.bold())
            Text("构建产物会被直接删除（不进废纸篓），需要时重新安装依赖或重新构建即可恢复。")
                .foregroundStyle(.secondary)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if verified {
                Label("Mole 列出的路径和你的选择完全一致，请确认。", systemImage: "checkmark.shield.fill")
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
            PromptBar(session: session, confirmLabel: "确认清理") { dismiss() }
                .opacity(verified || problem != nil || !session.isRunning ? 1 : 0)
        }
        .padding(20)
        .frame(width: 800, height: 600)
        .interactiveDismissDisabled(session.isRunning)
        .task {
            session.start(["purge"], usePTY: true, columns: PurgeMenuDriver.columns)
            problem = await PurgeMenuDriver.select(job.paths, in: session) { status = $0 }
            verified = problem == nil
        }
        .onDisappear { if session.isRunning { session.terminate() } }
    }
}
