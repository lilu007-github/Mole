import Foundation

/// A build artifact `mo purge --dry-run` would remove: "✓ [DRY RUN] /path/node_modules, 558.3MB".
struct PurgeArtifact: Identifiable, Hashable {
    var path: String
    var size: String
    /// The project folder: the first folder below the scan path that contains it.
    var project: String
    var id: String { path }

    var name: String { (path as NSString).lastPathComponent }

    /// Rows of a dry run, in Mole's order. Recently modified artifacts are not
    /// among them: Mole leaves those out unless picked by hand in its menu.
    static func parse(_ lines: [String], scanPaths: [String]) -> [PurgeArtifact] {
        let marker = "[DRY RUN] "
        return lines.compactMap { line in
            guard let start = line.range(of: marker) else { return nil }
            let rest = line[start.upperBound...]
            guard let comma = rest.range(of: ", ", options: .backwards) else { return nil }
            let path = String(rest[..<comma.lowerBound])
            guard path.hasPrefix("/") else { return nil }
            return PurgeArtifact(path: path, size: String(rest[comma.upperBound...]).trimmingCharacters(in: .whitespaces),
                                 project: project(of: path, scanPaths: scanPaths))
        }
    }

    static func project(of path: String, scanPaths: [String]) -> String {
        let roots = scanPaths.map { PurgePaths.expand($0) }.sorted { $0.count > $1.count }
        for root in roots where path.hasPrefix(root + "/") {
            let first = path.dropFirst(root.count + 1).split(separator: "/").first.map(String.init) ?? ""
            return root + "/" + first
        }
        return (path as NSString).deletingLastPathComponent
    }
}

/// ~/.config/mole/purge_paths: the folders `mo purge` scans, one per line.
/// Mole documents this file as user-editable; Burrow keeps its comment header.
enum PurgePaths {
    nonisolated(unsafe) static var fileURL = URL(fileURLWithPath: NSHomeDirectory() + "/.config/mole/purge_paths")

    static let header = """
    # Mole Purge Paths - Auto-discovered project directories
    # Edit this file to customize, or run: mo purge --paths
    # Add one path per line (supports ~ for home directory)

    """

