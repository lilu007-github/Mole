import Foundation
import UserNotifications

/// Local notifications for disk space, Bluetooth batteries and keep awake.
/// Each kind has its own switch in Settings and fires at most once a day.
@MainActor
enum Notifier {
    enum Kind: String, CaseIterable {
        case diskSpace = "notifyDiskSpace"
        case bluetoothBattery = "notifyBluetoothBattery"
        case keepAwake = "notifyKeepAwake"

        var title: String {
            switch self {
            case .diskSpace: "启动磁盘空间不足时提醒"
            case .bluetoothBattery: "蓝牙设备电量低时提醒"
            case .keepAwake: "保持常亮结束时提醒"
            }
        }
    }

    struct Alert: Equatable {
        var id: String
        var title: String
        var body: String
    }

    static let lowDiskBytes: Int64 = 10_000_000_000
    static let lowBluetoothPercent = 20
    static let repeatInterval: TimeInterval = 24 * 3600

    private static var lastSent: [String: Date] = [:]

    static func isEnabled(_ kind: Kind) -> Bool { UserDefaults.standard.bool(forKey: kind.rawValue) }

    /// Called after each status refresh.
    static func evaluate(_ snapshot: StatusSnapshot) {
        let due = alerts(for: snapshot, lastSent: lastSent, now: Date(),
                         diskEnabled: isEnabled(.diskSpace), bluetoothEnabled: isEnabled(.bluetoothBattery))
        for alert in due {
            lastSent[alert.id] = Date()
            post(alert)
        }
    }

    static func keepAwakePaused(percent: Int) {
        guard isEnabled(.keepAwake) else { return }
        post(Alert(id: "keep-awake", title: "保持常亮已暂停", body: "电量剩余 \(percent)%，接通电源后会自动恢复。"))
    }

    static func keepAwakeResumed() {
        guard isEnabled(.keepAwake) else { return }
        post(Alert(id: "keep-awake", title: "保持常亮已恢复", body: "已接通电源。"))
    }

    static func keepAwakeEnded() {
        guard isEnabled(.keepAwake) else { return }
        post(Alert(id: "keep-awake", title: "保持常亮已结束", body: "已恢复正常的睡眠设置。"))
    }

    /// Pure decision, so it can be checked without a notification center.
    static func alerts(for snapshot: StatusSnapshot, lastSent: [String: Date], now: Date,
                       diskEnabled: Bool, bluetoothEnabled: Bool) -> [Alert] {
        func due(_ id: String) -> Bool { lastSent[id].map { now.timeIntervalSince($0) >= repeatInterval } ?? true }
        var result: [Alert] = []
        if diskEnabled, let disk = snapshot.disks?.first(where: { $0.mount == "/" }),
           let total = disk.total, let used = disk.used, total - used < lowDiskBytes, due("disk") {
            result.append(Alert(id: "disk", title: "启动磁盘空间不足",
                                body: "只剩 \(Format.bytes(total - used)) 可用，打开 Burrow 的「清理」释放空间。"))
        }
        if bluetoothEnabled {
            for device in snapshot.bluetooth ?? [] where device.connected == true {
                guard let percent = Int((device.battery ?? "").filter(\.isNumber)), percent < lowBluetoothPercent,
                      due("bt-\(device.name)") else { continue }
                result.append(Alert(id: "bt-\(device.name)", title: "\(device.name) 电量低",
                                    body: "剩余 \(percent)%，需要充电了。"))
            }
        }
        return result
    }

    static func requestPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private static func post(_ alert: Alert) {
        guard Bundle.main.bundleIdentifier != nil else { return } // not inside an app bundle (checks)
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        let request = UNNotificationRequest(identifier: alert.id + "-\(Int(Date().timeIntervalSince1970))",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
