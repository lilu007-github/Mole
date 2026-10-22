import AppKit
import SwiftUI

/// One row of the `mo installer` menu: "○ Claude.dmg   296.8MB | Downloads".
struct InstallerRow: Identifiable, Hashable {
    var index: Int
    var name: String
    var size: String
    var source: String
    var id: Int { index }

    /// Parses the menu rows currently on screen, in menu order.
    static func parse(_ lines: [String]) -> [InstallerRow] {
        let pattern = #/[○●]\s+(.+?)\s{2,}(\S+)\s\|\s(.+?)\s*$/#
        var rows: [InstallerRow] = []
        for line in lines {
            guard let m = line.firstMatch(of: pattern) else { continue }
            rows.append(InstallerRow(index: rows.count, name: String(m.1), size: String(m.2),
                                     source: String(m.3)))
        }
        return rows
    }

    func sameFile(as other: InstallerRow) -> Bool {
        name == other.name && size == other.size && source == other.source
    }
}

struct InstallerView: View {
    @State private var rows: [InstallerRow] = []
    @State private var selection = Set<InstallerRow.ID>()
    @State private var loading = false
    @State private var loaded = false
    @State private var job: InstallerJob?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("下载、桌面、文档等位置里残留的 .dmg / .pkg / .zip 等安装包")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(selection.isEmpty ? "\(rows.count) 个" : "已选 \(selection.count) 个")
                    .foregroundStyle(.secondary)
                Button("全选") { selection = Set(rows.map(\.id)) }.disabled(rows.isEmpty)
                Button("删除所选…") {
                    job = InstallerJob(expected: rows, selected: selection)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty)
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(loading)
            }
            .padding(10)
            Divider()
            if loading && rows.isEmpty {
                ProgressView("正在查找安装包…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if loaded && rows.isEmpty {
                ContentUnavailableView("没有找到安装包", systemImage: "shippingbox",
                                       description: Text("常用位置里没有残留的安装文件。"))
            } else {
                Table(rows, selection: $selection) {
                    TableColumn("文件") { row in
                        HStack {
                            Image(systemName: "shippingbox").foregroundStyle(.secondary)
                            Text(row.name)
                        }
                    }
                    TableColumn("大小") { Text($0.size).monospacedDigit() }.width(90)
                    TableColumn("位置") { Text($0.source).foregroundStyle(.secondary) }.width(140)
                }
            }
        }
        .navigationTitle("安装包")
        .task { if !loaded { await load() } }
        .sheet(item: $job, onDismiss: {
            selection.removeAll()
            Task { await load() }
        }) { job in
            InstallerSheet(job: job)
        }
    }

    /// Without a terminal, `mo installer --dry-run` prints the menu once and exits.
    private func load() async {
        loading = true
        defer { loading = false }
        let data = (try? await MoleCLI.run(["installer", "--dry-run"])) ?? Data()
        var parser = TerminalTextParser()
        var lines: [String] = []
        var current = ""
        parser.feed(String(decoding: data, as: UTF8.self), lines: &lines, current: &current)
        rows = InstallerRow.parse(lines + [current])
        loaded = true
    }
}

struct InstallerJob: Identifiable {
    let id = UUID()
    let expected: [InstallerRow]
    let selected: Set<InstallerRow.ID>
}

/// Runs the real `mo installer` menu in a pseudo-terminal and selects the same
/// rows the user ticked, after checking the menu lists the same files in the
/// same order. Mole then prints its own delete plan, and only the user's click
/// confirms it.
struct InstallerSheet: View {
    let job: InstallerJob
    @Environment(\.dismiss) private var dismiss
    @State private var session = TerminalSession()
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("删除 \(job.selected.count) 个安装包").font(.title3.bold())
            Text("Burrow 会在 Mole 的菜单里选中这些文件，然后显示 Mole 的删除清单，请核对后确认。")
                .foregroundStyle(.secondary)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            RawOutputView(lines: session.allLines)
                .frame(minHeight: 320)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            PromptBar(session: session, confirmLabel: "确认删除") { dismiss() }
        }
        .padding(20)
        .frame(width: 760, height: 560)
        .interactiveDismissDisabled(session.isRunning)
        .task { await drive() }
        .onDisappear { if session.isRunning { session.terminate() } }
    }

    private func drive() async {
        session.start(["installer"], usePTY: true)
        problem = await InstallerMenuDriver.select(job.selected, expecting: job.expected, in: session)
    }
}

enum InstallerMenuDriver {
    /// Ticks `selected` in the live menu and presses Enter to leave it.
    /// Returns a problem description, after quitting the menu, when the menu does
    /// not show exactly the expected files or the selection count is off.
    @MainActor
    static func select(_ selected: Set<Int>, expecting expected: [InstallerRow],
                       in session: TerminalSession) async -> String? {
        // Wait for the menu footer, which is drawn after every row.
        let deadline = Date().addingTimeInterval(120)
        while !session.allLines.contains(where: { $0.contains("Space Select") }) {
            guard session.isRunning, Date() < deadline else { return "没有等到 Mole 的选择菜单。" }
            try? await Task.sleep(for: .milliseconds(200))
        }

        // The menu shows one page; every visible row must match the list the user chose from.
        let visible = InstallerRow.parse(session.allLines)
        let pageMatches = !visible.isEmpty && visible.count <= expected.count
            && zip(visible, expected).allSatisfy { $0.sameFile(as: $1) }
        guard pageMatches, let lastSelected = selected.max(), lastSelected < expected.count else {
            session.send("q")
            return "安装包列表已经变化，已取消。请刷新列表后重新选择。"
        }

        // Move down the menu and toggle each chosen row, one key at a time.
        for index in 0...lastSelected {
            if selected.contains(index) {
                session.send(" ")
                try? await Task.sleep(for: .milliseconds(60))
            }
            if index < lastSelected {
                session.send("\u{1b}[B")
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
        try? await Task.sleep(for: .milliseconds(300))

        // The header reads "Select Installers to Remove , 512MB, 2 selected".
        let header = session.allLines.last { $0.contains("Select Installers to Remove") } ?? ""
        guard header.contains(", \(selected.count) selected") else {
            session.send("q")
            return "Mole 菜单里的选择数量和你勾选的不一致，已取消。"
        }
        // Enter only closes the selection menu; Mole then shows its delete plan
        // and waits for the confirmation that PromptBar leaves to the user.
        session.send("\r")
        return nil
    }
}
