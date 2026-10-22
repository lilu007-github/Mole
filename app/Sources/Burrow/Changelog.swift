import Foundation
import SwiftUI

/// Burrow's own release notes, from app/CHANGELOG.md bundled into Resources.
enum Changelog {
    struct Release: Identifiable, Equatable {
        var version: String
        var date: String
        var items: [String]
        var id: String { version }
    }

    /// `## 0.3.0 — 2026-10-22` starts a release; `- text` lines are its items.
    static func parse(_ text: String) -> [Release] {
        var releases: [Release] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                let parts = line.dropFirst(3).split(separator: "—", maxSplits: 1)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                releases.append(Release(version: parts.first ?? "", date: parts.count > 1 ? parts[1] : "", items: []))
            } else if line.hasPrefix("- "), !releases.isEmpty {
                releases[releases.count - 1].items.append(String(line.dropFirst(2)))
            }
        }
        return releases.filter { !$0.version.isEmpty }
    }

    static func load() -> [Release] {
        let bundled = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md")
        // `swift run` has no bundle resources; read the file next to the sources.
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CHANGELOG.md")
        for url in [bundled, source].compactMap({ $0 }) {
            if let text = try? String(contentsOf: url, encoding: .utf8) { return parse(text) }
        }
        return []
    }
}

struct ChangelogView: View {
    private let releases = Changelog.load()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if releases.isEmpty {
                    Text("没有找到更新说明。").foregroundStyle(.secondary)
                }
                ForEach(releases) { release in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(release.version).font(.title3.bold())
                            Text(release.date).foregroundStyle(.secondary)
                            if release.version == Doctor.shortVersion {
                                Text("当前版本").font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.tint.opacity(0.15), in: Capsule())
                            }
                        }
                        ForEach(release.items, id: \.self) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("•").foregroundStyle(.secondary)
                                Text(item).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 520, height: 520)
    }
}
