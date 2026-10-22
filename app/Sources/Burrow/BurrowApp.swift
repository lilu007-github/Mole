import AppKit
import SwiftUI

@main
struct BurrowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Burrow") {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
        Settings {
            SettingsView()
        }
    }
}

/// A SwiftPM executable starts as a background process; promote it to a regular
/// app so it gets a Dock icon and keyboard focus when launched outside a bundle.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case status, analyze, clean, uninstall

    var id: String { rawValue }

    var title: String {
        switch self {
        case .status: "系统状态"
        case .analyze: "磁盘分析"
        case .clean: "清理"
        case .uninstall: "卸载应用"
        }
    }

    var symbol: String {
        switch self {
        case .status: "gauge.with.dots.needle.67percent"
        case .analyze: "chart.pie"
        case .clean: "sparkles"
        case .uninstall: "trash"
        }
    }
}

struct ContentView: View {
    @State private var selection: SidebarItem? = .status

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            if MoleCLI.executableURL == nil {
                MissingCLIView()
            } else {
                switch selection ?? .status {
                case .status: StatusView()
                case .analyze: AnalyzeView()
                case .clean: CleanView()
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
