//
//  DesignSystem.swift
//  Handsfree
//
//  Adapted from Clicky (github.com/farzaa/clicky, MIT, Farza): DesignSystem.swift.
//  Kept: the `DS` token namespace, layered dark surfaces, the spacing, radius
//  and duration scales, the hex colour helper and the AppKit pointer-cursor
//  bridge. Changed: our own "iris" accent instead of Clicky's blue, semantic
//  colours for the companion's states, and a `Companion` section of tokens for
//  the overlay, sized for someone reading at a glance from a distance.
//
//  Why iris (violet) and not blue: most Mac apps use a blue accent, so a blue
//  companion blends into the app it is working in. Violet stands out on white,
//  grey and dark windows alike, and is not already taken by a meaning
//  (green is done, amber is waiting, red is stop).
//

import AppKit
import SwiftUI

/// All design tokens. Usage: `DS.Colors.accent`, `DS.Companion.captionFont`.
enum DS {

    // MARK: - Colours

    enum Colors {
        // Surfaces, deepest to most raised, with a faint violet cast so the
        // panel and the overlay feel like one product.
        static let background = Color(hex: "#111015")
        static let surface1 = Color(hex: "#18171D")
        static let surface2 = Color(hex: "#211F27")
        static let surface3 = Color(hex: "#2A2831")
        static let surface4 = Color(hex: "#33313B")

        static let borderSubtle = Color(hex: "#36343F")
        static let borderStrong = Color(hex: "#4A4756")

        static let textPrimary = Color(hex: "#F1EFF6")
        static let textSecondary = Color(hex: "#B8B4C4")
        static let textTertiary = Color(hex: "#7D7989")
        /// White on `accentFill` (#6B47F5) is about 5.7:1, WCAG AA for any text size.
        static let textOnAccent: Color = .white

        // Iris, the Handsfree accent.
        static let iris300 = Color(hex: "#C7B6FF")
        static let iris400 = Color(hex: "#A98BFF")
        static let iris500 = Color(hex: "#8B66FF")
        static let iris600 = Color(hex: "#6B47F5")
        static let iris700 = Color(hex: "#5733DB")

        /// The companion's own colour: rings, glows, the listening dot.
        static let accent = iris500
        /// Accent text and icons on dark surfaces.
        static let accentText = iris400
        /// Solid fills behind white text (buttons).
        static let accentFill = iris600
        static let accentFillHover = iris700
        static let accentSubtle = iris500.opacity(0.14)

        // Meanings. Each is used for one thing only, so a glance is enough.
        /// Waiting: a question or an action held for the user's yes.
        static let hold = Color(hex: "#FFB224")
        static let holdText = Color(hex: "#FFC85C")
        /// Stop: the user said stop, or something failed.
        static let stop = Color(hex: "#FF5A5F")
        static let stopText = Color(hex: "#FF7A7E")
        /// Done: a task finished, a permission is granted.
        static let success = Color(hex: "#3DDC97")
        /// Not connected, cancelled, nothing to do.
        static let muted = Color(hex: "#8E8B99")

        static var disabledBackground: Color { textPrimary.opacity(0.12) }
        static var disabledText: Color { textPrimary.opacity(0.38) }
    }

