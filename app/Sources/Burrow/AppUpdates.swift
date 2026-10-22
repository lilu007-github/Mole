import Foundation

/// An app with a newer version, from Homebrew or the app's own Sparkle feed.
struct AppUpdate: Identifiable, Hashable {
    enum Source: String { case homebrew = "Homebrew", sparkle = "App 自带更新" }

    var name: String
    var source: Source
    var installed: String
    var latest: String
    /// The cask token for Homebrew, the app path for Sparkle.
    var reference: String
    var id: String { source.rawValue + reference }
}

enum AppUpdates {
    static var brew: URL? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // MARK: Homebrew

    /// `brew outdated --cask --greedy --json=v2`: casks with a newer version,
    /// including ones that update themselves (greedy).
    static func homebrew() async throws -> [AppUpdate] {
        guard let brew else { return [] }
        let data = try await Task.detached {
            let process = Process()
            process.executableURL = brew
            process.arguments = ["outdated", "--cask", "--greedy", "--json=v2"]
            var env = MoleCLI.environment
            env["HOMEBREW_NO_AUTO_UPDATE"] = "1" // a check must not update brew itself
            process.environment = env
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return data
        }.value
        return parseBrew(data)
    }

    static func parseBrew(_ data: Data) -> [AppUpdate] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = json["casks"] as? [[String: Any]] else { return [] }
        return casks.compactMap { cask in
            guard let token = cask["name"] as? String else { return nil }
            let installed = (cask["installed_versions"] as? [String])?.first ?? "?"
            let latest = cask["current_version"] as? String ?? "?"
            return AppUpdate(name: token, source: .homebrew, installed: tidy(installed), latest: tidy(latest), reference: token)
        }
    }

    /// "2.0.5,19905" → "2.0.5": casks append a build number after a comma.
    static func tidy(_ version: String) -> String {
        String(version.split(separator: ",").first ?? Substring(version))
    }

    // MARK: Sparkle

    /// Apps in /Applications and ~/Applications whose Info.plist names an https
    /// Sparkle feed, compared with the newest item in that feed.
    static func sparkle() async -> [AppUpdate] {
        let folders = ["/Applications", NSHomeDirectory() + "/Applications"]
        var candidates: [(name: String, path: String, feed: URL, short: String, build: String)] = []
        for folder in folders {
            let apps = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for app in apps where app.hasSuffix(".app") {
                let path = folder + "/" + app
                guard let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist") as? [String: Any],
                      let feedText = info["SUFeedURL"] as? String, let feed = URL(string: feedText),
                      feed.scheme == "https" else { continue }
                candidates.append(((app as NSString).deletingPathExtension, path, feed,
                                   info["CFBundleShortVersionString"] as? String ?? "",
                                   info["CFBundleVersion"] as? String ?? ""))
            }
        }
        return await withTaskGroup(of: AppUpdate?.self) { group in
            for app in candidates {
                group.addTask {
                    guard let latest = await latestInFeed(app.feed) else { return nil }
                    // Feeds compare by build (sparkle:version) when both sides have one.
                    let newer = !latest.build.isEmpty && !app.build.isEmpty
                        ? UpdateChecker.isNewer(latest.build, than: app.build)
                        : UpdateChecker.isNewer(latest.short, than: app.short)
                    guard newer else { return nil }
                    return AppUpdate(name: app.name, source: .sparkle, installed: app.short.isEmpty ? app.build : app.short,
                                     latest: latest.short.isEmpty ? latest.build : latest.short, reference: app.path)
                }
            }
            var found: [AppUpdate] = []
            for await update in group { if let update { found.append(update) } }
            return found.sorted { $0.name < $1.name }
        }
    }

    static func latestInFeed(_ feed: URL) async -> (short: String, build: String)? {
        var request = URLRequest(url: feed)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return AppcastParser.newest(in: data)
    }
}

/// Reads <item>s of a Sparkle appcast; the version is either an attribute on
/// <enclosure> or a <sparkle:version> / <sparkle:shortVersionString> element.
final class AppcastParser: NSObject, XMLParserDelegate {
    private var items: [(short: String, build: String)] = []
    private var current: (short: String, build: String)?
    private var element = ""
    private var text = ""

    static func newest(in data: Data) -> (short: String, build: String)? {
        let delegate = AppcastParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() else { return nil }
        return delegate.items.max { a, b in
            !a.build.isEmpty && !b.build.isEmpty
                ? UpdateChecker.isNewer(b.build, than: a.build)
                : UpdateChecker.isNewer(b.short, than: a.short)
        }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        element = name
        text = ""
        if name == "item" { current = ("", "") }
        if name == "enclosure", current != nil {
            if let build = attributes["sparkle:version"] { current?.build = build }
            if let short = attributes["sparkle:shortVersionString"] { current?.short = short }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "sparkle:version", !value.isEmpty { current?.build = value }
        if name == "sparkle:shortVersionString", !value.isEmpty { current?.short = value }
        if name == "item", let item = current {
            if !item.build.isEmpty || !item.short.isEmpty { items.append(item) }
            current = nil
        }
        text = ""
    }
}
