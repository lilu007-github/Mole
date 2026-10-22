import Foundation

@MainActor
enum UpdateChecks {
    static func register() {
        Checks.add("appupdates", "brew outdated JSON parses, build suffixes trimmed") {
            let json = #"{"formulae":[],"casks":[{"name":"orbstack","installed_versions":["2.0.5,19905"],"current_version":"2.2.4,21120"}]}"#
            let rows = AppUpdates.parseBrew(Data(json.utf8))
            expect(rows.count == 1 && rows[0].reference == "orbstack", "\(rows)")
            expect(rows.first?.installed == "2.0.5" && rows.first?.latest == "2.2.4", "\(rows)")
        }

        Checks.add("appupdates", "appcasts with attributes or elements give the newest item") {
            let attributes = #"""
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
            <item><enclosure url="a" sparkle:version="120" sparkle:shortVersionString="1.2.0"/></item>
            <item><enclosure url="b" sparkle:version="135" sparkle:shortVersionString="1.3.5"/></item>
            <item><enclosure url="c" sparkle:version="99" sparkle:shortVersionString="0.9"/></item>
            </channel></rss>
            """#
            let a = AppcastParser.newest(in: Data(attributes.utf8))
            expect(a?.build == "135" && a?.short == "1.3.5", "\(String(describing: a))")
            let elements = #"""
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
            <item><sparkle:version>2.10</sparkle:version><sparkle:shortVersionString>2.10</sparkle:shortVersionString></item>
            <item><sparkle:version>2.9</sparkle:version><sparkle:shortVersionString>2.9</sparkle:shortVersionString></item>
            </channel></rss>
            """#
            expect(AppcastParser.newest(in: Data(elements.utf8))?.short == "2.10", "2.10 beats 2.9")
            expect(AppcastParser.newest(in: Data("not xml".utf8)) == nil, "garbage")
        }

        Checks.add("appupdates", "live checks run without changing anything", live: true) {
            let brew = try await AppUpdates.homebrew()
            expect(brew.allSatisfy { !$0.reference.isEmpty && $0.source == .homebrew }, "\(brew.count) casks")
            let sparkle = await AppUpdates.sparkle()
            expect(sparkle.allSatisfy { FileManager.default.fileExists(atPath: $0.reference) }, "\(sparkle.map(\.name))")
            print("     (\(brew.count) Homebrew, \(sparkle.count) Sparkle updates found)")
        }
    }
}
