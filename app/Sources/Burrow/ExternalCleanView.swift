import SwiftUI

/// `mo clean --external <volume>`: removes only Finder metadata (.DS_Store,
/// AppleDouble ._* files) and .TemporaryItems from a mounted drive. Mole
/// validates the target and refuses the startup disk, symlinks and nested paths.
struct ExternalCleanSheet: View {
    struct Volume: Identifiable, Hashable {
        var url: URL
        var name: String
        var capacity: Int64?
        var id: String { url.path }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var volumes: [Volume] = []
    @State private var selected: Volume.ID?
    @State private var session = TerminalSession()
    @State private var mode: String?
    @State private var confirming = false
    @State private var metadataProtected = false

    private var report: SectionReport { SectionReport(lines: session.allLines) }

    /// Mounted volumes under /Volumes other than the startup disk.
    static func mountedVolumes() -> [Volume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRootFileSystemKey, .volumeTotalCapacityKey]
        // Hidden (nobrowse) mounts are included; Apple's own snapshot mounts are not.
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) ?? []
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard url.path.hasPrefix("/Volumes/"), !url.lastPathComponent.hasPrefix("com.apple."),
                  values?.volumeIsRootFileSystem != true else { return nil }
            return Volume(url: url, name: values?.volumeName ?? url.lastPathComponent,
                          capacity: values?.volumeTotalCapacity.map(Int64.init))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("清理外置磁盘").font(.title3.bold())
            Text("删除 macOS 在 U 盘、移动硬盘上留下的临时文件夹 .TemporaryItems。磁盘上的废纸篓和你的文件不会被触碰。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if metadataProtected {
                HStack(alignment: .top) {
                    Image(systemName: "info.circle").foregroundStyle(.blue)
                    Text("当前版本的 Mole 把 .DS_Store 和 ._ 文件列为内置安全规则，始终保护，所以不会清理它们（Mole 的说明文档写的是可以清理，两者不一致）。")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(8)
                .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            if volumes.isEmpty {
                ContentUnavailableView("没有外置磁盘", systemImage: "externaldrive",
                                       description: Text("插入 U 盘或移动硬盘后点「刷新」。"))
            } else {
                Picker("磁盘", selection: $selected) {
                    ForEach(volumes) { volume in
                        Text(volume.name + (volume.capacity.map { "（\(Format.bytes($0))）" } ?? "")).tag(Optional(volume.id))
                    }
                }
                .disabled(session.isRunning)
                .onChange(of: selected) { mode = nil }
                if mode != nil {
                    List {
                        ForEach(report.sections) { section in
                            Section(section.title) {
                                ForEach(section.items) { item in
                                    HStack(alignment: .top) {
                                        Text(item.icon).foregroundStyle(item.color)
                                        Text(item.text)
                                    }
                                }
                            }
                        }
                        if !report.summary.isEmpty {
                            Section("摘要") { ForEach(report.summary, id: \.self) { Text($0) } }
                        }
                        let errors = session.allLines.filter { $0.contains("Refusing") || $0.contains("must be") || $0.contains("does not exist") }
                        if !errors.isEmpty {
                            Section("Mole 拒绝了这个磁盘") { ForEach(errors, id: \.self) { Text($0).foregroundStyle(.orange) } }
                        }
                    }
                } else {
                    Spacer()
                }
            }
            HStack {
                Button("刷新") { reload() }.disabled(session.isRunning)
                Spacer()
                if session.isRunning { ProgressView().controlSize(.small) }
                Button("关闭") { dismiss() }.disabled(session.isRunning)
                Button("预览") { run(dryRun: true) }.disabled(selected == nil || session.isRunning)
                Button("清理") { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected == nil || session.isRunning || mode != "preview" || session.exitCode != 0)
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
        .onAppear { reload() }
        .task {
            let state = try? await Whitelist.load(.clean)
            metadataProtected = state?.rows.contains { $0.pattern == "FINDER_METADATA" && $0.protected } ?? false
        }
        .confirmationDialog("清理 \(volumes.first { $0.id == selected }?.name ?? "")？", isPresented: $confirming) {
            Button("清理", role: .destructive) { run(dryRun: false) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("Mole 会重新扫描并删除 .TemporaryItems。")
        }
    }

    private func reload() {
        volumes = Self.mountedVolumes()
        if selected == nil || !volumes.contains(where: { $0.id == selected }) { selected = volumes.first?.id }
    }

    private func run(dryRun: Bool) {
        guard let path = selected else { return }
        mode = dryRun ? "preview" : "clean"
        session.start(["clean", "--external", path] + (dryRun ? ["--dry-run"] : []), usePTY: false)
    }
}
