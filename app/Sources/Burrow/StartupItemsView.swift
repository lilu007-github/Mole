import AppKit
import SwiftUI

struct StartupItemsView: View {
    @State private var items: [StartupItem] = []
    @State private var loading = false
    @State private var scope: StartupItem.Scope?

    private var visible: [StartupItem] { scope.map { s in items.filter { $0.scope == s } } ?? items }
    private var brokenCount: Int { items.filter { $0.state == .broken }.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $scope) {
                    Text("全部").tag(StartupItem.Scope?.none)
                    ForEach(StartupItem.Scope.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button("登录项设置") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                }
                .help("在 App 里注册的登录项只能在系统设置里查看和关闭")
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .padding(10)
            if brokenCount > 0 {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("\(brokenCount) 个启动项要启动的程序已经不存在（通常是 App 卸载后的残留）。运行「优化」时，Mole 会安全地清理失效的启动项。")
                        .font(.callout)
                    Spacer()
                    Button("前往优化") { UserDefaults.standard.set(SidebarItem.optimize.rawValue, forKey: "lastPage") }
                }
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
            Divider()
            Table(visible) {
                TableColumn("启动项") { item in
                    HStack {
                        if let app = item.app {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 18, height: 18)
                        } else {
                            Image(systemName: "gearshape").frame(width: 18)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.appName ?? item.label).lineLimit(1)
                            if item.appName != nil {
                                Text(item.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .help(item.program ?? "")
                }
                TableColumn("范围") { Text($0.scope.rawValue).foregroundStyle(.secondary) }.width(70)
                TableColumn("状态") { item in
                    Text(item.state.rawValue + (item.pid.map { $0 > 0 ? " · PID \($0)" : "" } ?? ""))
                        .foregroundStyle(color(item.state))
                }
                .width(120)
                TableColumn("启动方式") { item in
                    Text([item.runAtLoad ? "开机/登录时" : nil, item.keepAlive ? "常驻" : nil].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
                .width(110)
            }
            .contextMenu(forSelectionType: StartupItem.ID.self) { ids in
                if let item = items.first(where: { ids.contains($0.id) }) {
                    Button("在访达中显示配置文件") { NSWorkspace.shared.activateFileViewerSelecting([item.plist]) }
                    if let program = item.program, item.programExists {
                        Button("在访达中显示程序") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: program)])
                        }
                    }
                    Button("拷贝标识") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.label, forType: .string)
                    }
                }
            }
        }
        .navigationTitle("启动项")
        .task { await load() }
    }

    private func color(_ state: StartupItem.State) -> Color {
        switch state {
        case .running: .green
        case .broken: .orange
        case .disabled, .notLoaded: .secondary
        case .loaded: .primary
        }
    }

    private func load() async {
        loading = true
        items = await Task.detached { StartupItems.scan() }.value
        loading = false
    }
}
