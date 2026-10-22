import Foundation
import IOKit.pwr_mgt
import Observation

/// Keeps the Mac awake with an IOKit power assertion, the same mechanism as
/// `caffeinate`. The assertion is released on disable, on expiry and when the
/// process exits, so nothing persists after Burrow quits.
@MainActor
@Observable
final class KeepAwake {
    static let shared = KeepAwake()

    private(set) var isActive = false
    private(set) var until: Date?
    private(set) var allowDisplaySleep = false

    private var assertionID: IOPMAssertionID = 0
    private var expiry: Task<Void, Never>?

    static let durations: [(label: String, seconds: TimeInterval?)] = [
        ("一直", nil),
        ("30 分钟", 30 * 60),
        ("1 小时", 60 * 60),
        ("2 小时", 2 * 60 * 60),
        ("5 小时", 5 * 60 * 60),
    ]

    /// - Parameters:
    ///   - duration: nil keeps the Mac awake until disabled.
    ///   - allowDisplaySleep: true keeps tasks running but lets the screen turn off.
    func enable(duration: TimeInterval?, allowDisplaySleep: Bool) {
        disable()
        let type = allowDisplaySleep ? kIOPMAssertionTypePreventUserIdleSystemSleep
            : kIOPMAssertionTypePreventUserIdleDisplaySleep
        let result = IOPMAssertionCreateWithName(type as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "Burrow keep awake" as CFString,
                                                 &assertionID)
        guard result == kIOReturnSuccess else { return }
        isActive = true
        self.allowDisplaySleep = allowDisplaySleep
        if let duration {
            until = Date().addingTimeInterval(duration)
            expiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration))
                if !Task.isCancelled { self?.disable() }
            }
        }
    }

    func disable() {
        expiry?.cancel()
        expiry = nil
        if isActive {
            IOPMAssertionRelease(assertionID)
        }
        assertionID = 0
        isActive = false
        until = nil
    }

    var statusText: String {
        guard isActive else { return "未开启" }
        let screen = allowDisplaySleep ? "屏幕可以关闭" : "屏幕保持点亮"
        guard let until else { return "\(screen)，直到手动关闭" }
        return "\(screen)，到 \(until.formatted(date: .omitted, time: .shortened))"
    }
}
