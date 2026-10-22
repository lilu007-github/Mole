import AppKit
import SwiftUI
import Carbon.HIToolbox
import ServiceManagement

/// Launch at login through SMAppService, the supported API since macOS 13.
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// macOS may ask the user to approve the login item in System Settings.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// System-wide shortcuts through Carbon's RegisterEventHotKey, which needs no
/// permission (unlike event taps). Fixed combinations, on or off as a group.
@MainActor
final class GlobalShortcuts {
    static let shared = GlobalShortcuts()
    static let enabledKey = "globalShortcutsEnabled"

    struct Shortcut {
        let id: UInt32
        let keyCode: Int
        let label: String
        let action: @MainActor () -> Void
    }

    /// ⌃⌥⌘ plus a letter: unlikely to clash with other apps.
    static let modifiers = UInt32(controlKey | optionKey | cmdKey)
    static let all: [Shortcut] = [
        Shortcut(id: 1, keyCode: kVK_ANSI_K, label: "⌃⌥⌘K  开关保持常亮") {
            let awake = KeepAwake.shared
            if awake.isActive {
                awake.disable()
            } else {
                awake.enable(duration: nil,
                             allowDisplaySleep: UserDefaults.standard.bool(forKey: MenuBarSettings.allowDisplaySleepKey))
            }
        },
        Shortcut(id: 2, keyCode: kVK_ANSI_L, label: "⌃⌥⌘L  清洁屏幕（手动退出）") {
            CleanScreen.shared.start(duration: nil)
        },
    ]

    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    /// Applies the saved preference; call at launch and when it changes.
    func apply() {
        unregister()
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    GlobalShortcuts.all.first { $0.id == id.id }?.action()
                }
            }
            return noErr
        }, 1, &spec, nil, &handler)
        for shortcut in Self.all {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4255_5257), id: shortcut.id) // "BURW"
            if RegisterEventHotKey(UInt32(shortcut.keyCode), Self.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr,
               let ref {
                refs.append(ref)
            }
        }
    }

    private func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    /// How many shortcuts are currently registered (another app may own a combination).
    var registeredCount: Int { refs.count }
}

/// Quitting a process from the Status page. Burrow never elevates: processes
/// owned by another user or by the system fail with EPERM and are reported.
enum ProcessControl {
    /// Quitting these logs the user out, hangs the Mac or is refused by the kernel.
    static let protectedNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow", "Finder", "Dock", "SystemUIServer",
        "ControlCenter", "coreaudiod", "mds", "mds_stores", "opendirectoryd", "securityd", "syspolicyd", "tccd",
    ]

    static func refusal(pid: Int, name: String) -> String? {
        if pid <= 1 { return "系统核心进程不能结束。" }
        if pid == Int(ProcessInfo.processInfo.processIdentifier) { return "这是 Burrow 自己。" }
        if protectedNames.contains(name) { return "\(name) 是 macOS 的关键进程，结束它可能导致注销或卡死，Burrow 不会结束它。" }
        return nil
    }

    /// Asks a GUI app to quit through AppKit (it may save documents); other
    /// processes get SIGTERM, or SIGKILL when forced. Returns an error message.
    static func quit(pid: Int, name: String, force: Bool) -> String? {
        if let refusal = refusal(pid: pid, name: name) { return refusal }
        if let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
            return (force ? app.forceTerminate() : app.terminate()) ? nil : "\(name) 没有响应退出请求。"
        }
        guard kill(pid_t(pid), force ? SIGKILL : SIGTERM) == 0 else {
            switch errno {
            case EPERM: return "\(name) 属于系统或其他用户，需要管理员权限；Burrow 不会提升权限结束它。"
            case ESRCH: return "\(name) 已经不在运行。"
            default: return String(cString: strerror(errno))
            }
        }
        return nil
    }
}

/// With the Dock icon hidden Burrow runs as an accessory app: no Dock tile and
/// no app menu, reachable from the menu bar panel.
enum DockIcon {
    static func apply(hidden: Bool) {
        NSApp.setActivationPolicy(hidden ? .accessory : .regular)
        if !hidden { NSApp.activate(ignoringOtherApps: true) }
    }
}

enum AppSettings {
    static let commandQClosesKey = "commandQClosesToMenuBar"
    static let appearanceKey = "appearance"
    /// Set by the menu bar panel's 退出 so a real quit always goes through.
    @MainActor static var quitRequested = false

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String { self == .system ? "跟随系统" : self == .light ? "浅色" : "深色" }
    }

    static func applyAppearance() {
        let raw = UserDefaults.standard.string(forKey: appearanceKey) ?? Appearance.system.rawValue
        switch Appearance(rawValue: raw) ?? .system {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// Brings the existing main window forward instead of opening a second one
/// (SwiftUI's openWindow always creates a new WindowGroup window).
enum MainWindow {
    @MainActor
    static func show(_ openWindow: OpenWindowAction) {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
