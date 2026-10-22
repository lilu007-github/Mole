import Foundation

@MainActor
enum TreemapChecks {
    static func register() {
        Checks.add("treemap", "areas are proportional, rectangles tile the canvas without overlap") {
            let values: [Double] = [6, 6, 4, 3, 2, 2, 1]
            let canvas = CGRect(x: 0, y: 0, width: 600, height: 400)
            let rects = Treemap.layout(values, in: canvas)
            let total = values.reduce(0, +)
            for (value, rect) in zip(values, rects) {
                let expected = Double(canvas.width * canvas.height) * value / total
                expect(abs(Double(rect.width * rect.height) - expected) < 1, "area \(value): \(rect)")
                expect(canvas.insetBy(dx: -0.5, dy: -0.5).contains(rect), "inside: \(rect)")
            }
            for i in rects.indices {
                for j in rects.indices where j > i {
                    let overlap = rects[i].insetBy(dx: 0.5, dy: 0.5).intersection(rects[j].insetBy(dx: 0.5, dy: 0.5))
                    expect(overlap.isNull || overlap.width * overlap.height < 1, "\(i) overlaps \(j)")
                }
            }
            let worstAspect = rects.map { max($0.width / $0.height, $0.height / $0.width) }.max() ?? 0
            expect(worstAspect < 4, "squarified: worst aspect \(worstAspect)")
        }

        Checks.add("treemap", "zero sizes and empty canvases are harmless") {
            expect(Treemap.layout([0, 0], in: CGRect(x: 0, y: 0, width: 10, height: 10)) == [.zero, .zero], "all zero")
            expect(Treemap.layout([3, 0, 1], in: CGRect(x: 0, y: 0, width: 10, height: 10))[1] == .zero, "zero entry")
            expect(Treemap.layout([1], in: .zero) == [.zero], "no space")
        }
    }
}
