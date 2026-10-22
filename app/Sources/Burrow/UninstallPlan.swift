import Foundation

/// The personal-data part of the plan `mo uninstall` prints before it asks for
/// confirmation. Mole reprints the whole plan after every change, so the
/// latest "Files to be removed:" block is the current one.
struct UninstallPlan: Equatable {
    /// Display paths ("~/Library/…" or absolute), in Mole's order.
    var personalRemoved: [String] = []
    var personalKept: [String] = []

    var allPersonal: [String] { personalRemoved + personalKept }

    static func parse(_ lines: [String]) -> UninstallPlan? {
        guard let start = lines.lastIndex(where: { $0.hasPrefix("Files to be removed:") }) else { return nil }
        var plan = UninstallPlan()
        var section: WritableKeyPath<UninstallPlan, [String]>?
        for line in lines[start...] {
            if line.hasPrefix("Personal data to remove:") { section = \.personalRemoved; continue }
            if line.hasPrefix("Personal data kept:") { section = \.personalKept; continue }
            guard let current = section else { continue }
            guard line.hasPrefix("  ") else {
                if !line.isEmpty { section = nil }
                continue
            }
            plan[keyPath: current].append(displayPath(line))
        }
        return plan
    }

    /// "  ✓ /var/folders/…/md.obsidian , 348KB" → "/var/folders/…/md.obsidian".
    /// Only a trailing size is cut; kept rows carry none, and a path may contain " , ".
    static func displayPath(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        if let first = text.unicodeScalars.first, !"~/".unicodeScalars.contains(first) {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if let size = text.firstMatch(of: #/ , [\d.]+(B|KB|MB|GB|TB)\+?$/#) {
            text = String(text[..<size.range.lowerBound])
        }
        return text
    }
}

/// Drives Mole's "Personal data to remove" menu (the D key) so that exactly
/// `wanted` is selected, then checks the plan Mole reprints.
enum PersonalDataDriver {
    /// - Parameters:
    ///   - order: every personal path in Mole's menu order (the "kept" list of a
    ///     plan where nothing was selected yet).
    ///   - current: what the current plan already removes.
    @MainActor
    static func apply(wanted: Set<String>, order: [String], current: Set<String>,
                      in session: TerminalSession) async -> String? {
        guard wanted.isSubset(of: Set(order)), current.isSubset(of: Set(order)) else {
            return "个人数据列表和计划不一致。"
        }
        // Every redraw of the menu writes its header again; a new header is the
        // menu's answer to the last key.
        var seen = headers(session).count
        session.send("d")
        guard let opened = await nextHeader(in: session, after: seen, seconds: 10, where: { _ in true }),
              opened.total == order.count, opened.selected == current.count else {
            session.send("q")
            return "没有打开 Mole 的个人数据菜单，或菜单内容和计划不一致。"
        }

        var selected = opened.selected
        for (index, path) in order.enumerated() {
            if wanted.contains(path) != current.contains(path) {
                let expected = wanted.contains(path) ? selected + 1 : selected - 1
                seen = headers(session).count
                session.send(" ")
                guard await nextHeader(in: session, after: seen, seconds: 5, where: { $0.selected == expected }) != nil else {
                    session.send("q")
                    return "在 Mole 菜单中选择失败，已取消。"
                }
                selected = expected
            }
            if index < order.count - 1 {
                session.send("\u{1b}[B")
                try? await Task.sleep(for: .milliseconds(120))
            }
        }

        // Enter saves the choice; Mole reprints the plan and asks again.
        let before = session.lineSerial
        session.send("\r")
        let end = Date().addingTimeInterval(30)
        while Date() < end {
            if session.lineSerial > before, session.currentLine.contains(PromptBar.confirmMarker) { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let plan = UninstallPlan.parse(session.allLines), session.currentLine.contains(PromptBar.confirmMarker) else {
            return "Mole 没有重新显示卸载计划。"
        }
        guard Set(plan.personalRemoved) == wanted else {
            session.send("\u{1b}")
            return "Mole 计划里的个人数据和你的选择不一致，已取消卸载，没有删除任何文件。"
        }
        return nil
    }

    /// Every "Personal data to remove  k/N selected" header written so far.
    @MainActor
    private static func headers(_ session: TerminalSession) -> [(selected: Int, total: Int)] {
        (session.transcript + [session.currentLine]).compactMap { line in
            line.firstMatch(of: #/Personal data to remove\s+(\d+)/(\d+) selected/#)
                .flatMap { m in Int(m.1).flatMap { k in Int(m.2).map { (k, $0) } } }
        }
    }

    /// Waits for a header newer than the first `count` that satisfies `condition`.
    @MainActor
    private static func nextHeader(in session: TerminalSession, after count: Int, seconds: Double,
                                   where condition: ((selected: Int, total: Int)) -> Bool) async -> (selected: Int, total: Int)? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            let all = headers(session)
            if all.count > count, let latest = all.last, condition(latest) { return latest }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return nil
    }
}
