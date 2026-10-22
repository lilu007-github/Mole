// Draws Burrow's app icon and writes an .iconset folder for iconutil.
// Usage: swift app/scripts/make-icon.swift <output.iconset>
//
// A dusk sky, an earthen hill with a burrow entrance, and a sparkle for
// "clean". Plain vector shapes, so it stays legible down to 16 px.

import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func linear(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(gradient, start: from, end: to, options: [])
}

/// Draws on a 1024-unit canvas scaled to `pixels`. Origin is bottom-left.
func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    // macOS icon grid: an 824-unit rounded square centred on the canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Soft drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x1E2440))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    // Sky.
    linear(ctx, [color(0x4A5A92), color(0x232A4D)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 380))

    // Sparkle: a four-point star with a faint halo.
    let star = CGPoint(x: 700, y: 735)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 40, color: color(0xFFF4D6, 0.9))
    let starPath = CGMutablePath()
    let long: CGFloat = 110, short: CGFloat = 26
    starPath.move(to: CGPoint(x: star.x, y: star.y + long))
    starPath.addQuadCurve(to: CGPoint(x: star.x + long, y: star.y), control: CGPoint(x: star.x + short, y: star.y + short))
    starPath.addQuadCurve(to: CGPoint(x: star.x, y: star.y - long), control: CGPoint(x: star.x + short, y: star.y - short))
    starPath.addQuadCurve(to: CGPoint(x: star.x - long, y: star.y), control: CGPoint(x: star.x - short, y: star.y - short))
    starPath.addQuadCurve(to: CGPoint(x: star.x, y: star.y + long), control: CGPoint(x: star.x - short, y: star.y + short))
    ctx.addPath(starPath)
    ctx.setFillColor(color(0xFFF7E3))
    ctx.fillPath()
    ctx.restoreGState()
    // A smaller companion sparkle.
    ctx.setFillColor(color(0xFFF7E3, 0.85))
    ctx.fillEllipse(in: CGRect(x: 545, y: 805, width: 26, height: 26))

    // Hill.
    let hill = CGMutablePath()
    hill.move(to: CGPoint(x: 60, y: 60))
    hill.addLine(to: CGPoint(x: 60, y: 430))
    hill.addCurve(to: CGPoint(x: 964, y: 470),
                  control1: CGPoint(x: 300, y: 640), control2: CGPoint(x: 700, y: 640))
    hill.addLine(to: CGPoint(x: 964, y: 60))
    hill.closeSubpath()
    ctx.saveGState()
    ctx.addPath(hill)
    ctx.clip()
    linear(ctx, [color(0xD9995A), color(0x9C6233), color(0x6E4022)],
           from: CGPoint(x: 512, y: 600), to: CGPoint(x: 512, y: 100))
    ctx.restoreGState()

    // Sunlit rim along the hilltop.
    let rim = CGMutablePath()
    rim.move(to: CGPoint(x: 60, y: 430))
    rim.addCurve(to: CGPoint(x: 964, y: 470), control1: CGPoint(x: 300, y: 640), control2: CGPoint(x: 700, y: 640))
    ctx.addPath(rim)
    ctx.setStrokeColor(color(0xF2C27F, 0.9))
    ctx.setLineWidth(14)
    ctx.strokePath()

    // Burrow entrance: an arch with a darker inner shade for depth.
    func arch(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.35))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.35),
                      control1: CGPoint(x: rect.minX, y: rect.maxY + rect.height * 0.25),
                      control2: CGPoint(x: rect.maxX, y: rect.maxY + rect.height * 0.25))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
    ctx.addPath(arch(CGRect(x: 342, y: 230, width: 340, height: 230)))
    ctx.setFillColor(color(0x5A3519))
    ctx.fillPath()
    ctx.addPath(arch(CGRect(x: 372, y: 230, width: 280, height: 196)))
    ctx.setFillColor(color(0x24140A))
    ctx.fillPath()
    // Low mound of dug-out earth in front of the entrance, fading into the ground.
    let mound = CGMutablePath()
    mound.move(to: CGPoint(x: 250, y: 120))
    mound.addCurve(to: CGPoint(x: 774, y: 120),
                   control1: CGPoint(x: 360, y: 300), control2: CGPoint(x: 664, y: 300))
    mound.closeSubpath()
    ctx.saveGState()
    ctx.addPath(mound)
    ctx.clip()
    linear(ctx, [color(0xC4884E), color(0x8A5630)], from: CGPoint(x: 512, y: 255), to: CGPoint(x: 512, y: 120))
    ctx.restoreGState()

    ctx.restoreGState()

    // Hairline edge so the tile reads on light and dark backgrounds.
    ctx.addPath(shape)
    ctx.setStrokeColor(color(0xFFFFFF, 0.12))
    ctx.setLineWidth(3)
    ctx.strokePath()
    return rep
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Burrow.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let png = drawIcon(pixels: points * scale).representation(using: .png, properties: [:])!
        try png.write(to: output.appendingPathComponent(name))
    }
}
