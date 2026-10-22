import SwiftUI

/// Squarified treemap layout (Bruls, Huizing, van Wijk): rows of rectangles
/// whose aspect ratios stay close to 1, so small items remain readable.
enum Treemap {
    /// Rectangles for `values` (any order) inside `rect`, returned in input order.
    static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return values.map { _ in .zero } }
        let scale = Double(rect.width * rect.height) / total
        let order = values.indices.sorted { values[$0] > values[$1] }
        var result = [CGRect](repeating: .zero, count: values.count)
        var remaining = rect
        var row: [Int] = []

        func worst(_ row: [Int], side: Double) -> Double {
            let areas = row.map { values[$0] * scale }
            let sum = areas.reduce(0, +)
            guard let maxA = areas.max(), let minA = areas.min(), sum > 0, minA > 0 else { return .infinity }
            return max(side * side * maxA / (sum * sum), (sum * sum) / (side * side * minA))
        }

        func place(_ row: [Int]) {
            let areas = row.map { values[$0] * scale }
            let sum = areas.reduce(0, +)
            if remaining.width >= remaining.height {
                let width = CGFloat(sum) / remaining.height
                var y = remaining.minY
                for (i, index) in row.enumerated() {
                    let height = CGFloat(areas[i]) / width
                    result[index] = CGRect(x: remaining.minX, y: y, width: width, height: height)
                    y += height
                }
                remaining = CGRect(x: remaining.minX + width, y: remaining.minY,
                                   width: max(remaining.width - width, 0), height: remaining.height)
            } else {
                let height = CGFloat(sum) / remaining.width
                var x = remaining.minX
                for (i, index) in row.enumerated() {
                    let width = CGFloat(areas[i]) / height
                    result[index] = CGRect(x: x, y: remaining.minY, width: width, height: height)
                    x += width
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + height,
                                   width: remaining.width, height: max(remaining.height - height, 0))
            }
        }

        for index in order where values[index] > 0 {
            let side = Double(min(remaining.width, remaining.height))
            if row.isEmpty || worst(row + [index], side: side) <= worst(row, side: side) {
                row.append(index)
            } else {
                place(row)
                row = [index]
            }
        }
        if !row.isEmpty { place(row) }
        return result
    }
}

/// Analyze entries as a treemap; folders open on click.
struct TreemapView: View {
    let entries: [AnalyzeResult.Entry]
    let open: (AnalyzeResult.Entry) -> Void
    @State private var hovered: String?

    private static let palette: [Color] = [.blue, .teal, .indigo, .purple, .cyan, .mint, .green, .orange]

    var body: some View {
        GeometryReader { geo in
            let shown = Array(entries.filter { $0.size > 0 }.prefix(60))
            let rects = Treemap.layout(shown.map { Double($0.size) }, in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                    let rect = rects[index].insetBy(dx: 1, dy: 1)
                    let color = Self.palette[index % Self.palette.count]
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color.opacity(hovered == entry.id ? 0.55 : 0.35))
                        .overlay(alignment: .topLeading) {
                            if rect.width > 70 && rect.height > 34 {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.name).font(.caption.bold()).lineLimit(1)
                                    Text(Format.bytes(entry.size)).font(.caption2).foregroundStyle(.secondary)
                                }
                                .padding(5)
                            }
                        }
                        .frame(width: max(rect.width, 0), height: max(rect.height, 0))
                        .offset(x: rect.minX, y: rect.minY)
                        .onHover { hovered = $0 ? entry.id : (hovered == entry.id ? nil : hovered) }
                        .onTapGesture { if entry.isDir { open(entry) } }
                        .help("\(entry.name) · \(Format.bytes(entry.size))" + (entry.isDir ? "，点击进入" : ""))
                }
            }
        }
        .padding(8)
    }
}
