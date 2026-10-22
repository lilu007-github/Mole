import SwiftUI

/// Groups `mo clean` / `mo optimize` output into its "➤ Section" blocks and the closing summary.
struct SectionReport {
    /// Rows of every section share one List, so ids are unique across sections
    /// ("section-row"); per-section offsets made all sections show one row's text.
    struct Item: Identifiable {
        var id = ""
        var icon: String
        var text: String

        var color: Color {
            switch icon {
            case "✓": .green
            case "◎", "☻": .orange
            case "⊙": .blue
            default: .secondary
            }
        }
    }

    struct Section: Identifiable {
        var id: Int
        var title: String
        var items: [Item] = []
    }

    var sections: [Section] = []
    var summary: [String] = []

    /// Summary lines with ids that cannot collide with section rows.
    var summaryRows: [(id: String, text: String)] {
        summary.enumerated().map { ("summary-\($0.offset)", $0.element) }
    }

    init(lines: [String]) {
        var inSummary = false
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("====") {
                inSummary.toggle()
                continue
            }
            if inSummary {
                if !line.isEmpty { summary.append(line) }
            } else if line.hasPrefix("➤ ") {
                sections.append(Section(id: sections.count, title: String(line.dropFirst(2))))
            } else if !line.isEmpty, raw.hasPrefix("  "), !sections.isEmpty {
                let icon = String(line.prefix(1))
                let text = line.dropFirst().trimmingCharacters(in: .whitespaces)
                let index = sections.count - 1
                let id = "\(index)-\(sections[index].items.count)"
                sections[index].items.append(Item(id: id, icon: icon, text: text))
            }
        }
    }

    /// "Potential space: 11.09GB+ | Items: …" from the dry-run summary.
    var potentialSpace: String? {
        for line in summary {
            for prefix in ["Potential space:", "Space freed:"] where line.hasPrefix(prefix) {
                return line.dropFirst(prefix.count).split(separator: "|").first?
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

struct RawOutputView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: lines.count) { _, count in
                if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
    }
}
