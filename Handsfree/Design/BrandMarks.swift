//
//  BrandMarks.swift
//  Handsfree
//
//  The Handsfree marks, drawn in code so they stay sharp at every size: the
//  menu bar icon (a pointer arrow with two sound waves beside it: the pointer,
//  run by voice). Clicky drew its own triangle icon the same way in
//  MenuBarPanelManager.makeClickyMenuBarIcon; the shape here is ours.
//

import AppKit

enum BrandMarks {
    /// An 18 by 18 point template image for the menu bar. macOS tints it to suit the menu bar.
    static func menuBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()

            // The pointer arrow, tip at the top left.
            let arrow = NSBezierPath()
            let origin = CGPoint(x: 2.5, y: 1.5)
            let points: [CGPoint] = [
                CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 12.6), CGPoint(x: 3.1, y: 9.9), CGPoint(x: 5.2, y: 14.6),
                CGPoint(x: 7.0, y: 13.8), CGPoint(x: 5.0, y: 9.2), CGPoint(x: 9.2, y: 9.2),
            ]
            arrow.move(to: CGPoint(x: origin.x + points[0].x, y: origin.y + points[0].y))
            for point in points.dropFirst() { arrow.line(to: CGPoint(x: origin.x + point.x, y: origin.y + point.y)) }
            arrow.close()
            arrow.lineJoinStyle = .round
            arrow.fill()

            // Two sound waves to the right of the arrow.
            for (index, radius) in [CGFloat(3.4), 6.2].enumerated() {
                let wave = NSBezierPath()
                wave.appendArc(withCenter: CGPoint(x: 10.0, y: 12.6), radius: radius, startAngle: -50, endAngle: 50)
                wave.lineWidth = index == 0 ? 1.7 : 1.5
                wave.lineCapStyle = .round
                wave.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
