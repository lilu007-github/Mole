import Foundation

@MainActor
enum StartupChecks {
    static func register() {
        Checks.add("startup", "broken, disabled and app-owned agents are told apart") {
            let dir = makeFixtureDir("agents")
            func plist(_ name: String, _ dict: [String: Any]) throws {
                let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
                try data.write(to: dir.appendingPathComponent(name + ".plist"))
            }
            try plist("com.example.gone", ["Label": "com.example.gone", "ProgramArguments": ["/Applications/Gone.app/Contents/MacOS/helper"], "RunAtLoad": true])
            try plist("com.example.off", ["Label": "com.example.off", "Program": "/bin/sleep", "Disabled": true])
            try plist("com.apple.Safari.helper", ["Label": "com.apple.Safari.helper", "Program": "/bin/sleep", "KeepAlive": ["SuccessfulExit": false]])
            let saved = StartupItems.folders
            StartupItems.folders = [(.user, dir.path)]
            defer { StartupItems.folders = saved }
            let items = Dictionary(uniqueKeysWithValues: StartupItems.scan().map { ($0.label, $0) })
            expect(items["com.example.gone"]?.state == .broken, "missing program")
            expect(items["com.example.gone"]?.runAtLoad == true, "run at load")
            expect(items["com.example.off"]?.state == .disabled, "disabled")
            expect(items["com.apple.Safari.helper"]?.keepAlive == true, "KeepAlive dictionary counts")
            expect(items["com.apple.Safari.helper"]?.app?.lastPathComponent == "Safari.app", "owner from label prefix")
            expect(StartupItems.scan().first?.state == .broken, "broken items sort first")
        }
    }
}