    // MARK: - Scales (from Clicky)

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
    }

    enum CornerRadius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 8
        static let large: CGFloat = 10
        static let extraLarge: CGFloat = 12
        static let panel: CGFloat = 14
    }

    enum Animation {
        static let fast: Double = 0.15
        static let normal: Double = 0.25
        static let slow: Double = 0.4
    }

    // MARK: - Companion overlay

    /// Tokens for the overlay beside the pointer. Sizes are larger than Clicky's
    /// (its bubbles use 11 pt text) because our user may be further from the
    /// screen, may have limited eye or neck movement, and has to read a
    /// confirmation question without moving to it.
    enum Companion {
        /// The surface behind every caption and card: near-black at high opacity, so
        /// white text reads on any app beneath, light or dark.
        static let surface = Color(hex: "#0F0E13").opacity(0.93)
        /// A thin light edge so dark surfaces still separate from dark windows.
        static let surfaceEdge = Color.white.opacity(0.16)
        static let shadow = Color.black.opacity(0.45)

        static let restingDotDiameter: CGFloat = 11
        static let glyphDiameter: CGFloat = 34
        static let glyphRingWidth: CGFloat = 2.5

        static let captionFont = Font.system(size: 15, weight: .semibold, design: .rounded)
        static let captionMaxWidth: CGFloat = 340
        static let captionCornerRadius: CGFloat = 11

        static let cardWidth: CGFloat = 380
        static let cardCornerRadius: CGFloat = 16
        static let cardLabelFont = Font.system(size: 12, weight: .heavy, design: .rounded)
        static let cardQuestionFont = Font.system(size: 20, weight: .bold, design: .rounded)
        static let cardDetailFont = Font.system(size: 13, weight: .medium, design: .rounded)
        static let cardHintFont = Font.system(size: 14, weight: .semibold, design: .rounded)

        static let targetRingDiameter: CGFloat = 46
        static let targetRingWidth: CGFloat = 3

        /// Following the pointer: Clicky's spring, unchanged. Fast enough to feel
        /// attached (response 0.2 s), with a little overshoot (damping 0.6) so the
        /// companion feels alive rather than glued on.
        static let followSpring = SwiftUI.Animation.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0)
        /// Changing state: a softer spring for size and content changes.
        static let stateSpring = SwiftUI.Animation.spring(response: 0.32, dampingFraction: 0.78)
        static let fadeIn = SwiftUI.Animation.easeOut(duration: 0.18)
        static let fadeOut = SwiftUI.Animation.easeIn(duration: 0.35)
    }
}

// MARK: - Button styles (adapted from Clicky's DSPrimaryButtonStyle and DSOutlinedButtonStyle, smaller for the panel)

/// The one main action in a section, such as "Ask macOS".
struct DSPrimaryButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(DS.Colors.textOnAccent)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(isHovered || configuration.isPressed ? DS.Colors.accentFillHover : DS.Colors.accentFill))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { isHovered = $0 }
            .pointerCursor()
    }
}

/// A supporting action with a border, such as "Open Settings".
struct DSOutlinedButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(DS.Colors.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(configuration.isPressed ? DS.Colors.surface3 : (isHovered ? DS.Colors.surface2 : DS.Colors.surface1)))
            .overlay(Capsule().stroke(isHovered ? DS.Colors.borderStrong : DS.Colors.borderSubtle, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { isHovered = $0 }
            .pointerCursor()
    }
}

/// Lowest emphasis: text only (Clicky's DSTextButtonStyle).
struct DSTextButtonStyle: ButtonStyle {
    var fontSize: CGFloat = 12
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .medium))
            .foregroundColor(isHovered || configuration.isPressed ? DS.Colors.textPrimary : DS.Colors.textTertiary)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { isHovered = $0 }
            .pointerCursor()
    }
}

// MARK: - Pointer cursor (from Clicky)

/// Uses AppKit cursor rects to show the pointing hand. Clicky found this more
/// reliable than NSCursor.push/pop inside SwiftUI's onHover.
private class PointerCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct PointerCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { PointerCursorNSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

extension View {
    /// Shows the pointing-hand cursor over an interactive control.
    func pointerCursor(isEnabled: Bool = true) -> some View {
        overlay { if isEnabled { PointerCursorView() } }
    }
}

// MARK: - Colour helper (from Clicky)

extension Color {
    /// A colour from a hex string such as "#FF5733" or "FF5733".
    init(hex: String) {
        let sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        var rgbValue: UInt64 = 0
        Scanner(string: sanitized).scanHexInt64(&rgbValue)
        self.init(
            red: Double((rgbValue & 0xFF0000) >> 16) / 255.0,
            green: Double((rgbValue & 0x00FF00) >> 8) / 255.0,
            blue: Double(rgbValue & 0x0000FF) / 255.0)
    }
}
