import AppKit
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
