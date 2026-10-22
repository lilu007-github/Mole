import Foundation

@MainActor
enum NotifierChecks {
    static func snapshot(free: Int64, devices: String) throws -> StatusSnapshot {
        let json = """
        {"disks":[{"mount":"/","used":\(500_000_000_000 - free),"total":500000000000}],"bluetooth":\(devices)}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(StatusSnapshot.self, from: Data(json.utf8))
    }

    static func register() {
        Checks.add("notify", "low disk and low Bluetooth batteries alert once a day") {
            let devices = #"[{"name":"AirPods","connected":true,"battery":"12%"},{"name":"Mouse","connected":true,"battery":"80%"},{"name":"Old","connected":false,"battery":"5%"}]"#
            let low = try snapshot(free: 4_000_000_000, devices: devices)
            let now = Date()
            let first = Notifier.alerts(for: low, lastSent: [:], now: now, diskEnabled: true, bluetoothEnabled: true)
            expect(first.map(\.id) == ["disk", "bt-AirPods"], "\(first.map(\.id))")
            let sent = Dictionary(uniqueKeysWithValues: first.map { ($0.id, now) })
            expect(Notifier.alerts(for: low, lastSent: sent, now: now.addingTimeInterval(3600),
                                   diskEnabled: true, bluetoothEnabled: true).isEmpty, "not again within a day")
            expect(Notifier.alerts(for: low, lastSent: sent, now: now.addingTimeInterval(25 * 3600),
                                   diskEnabled: true, bluetoothEnabled: true).count == 2, "again after a day")
            expect(Notifier.alerts(for: low, lastSent: [:], now: now, diskEnabled: false, bluetoothEnabled: false).isEmpty,
                   "switches off")
            let fine = try snapshot(free: 200_000_000_000, devices: "[]")
            expect(Notifier.alerts(for: fine, lastSent: [:], now: now, diskEnabled: true, bluetoothEnabled: true).isEmpty,
                   "plenty of space")
        }
    }
}
