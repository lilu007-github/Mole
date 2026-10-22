import Foundation

/// Compares the bundled Mole CLI with tw93/Mole's latest GitHub release.
/// Burrow itself is built from source, so a newer Mole means: run
/// app/scripts/sync-upstream.sh and rebuild.
enum UpdateChecker {
    enum Result: Equatable {
        case upToDate(current: String)
        case available(current: String, latest: String, notes: URL)
        case failed(String)
    }

    static let releasesAPI = URL(string: "https://api.github.com/repos/tw93/Mole/releases/latest")!

    static func check() async -> Result {
        guard let current = await currentVersion() else { return .failed("读取不到当前的 Mole 版本。") }
        var request = URLRequest(url: releasesAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String
            else { return .failed("GitHub 没有返回版本信息，稍后再试。") }
            let latest = normalize(tag)
            let notes = (json["html_url"] as? String).flatMap(URL.init(string:))
                ?? URL(string: "https://github.com/tw93/Mole/releases")!
            return isNewer(latest, than: current) ? .available(current: current, latest: latest, notes: notes)
                : .upToDate(current: current)
        } catch {
            return .failed("无法连接 GitHub：\(error.localizedDescription)")
        }
    }

    /// The bundled version from Info.plist, else what the CLI reports.
    static func currentVersion() async -> String? {
        if let bundled = Bundle.main.object(forInfoDictionaryKey: "BundledMoleVersion") as? String,
           let version = bundled.split(separator: " ").first, !version.isEmpty {
            return normalize(String(version))
        }
        guard let data = try? await MoleCLI.run(["--version"]) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.firstMatch(of: #/Mole version (\S+)/#).map { normalize(String($0.1)) }
    }

    /// "V1.62.0" → "1.62.0".
    static func normalize(_ version: String) -> String {
        version.trimmingCharacters(in: CharacterSet(charactersIn: "vV ").union(.whitespaces))
    }

    /// Numeric comparison, part by part: 1.62.10 is newer than 1.62.9.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let b = current.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
