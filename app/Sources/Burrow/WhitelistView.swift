import AppKit
import SwiftUI

/// Edits a Mole whitelist through Mole's own load and save functions.
struct WhitelistSheet: View {
    let mode: Whitelist.Mode
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Whitelist.Row] = []
    @State private var custom: [String] = []
    @State private var original: (rows: [Whitelist.Row], custom: [String])?
    @State private var search = ""
    @State private var newPattern = ""
    @State private var error: String?
    @State private var saving = false

    private var visible: [Whitelist.Row] {
        let filtered = search.isEmpty ? rows : rows.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.pattern.localizedCaseInsensitiveContains(search)
        }
        // Protected rows first, like Mole's menu.
        return filtered.filter(\.protected) + filtered.filter { !$0.protected }
    }

    private var changed: Bool {
        guard let original else { return false }
        return original.rows != rows || original.custom != custom
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode.title).font(.title3.bold())
            Text(mode == .clean
                 ? "勾选的缓存在清理时会被保留。勾选「Trash」可以让清理时不清空废纸篓。"
                 : "勾选的优化项目在优化时会被跳过。")
                .foregroundStyle(.secondary)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            TextField("搜索", text: $search).textFieldStyle(.roundedBorder)
            List {
                Section("预设项目（\(rows.filter(\.protected).count)/\(rows.count) 已保护）") {
                    ForEach(visible) { row in
                        Toggle(isOn: binding(for: row)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.name + (row.alwaysProtected ? "（Mole 内置安全规则，始终保护）" : ""))
                                Text(row.pattern).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                        .disabled(row.alwaysProtected)
                    }
                }
                if mode == .clean {
                    Section("自定义规则（Mole 的其他默认保护和你添加的路径，保存时一并保留）") {
                        ForEach(custom, id: \.self) { pattern in
                            HStack {
                                Text(pattern).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button {
                                    custom.removeAll { $0 == pattern }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("不再保护")
                            }
                        }
                        HStack {
                            TextField("路径或通配符，例如 ~/Library/Caches/com.example.app/*", text: $newPattern)
                                .onSubmit(addPattern)
                            Button("选择…", action: choosePath)
                            Button("添加", action: addPattern).disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            }
            HStack {
                Text("保存后写入 ~/.config/mole/\(mode == .clean ? "whitelist" : "whitelist_optimize")，命令行的 mo 也会使用。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("取消") { dismiss() }
                Button("保存") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!changed || saving)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 620)
        .task { await load() }
    }

    private func binding(for row: Whitelist.Row) -> Binding<Bool> {
        Binding(get: { rows.first { $0.id == row.id }?.protected ?? false },
                set: { on in
                    if let index = rows.firstIndex(where: { $0.id == row.id }) { rows[index].protected = on }
                })
    }

    private func load() async {
        do {
            let state = try await Whitelist.load(mode)
            rows = state.rows
            custom = state.custom
            original = (state.rows, state.custom)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await Whitelist.save(mode, protectedRows: rows.filter(\.protected), custom: custom)
            await load()
            dismiss()
        } catch {
            self.error = "保存失败，没有改动：\(error.localizedDescription)"
        }
    }

    private func addPattern() {
        let pattern = PurgePaths.abbreviate(PurgePaths.expand(newPattern.trimmingCharacters(in: .whitespaces)))
        guard !pattern.isEmpty, !custom.contains(pattern) else { return }
        custom.append(pattern)
        newPattern = ""
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        newPattern = PurgePaths.abbreviate(url.path) + (url.hasDirectoryPath ? "/*" : "")
    }
}
