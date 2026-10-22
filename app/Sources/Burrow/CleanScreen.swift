import AppKit
import ApplicationServices
import Observation
import SwiftUI

/// Blacks out every display so the screen can be wiped. With Accessibility
/// permission it also swallows keyboard, brightness and volume keys; only Esc
/// gets through, and holding it for two seconds exits. Everything is undone on
/// exit, and the event tap dies with the process if Burrow quits.
@MainActor
@Observable
final class CleanScreen {
    static let shared = CleanScreen()
    nonisolated static let accessibilitySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let durations: [(label: String, seconds: TimeInterval?)] = [
        ("1 分钟", 60), ("2 分钟", 120), ("5 分钟", 300), ("手动退出", nil),
    ]
    static let holdToExit: TimeInterval = 2

    private(set) var isActive = false
    private(set) var endsAt: Date?
    private(set) var blockingKeys = false
    /// 0…1 while Esc is held.
    private(set) var exitProgress: Double = 0

    private var windows: [NSWindow] = []
    private var escMonitor: Any?
    private var escPressedAt: Date?
    private var ticker: Timer?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?

    func start(duration: TimeInterval?) {
        guard !isActive else { return }
        isActive = true
        endsAt = duration.map { Date().addingTimeInterval($0) }
        exitProgress = 0

        NSApp.activate(ignoringOtherApps: true)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching, .disableHideApplication]
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered,
                                  defer: false, screen: screen)
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            window.backgroundColor = .black
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.contentView = NSHostingView(rootView: CleanScreenOverlay(showsControls: screen == NSScreen.main))
            window.setFrame(screen.frame, display: true)
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
        NSCursor.setHiddenUntilMouseMoves(true)
        blockingKeys = installKeyTap()

        // Esc reaches the app (the tap lets it through); count how long it is held.
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                if event.type == .keyDown, self.escPressedAt == nil { self.escPressedAt = Date() }
                if event.type == .keyUp { self.escPressedAt = nil }
            }
            return nil // no beeps while the screen is black
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        guard isActive else { return }
        ticker?.invalidate()
        ticker = nil
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
        escPressedAt = nil
        removeKeyTap()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        NSApp.presentationOptions = []
        isActive = false
        endsAt = nil
        blockingKeys = false
        exitProgress = 0
    }

    private func tick() {
        if let pressed = escPressedAt {
            exitProgress = min(Date().timeIntervalSince(pressed) / Self.holdToExit, 1)
            if exitProgress >= 1 { stop(); return }
        } else {
            exitProgress = 0
        }
        if let endsAt, Date() >= endsAt { stop() }
    }

    // MARK: Key blocking

    private func installKeyTap() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        var mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        mask |= 1 << 14 // NX_SYSDEFINED: brightness, volume, media and Dictation keys
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: cleanScreenTapCallback, userInfo: nil)
        else { return false }
        cleanScreenActiveTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        tapSource = source
        return true
    }

    private func removeKeyTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
        cleanScreenActiveTap = nil
    }
}

nonisolated(unsafe) private var cleanScreenActiveTap: CFMachPort?

/// Swallows every key event except Esc; re-enables the tap if macOS paused it.
private func cleanScreenTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                    userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = cleanScreenActiveTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if (type == .keyDown || type == .keyUp), event.getIntegerValueField(.keyboardEventKeycode) == 53 {
        return Unmanaged.passUnretained(event)
    }
    return nil
}

private struct CleanScreenOverlay: View {
    let showsControls: Bool
    private let state = CleanScreen.shared

    var body: some View {
        ZStack {
            Color.black
            if showsControls {
                VStack(spacing: 14) {
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(footer(now: context.date))
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    if !state.blockingKeys {
                        Text("亮度、音量键仍可使用：在「隐私与安全性 → 辅助功能」里打开 Burrow 即可一并屏蔽")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    HoldToExitButton(progress: state.exitProgress) { CleanScreen.shared.stop() }
                        .padding(.bottom, 60)
                }
            }
        }
        .ignoresSafeArea()
    }

    private func footer(now: Date) -> String {
        let lock = state.blockingKeys ? "屏幕和键盘已锁定" : "屏幕已锁定"
        var parts = [lock]
        if let endsAt = state.endsAt {
            parts.append("\(max(Int(endsAt.timeIntervalSince(now).rounded(.up)), 0)) 秒后自动退出")
        }
        parts.append("长按 Esc 2 秒退出")
        return parts.joined(separator: " · ")
    }
}

/// Needs a one-second press, so wiping the screen cannot click it by accident.
private struct HoldToExitButton: View {
    let progress: Double
    let exit: () -> Void
    @State private var pressing = false

    var body: some View {
        ZStack {
            Capsule().stroke(.white.opacity(0.25), lineWidth: 1)
            Capsule().fill(.white.opacity(0.15)).scaleEffect(x: pressing ? 1 : max(progress, 0.001), anchor: .leading)
                .animation(pressing ? .linear(duration: 1) : .default, value: pressing)
            Text("长按退出").foregroundStyle(.white.opacity(0.7))
        }
        .frame(width: 140, height: 36)
        .clipShape(Capsule())
        .onLongPressGesture(minimumDuration: 1, perform: exit, onPressingChanged: { pressing = $0 })
    }
}
