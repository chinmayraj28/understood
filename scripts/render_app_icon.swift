// Renders the Handsfree app icon at every size macOS needs, into
// Handsfree/Assets.xcassets/AppIcon.appiconset. Run: swift scripts/render_app_icon.swift
// The design: a dark iris tile; a white pointer arrow; an iris dot with two
// sound waves beside it ("the pointer, run by voice"). Same idea as the menu bar icon.
import AppKit
import CoreGraphics

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func renderIcon(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: size / 1024, y: size / 1024)
    // Work in a top-left coordinate space.
    context.translateBy(x: 0, y: 1024)
    context.scaleBy(x: 1, y: -1)

    // macOS icon grid: an 824-point tile centred on the 1024 canvas, with a soft drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    context.addPath(tilePath)
    context.setFillColor(color(0x17112E))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [color(0x3A2A7A), color(0x1A1336), color(0x0E0B1C)] as CFArray, locations: [0, 0.55, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 200, y: 100), end: CGPoint(x: 820, y: 924), options: [])
    // A soft iris glow behind the voice dot.
    let glow = CGGradient(colorsSpace: space, colors: [color(0x8B66FF, 0.55), color(0x8B66FF, 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 640, y: 650), startRadius: 0, endCenter: CGPoint(x: 640, y: 650), endRadius: 300, options: [])
    context.restoreGState()

    // The pointer arrow, tip at (300, 240).
    let arrowPoints: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 452), CGPoint(x: 111, y: 356), CGPoint(x: 187, y: 525),
        CGPoint(x: 252, y: 497), CGPoint(x: 180, y: 331), CGPoint(x: 330, y: 331),
    ].map { CGPoint(x: $0.x + 300, y: $0.y + 240) }
    let arrow = CGMutablePath()
    arrow.addLines(between: arrowPoints)
    arrow.closeSubpath()
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.45))
    context.addPath(arrow)
    context.setFillColor(color(0xFFFFFF))
    context.fillPath()
    context.restoreGState()
    context.addPath(arrow)
    context.setStrokeColor(color(0x0E0B1C))
    context.setLineWidth(14)
    context.setLineJoin(.round)
    context.strokePath()

    // The voice: an iris dot with a white edge, and two waves.
    let dotCenter = CGPoint(x: 640, y: 650)
    context.setFillColor(color(0x8B66FF))
    context.addEllipse(in: CGRect(x: dotCenter.x - 58, y: dotCenter.y - 58, width: 116, height: 116))
    context.fillPath()
    context.setStrokeColor(color(0xFFFFFF))
    context.setLineWidth(14)
    context.addEllipse(in: CGRect(x: dotCenter.x - 58, y: dotCenter.y - 58, width: 116, height: 116))
    context.strokePath()
    context.setLineCap(.round)
    for (radius, alpha) in [(CGFloat(118), CGFloat(0.95)), (CGFloat(178), CGFloat(0.6))] {
        context.setStrokeColor(color(0xC7B6FF, alpha))
        context.setLineWidth(26)
        context.addArc(center: dotCenter, radius: radius, startAngle: -.pi / 4, endAngle: .pi / 4, clockwise: false)
        context.strokePath()
    }

    let image = context.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Handsfree/Assets.xcassets/AppIcon.appiconset")
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try! renderIcon(pixels: points * scale).write(to: folder.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icon images to \(folder.path)")
