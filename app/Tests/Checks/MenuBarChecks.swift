import AppKit

@MainActor
enum MenuBarChecks {
    static func register() {
        Checks.add("menubar", "each metric renders a short label") {
            let json = #"{"cpu":{"usage":23.6},"memory":{"used_percent":81.2},"batteries":[{"percent":64}]}"#
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let s = try decoder.decode(StatusSnapshot.self, from: Data(json.utf8))
            let net = StatusSnapshot.Network(name: "en0", rxRateMbs: 1.5, txRateMbs: 0.01, ip: "1.2.3.4")
            expect(MenuBarMetric.none.text(s, network: net) == nil, "none")
            expect(MenuBarMetric.cpu.text(s, network: net) == "CPU 24%", MenuBarMetric.cpu.text(s, network: net) ?? "")
            expect(MenuBarMetric.memory.text(s, network: net) == "内存 81%", "memory")
            expect(MenuBarMetric.battery.text(s, network: net) == "64%", "battery")
            expect(MenuBarMetric.network.text(s, network: net) == "↓1.5M ↑10K", MenuBarMetric.network.text(s, network: net) ?? "")
            expect(MenuBarMetric.network.text(s, network: nil) == nil, "no interface")
        }

        Checks.add("menubar", "ejecting a mounted image", live: true) {
            let dir = makeFixtureDir("eject")
            let image = dir.appendingPathComponent("e.dmg").path
            let name = "BurrowEject\(Int.random(in: 1000...9999))"
            _ = try runProcess("/usr/bin/hdiutil", ["create", "-quiet", "-size", "5m", "-fs", "HFS+", "-volname", name, image])
            _ = try runProcess("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", image])
            let volume = try require(ExternalCleanSheet.mountedVolumes().first { $0.name == name })
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
            expect(!FileManager.default.fileExists(atPath: volume.url.path), "unmounted")
        }
    }
}
