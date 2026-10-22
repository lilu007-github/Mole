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
        .commands { ToolCommands() }
        Window("关于 Burrow", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        Window("诊断", id: "doctor") {
            DoctorView()
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
        AppSettings.applyAppearance()
        DockIcon.apply(hidden: UserDefaults.standard.bool(forKey: MenuBarSettings.hideDockKey)
            && UserDefaults.standard.object(forKey: MenuBarSettings.showKey) as? Bool != false)
        NSApp.activate(ignoringOtherApps: true)
        MainActor.assumeIsolated { GlobalShortcuts.shared.apply() }
    }

    /// With the menu bar item on, closing the window keeps Burrow running there.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let closeInstead = UserDefaults.standard.bool(forKey: AppSettings.commandQClosesKey)
            && UserDefaults.standard.object(forKey: MenuBarSettings.showKey) as? Bool != false
        guard closeInstead, !AppSettings.quitRequested else { return .terminateNow }
        NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) }.forEach { $0.close() }
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        UserDefaults.standard.object(forKey: MenuBarSettings.showKey) as? Bool == false
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { KeepAwake.shared.disable() }
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
                case .purge: PurgeView()
                case .optimize: OptimizeView()
                case .installer: InstallerView()
                case .uninstall: UninstallView()
                case .updates: AppUpdatesView()
                case .startup: StartupItemsView()
                case .history: HistoryView()
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