    /// nil when the file does not exist and Mole falls back to its defaults.
    static func load() -> [String]? {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func save(_ paths: [String]) throws {
        let comments = (try? String(contentsOf: fileURL, encoding: .utf8))?
            .split(whereSeparator: \.isNewline)
            .prefix { $0.hasPrefix("#") || $0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n")
        let head = comments.map { $0.isEmpty ? header : $0 + "\n\n" } ?? header
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try (head + paths.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// "~/Projects" → "/Users/me/Projects", the form Mole prints.
    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// "/Users/me/Projects" → "~/Projects", for the config file and display.
    static func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

/// Drives the real `mo purge` selection menu so it holds exactly the chosen
/// artifacts, then lets Mole print its own list of selected paths and checks it.
enum PurgeMenuDriver {
    /// The menu needs room to print full paths on its "Path:" line.
    static let columns = 220

    @MainActor
    static func select(_ chosen: Set<String>, in session: TerminalSession,
                       progress: @escaping (String) -> Void) async -> String? {
        func quit(_ problem: String) -> String {
            session.send("q")
            return problem
        }

        // Wait for the first complete frame.
        guard await wait(in: session, seconds: 300, until: { frame($0) != nil }) else {
            return session.allLines.contains { $0.contains("No artifacts found") }
                ? "Mole 没有找到可清理的构建产物。" : quit("没有等到 Mole 的选择菜单。")
        }

        // Clear Mole's default selection: select all, then invert.
        session.send("A")
        guard await wait(in: session, until: { frame($0).map { $0.selected == $0.total } ?? false }) else {
            return quit("无法全选。")
        }
        session.send("I")
        guard await wait(in: session, until: { frame($0)?.selected == 0 }) else { return quit("无法清空选择。") }
        session.send("\u{1b}[H") // Home: first item
        guard await wait(in: session, until: { frame($0)?.cursor == 1 }) else { return quit("无法回到第一项。") }

        // Walk every item; press Space where the full path is one the user chose.
        let total = frame(session.allLines)?.total ?? 0
        var found = Set<String>()
        for index in 1...max(total, 1) {
            guard let current = frame(session.allLines), current.cursor == index else {
                return quit("菜单位置和预期不一致，已取消。")
            }
            progress("正在 Mole 菜单中选择 \(index)/\(total)")
            if let path = current.path, chosen.contains(path) {
                let before = current.selected
                session.send(" ")
                guard await wait(in: session, until: { frame($0)?.selected == before + 1 }) else {
                    return quit("选择 \(path) 失败。")
                }
                found.insert(path)
            }
            if index < total {
                session.send("\u{1b}[B")
                guard await wait(in: session, until: { frame($0)?.cursor == index + 1 }) else {
                    return quit("菜单没有响应，已取消。")
                }
            }
        }
        guard found == chosen else {
            let missing = chosen.subtracting(found).map { PurgePaths.abbreviate($0) }.sorted()
            return quit("Mole 的菜单里找不到：\(missing.joined(separator: "、"))。列表可能已经变化，请重新扫描。")
        }

        // Enter shows Mole's own list of selected paths before its confirmation.
        session.send("\r")
        guard await wait(in: session, seconds: 60, until: { lines in
            lines.last.map { $0.contains(PromptBar.confirmMarker) } ?? false
        }) else { return "Mole 没有显示确认提示。" }
        let listed = selectedPaths(session.allLines)
        guard listed == chosen else {
            session.send("\u{1b}")
            return "Mole 列出的路径和你的选择不一致，已取消，没有删除任何文件。"
        }
        return nil
    }

    struct Frame {
        var cursor: Int
        var total: Int
        var selected: Int
        var path: String?
    }

    /// Reads one fully drawn menu frame. The header carries "[i/N]" only when the
    /// list spans several pages; on a single page the "➤" row is the cursor.
    /// The key legend is drawn last, so a frame without it is still being drawn.
    static func frame(_ lines: [String]) -> Frame? {
        guard lines.contains(where: { $0.contains("Space Select") }),
              let header = lines.first(where: { $0.contains("Select Artifacts to Purge") }),
              let count = lines.lazy.compactMap({ $0.firstMatch(of: #/, (\d+) selected\s*$/#) }).first,
              let selected = Int(count.1)
        else { return nil }
        let path = lines.last { $0.hasPrefix("Path: ") }.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        if let position = header.firstMatch(of: #/\[(\d+)/(\d+)\]/#), let cursor = Int(position.1), let total = Int(position.2) {
            return Frame(cursor: cursor, total: total, selected: selected, path: path)
        }
        let rows = lines.filter { $0.firstMatch(of: #/^(➤| ) [○●] /#) != nil }
        guard let cursor = rows.firstIndex(where: { $0.hasPrefix("➤") }) else { return nil }
        return Frame(cursor: cursor + 1, total: rows.count, selected: selected, path: path)
    }

    /// The indented lines after "Selected paths:" in Mole's confirmation.
    static func selectedPaths(_ lines: [String]) -> Set<String> {
        guard let start = lines.lastIndex(where: { $0.hasPrefix("Selected paths:") }) else { return [] }
        var paths = Set<String>()
        for line in lines[(start + 1)...] {
            guard line.hasPrefix("  "), !line.contains(PromptBar.confirmMarker) else { break }
            paths.insert(PurgePaths.expand(line.trimmingCharacters(in: .whitespaces)))
        }
        return paths
    }

    @MainActor
    private static func wait(in session: TerminalSession, seconds: Double = 10,
                             until condition: ([String]) -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition(session.allLines) { return true }
            if !session.isRunning, session.exitCode != nil { return condition(session.allLines) }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return false
    }
}
