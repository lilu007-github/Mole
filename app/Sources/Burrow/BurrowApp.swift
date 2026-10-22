import AppKit
import SwiftUI

@main
struct BurrowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(MenuBarSettings.showKey) private var showMenuBar = true

    var body: some Scene {
        WindowGroup("Burrow", id: "main") {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
        Settings {
            SettingsView()
        }
        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarView()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

/// A SwiftPM executable starts as a background process; promote it to a regular
/// app so it gets a Dock icon and keyboard focus when launched outside a bundle.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// With the menu bar item on, closing the window keeps Burrow running there.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        UserDefaults.standard.object(forKey: MenuBarSettings.showKey) as? Bool == false
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { KeepAwake.shared.disable() }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case status, analyze, clean, ai, optimize, installer, uninstall

    var id: String { rawValue }

    var title: String {
        switch self {
        case .status: "系统状态"
        case .analyze: "磁盘分析"
        case .clean: "清理"
        case .ai: "AI 数据"
        case .optimize: "优化"
        case .installer: "安装包"
        case .uninstall: "卸载应用"
        }
    }

    var symbol: String {
        switch self {
        case .status: "gauge.with.dots.needle.67percent"
        case .analyze: "chart.pie"
        case .clean: "sparkles"
        case .ai: "brain"
        case .optimize: "wand.and.stars"
        case .installer: "shippingbox"
        case .uninstall: "trash"
        }
    }
}

struct ContentView: View {
    // Reopens on the page used last.
    @AppStorage("lastPage") private var lastPage: SidebarItem = .status

    private var selection: Binding<SidebarItem?> {
        Binding(get: { lastPage }, set: { if let page = $0 { lastPage = page } })
    }

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: selection) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            if MoleCLI.executableURL == nil {
                MissingCLIView()
            } else {
                switch lastPage {
                case .status: StatusView()
                case .analyze: AnalyzeView()
                case .clean: CleanView()
                case .ai: AIDataView()
                case .optimize: OptimizeView()
                case .installer: InstallerView()
                case .uninstall: UninstallView()
                }
            }
        }
    }
}

struct MissingCLIView: View {
    var body: some View {
        ContentUnavailableView {
            Label("找不到 mo 命令", systemImage: "exclamationmark.triangle")
        } description: {
            Text("Burrow 通过 Mole CLI 完成所有操作。请先安装 Mole，或在设置（⌘,）里指定 mo / mole 的路径。")
        } actions: {
            SettingsLink { Text("打开设置") }
        }
    }
}
