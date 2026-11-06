//
//  OverlayGeometry.swift
//  Handsfree
//
//  Coordinate conversions and the placement of the companion beside the
//  pointer. Pure functions, unit tested.
//
//  Adapted from Clicky (github.com/farzaa/clicky, MIT): the AppKit-to-overlay
//  conversion is BlueCursorView.convertScreenPointToSwiftUICoordinates in
//  OverlayWindow.swift, and the flip-at-the-screen-edge rule is
//  CompanionResponseOverlayManager.repositionPanelNearCursor in
//  CompanionResponseOverlay.swift.
//
//  Three coordinate systems meet here:
//  - HFCore (what the hands and the screen agent post): screen points, origin at
//    the TOP LEFT of the main display, y grows downward.
//  - AppKit (NSEvent.mouseLocation, NSScreen.frame): origin at the BOTTOM LEFT
//    of the main display, y grows upward.
//  - One overlay window's SwiftUI canvas: origin at the top left of that screen.
//

import CoreGraphics

enum OverlayGeometry {

    /// HFCore point to AppKit point. `mainDisplayHeight` is the height of the
    /// display whose origin is (0, 0), i.e. `NSScreen.screens[0].frame.height`.
    static func appKitPoint(fromTopLeft point: CGPoint, mainDisplayHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: mainDisplayHeight - point.y)
    }

    /// AppKit point to HFCore point. The same flip, the other way.
    static func topLeftPoint(fromAppKit point: CGPoint, mainDisplayHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: mainDisplayHeight - point.y)
    }

    /// AppKit point to a point on the canvas of the overlay covering `screenFrame`.
    static func canvasPoint(fromAppKit point: CGPoint, screenFrame: CGRect) -> CGPoint {
        CGPoint(x: point.x - screenFrame.minX, y: screenFrame.maxY - point.y)
    }

    /// Where the companion's two parts go: the round glyph beside the pointer's
    /// tip, and the stack of caption and card next to the glyph.
    struct CompanionPlacement: Equatable {
        var glyphCenter: CGPoint
        var stackCenter: CGPoint
        /// The stack sits to the left of the pointer because there is no room on the right.
        var opensToLeft: Bool
        /// The stack sits above the pointer because there is no room below.
        var opensUpward: Bool
    }

    /// Radius of the glyph when it is expanded, in points.
    static let glyphRadius: CGFloat = 17
    /// Space between the glyph and the caption stack.
    static let glyphToStackGap: CGFloat = 10
    /// Nothing is drawn closer than this to a screen edge.
    static let edgeMargin: CGFloat = 10

    /// Places the companion so it never covers the pointer's tip (the hotspot, which
    /// is what the user and the agent are aiming with) and never runs off the screen.
    ///
    /// By default the glyph sits below and to the right of the tip, like a
    /// shadow of the arrow, and the stack opens to its right. Near the right edge
    /// everything mirrors to the left; near the bottom edge it moves above the tip.
    ///
    /// - Parameters:
    ///   - pointer: the pointer's tip on this canvas.
    ///   - canvasSize: the size of the screen in points.
    ///   - cursorScale: the user's pointer size setting (1 is normal). Users with
    ///     low vision often enlarge the pointer, and the companion must clear it.
    ///   - stackSize: the measured size of the caption stack (zero when empty).
    static func companionPlacement(
        pointer: CGPoint, canvasSize: CGSize, cursorScale: CGFloat, stackSize: CGSize
    ) -> CompanionPlacement {
        let scale = min(max(cursorScale, 1), 4)
        // The standard arrow is about 12 by 19 points; these offsets clear it.
        let rightOffset = 24 * scale
        let leftOffset = 14 * scale + glyphRadius
        let belowOffset = 28 * scale
        let aboveOffset = 10 * scale + glyphRadius

        let widthNeededOnRight = rightOffset + glyphRadius + glyphToStackGap + stackSize.width + edgeMargin
        let opensToLeft = pointer.x + widthNeededOnRight > canvasSize.width
        let heightNeededBelow = belowOffset + max(stackSize.height, glyphRadius * 2) + edgeMargin
        let opensUpward = pointer.y + heightNeededBelow > canvasSize.height

        var glyphCenter = CGPoint(
            x: opensToLeft ? pointer.x - leftOffset : pointer.x + rightOffset,
            y: opensUpward ? pointer.y - aboveOffset : pointer.y + belowOffset)
        glyphCenter.x = clamp(glyphCenter.x, low: edgeMargin + glyphRadius, high: canvasSize.width - edgeMargin - glyphRadius)
        glyphCenter.y = clamp(glyphCenter.y, low: edgeMargin + glyphRadius, high: canvasSize.height - edgeMargin - glyphRadius)

        // The stack's near edge touches the glyph; its top lines up with the glyph's
        // top when opening downward, its bottom with the glyph's bottom when upward.
        var stackOrigin = CGPoint(
            x: opensToLeft
                ? glyphCenter.x - glyphRadius - glyphToStackGap - stackSize.width
                : glyphCenter.x + glyphRadius + glyphToStackGap,
            y: opensUpward
                // Above the glyph's middle, so the stack clears the row the pointer is on
                // (often the very field the agent is about to use).
                ? glyphCenter.y - stackSize.height
                : glyphCenter.y - glyphRadius)
        stackOrigin.x = clamp(stackOrigin.x, low: edgeMargin, high: canvasSize.width - edgeMargin - stackSize.width)
        stackOrigin.y = clamp(stackOrigin.y, low: edgeMargin, high: canvasSize.height - edgeMargin - stackSize.height)

        return CompanionPlacement(
            glyphCenter: glyphCenter,
            stackCenter: CGPoint(x: stackOrigin.x + stackSize.width / 2, y: stackOrigin.y + stackSize.height / 2),
            opensToLeft: opensToLeft,
            opensUpward: opensUpward)
    }

    /// Smoothstep ease-in-out (3t² − 2t³), Clicky's easing for its flight, here
    /// used for the simulated pointer in demo mode.
    static func smoothstep(_ progress: Double) -> Double {
        let clamped = min(max(progress, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    private static func clamp(_ value: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        guard high >= low else { return low }
        return min(max(value, low), high)
    }
}
