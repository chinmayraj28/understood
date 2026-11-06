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

        /// Asleep: a smaller, dimmer disc than any awake state, so "not listening to you" reads
        /// at a glance, and a quiet hint with the wake phrase.
        static let asleepGlyphScale: CGFloat = 0.85
        static let sleepHintFont = Font.system(size: 14, weight: .semibold, design: .rounded)
        static let sleepHintSurfaceOpacity: Double = 0.86

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

    // MARK: - Menu bar panel

    /// Tokens for the menu bar panel. Unlike the overlay (always dark, drawn over any app), the
    /// panel is a normal Mac window: it follows the system's light or dark appearance and sits on
    /// the system's own translucent material. Every text colour here meets WCAG AA (4.5:1) on the
    /// panel's background and on its cards, in both appearances; the ratios are noted beside each.
    enum Panel {
        static let width: CGFloat = 380
        /// macOS 26's panels and popovers use generous, continuous corners.
        static let cornerRadius: CGFloat = 16
        static let cardCornerRadius: CGFloat = 12
        static let controlCornerRadius: CGFloat = 8
        static let bubbleCornerRadius: CGFloat = 14
        /// The space around the panel's content and between its blocks (the 4/8-point grid).
        static let inset: CGFloat = 16
        static let blockSpacing: CGFloat = 12
        static let iconTile: CGFloat = 28
        /// Taller than this, the conversation scrolls (and keeps the newest line in view).
        static let threadMaxHeight: CGFloat = 220
        /// Taller than this, the whole panel body scrolls (the manager lowers it on small screens).
        static let bodyMaxHeight: CGFloat = 680

        // Text. The system's own secondary label colour is only about 3.9:1 on white, so the
        // panel uses its own, darker in light mode and lighter in dark mode.
        static let textPrimary = Adaptive(light: "#1D1B22", dark: "#F1EFF6")
        /// 7.4:1 on white, 6.4:1 on the light material; 9.6:1 on the dark material.
        static let textSecondary = Adaptive(light: "#55525E", dark: "#C4C0CF")
        /// For quiet labels only (eyebrows, the footer). 5.3:1 on white; 5.4:1 on the dark material.
        static let textTertiary = Adaptive(light: "#6A6773", dark: "#9D99A9")

        /// Iris, for text and icons: 5.7:1 on white (iris 600), 5.7:1 on the dark material (iris 400).
        static let accent = Adaptive(light: "#6B47F5", dark: "#A98BFF")
        /// Fills behind white text: white on iris 600 is 5.7:1, in both appearances.
        static let accentFill = Adaptive(light: "#6B47F5", dark: "#6B47F5")
        static let accentFillPressed = Adaptive(light: "#5733DB", dark: "#5733DB")
        static let accentTint = Adaptive(light: "#6B47F5", dark: "#8B66FF", lightOpacity: 0.10, darkOpacity: 0.20)

        /// Waiting for a yes or an answer: 5.9:1 on white; 11:1 on the dark material.
        static let hold = Adaptive(light: "#8A5A00", dark: "#FFC85C")
        static let holdTint = Adaptive(light: "#FFB224", dark: "#FFB224", lightOpacity: 0.16, darkOpacity: 0.14)
        static let holdEdge = Adaptive(light: "#C98500", dark: "#FFB224", lightOpacity: 0.55, darkOpacity: 0.45)
        /// Done, granted: 6.6:1 on white and 5.4:1 on its own tint; 9.5:1 on the dark material.
        static let success = Adaptive(light: "#156B3F", dark: "#3DDC97")
        static let successTint = Adaptive(light: "#156B3F", dark: "#3DDC97", lightOpacity: 0.10, darkOpacity: 0.14)
        /// Stopped, failed, something wrong: 5.7:1 on white; 6.6:1 on the dark material.
        static let stop = Adaptive(light: "#C4282E", dark: "#FF8A8D")
        static let stopTint = Adaptive(light: "#C4282E", dark: "#FF5A5F", lightOpacity: 0.09, darkOpacity: 0.15)
        static let stopEdge = Adaptive(light: "#C4282E", dark: "#FF5A5F", lightOpacity: 0.35, darkOpacity: 0.40)

        /// Cards sit a step above the material, as grouped rows do in System Settings.
        static let card = Adaptive(light: "#FFFFFF", dark: "#FFFFFF", lightOpacity: 0.78, darkOpacity: 0.06)
        static let cardEdge = Adaptive(light: "#000000", dark: "#FFFFFF", lightOpacity: 0.07, darkOpacity: 0.08)
        static let separator = Adaptive(light: "#000000", dark: "#FFFFFF", lightOpacity: 0.09, darkOpacity: 0.10)
        static let quietFill = Adaptive(light: "#000000", dark: "#FFFFFF", lightOpacity: 0.05, darkOpacity: 0.08)
        static let quietFillHover = Adaptive(light: "#000000", dark: "#FFFFFF", lightOpacity: 0.09, darkOpacity: 0.13)
        /// Handsfree's side of the conversation.
        static let assistantBubble = Adaptive(light: "#000000", dark: "#FFFFFF", lightOpacity: 0.06, darkOpacity: 0.10)
        /// The edge around the whole panel, so it separates from a window of the same colour.
        static let panelEdge = Adaptive(light: "#000000", dark: "#FFFFFF", lightOpacity: 0.12, darkOpacity: 0.14)
        /// Stands in for the system material when the panel is drawn to an image (`--render-states`),
        /// which cannot draw AppKit's material view: close to the popover material over a plain desktop.
        static let snapshotBackground = Adaptive(light: "#F0EFF2", dark: "#29282D")

        /// A colour for light and one for dark, picked from the view's own colour scheme. A SwiftUI
        /// shape style rather than a dynamic NSColor, so it also resolves correctly when drawn off screen.
        struct Adaptive: ShapeStyle {
            let light: String
            let dark: String
            var lightOpacity: Double = 1
            var darkOpacity: Double = 1

            func resolve(in environment: EnvironmentValues) -> Color {
                environment.colorScheme == .dark
                    ? Color(hex: dark).opacity(darkOpacity) : Color(hex: light).opacity(lightOpacity)
            }
        }

        /// The panel's type ramp, in SF Pro. Sizes are at text scale 1 and grow with
        /// `panelTextScale` (see `panelFont`).
        enum TextStyle {
            case hero, title, headline, body, callout, footnote, eyebrow, mono

            var size: CGFloat {
                switch self {
                case .hero: return 22
                case .title: return 17
                case .headline: return 13
                case .body: return 13
                case .callout: return 12
                case .footnote: return 11
                case .eyebrow: return 11
                case .mono: return 11.5
                }
            }

            var weight: Font.Weight {
                switch self {
                case .hero: return .bold
                case .title, .headline, .eyebrow: return .semibold
                default: return .regular
                }
            }
        }

        /// Spring for content changing inside the panel; replaced by a plain fade under Reduce Motion.
        static let change = SwiftUI.Animation.spring(response: 0.35, dampingFraction: 0.85)
    }
}

// MARK: - Panel text size

/// How much larger than standard the panel's text is drawn (1 = standard). macOS has no system-wide
/// text size for apps, so the panel reads its own setting: `defaults write com.handsfree.Handsfree
/// PanelTextScale 1.3` (1 to 1.6). Every panel font goes through `panelFont`, so the whole panel scales.
private struct PanelTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var panelTextScale: CGFloat {
        get { self[PanelTextScaleKey.self] }
        set { self[PanelTextScaleKey.self] = newValue }
    }
}

private struct PanelFontModifier: ViewModifier {
    let style: DS.Panel.TextStyle
    @Environment(\.panelTextScale) private var scale

    func body(content: Content) -> some View {
        let font = Font.system(size: (style.size * scale).rounded(), weight: style.weight, design: style == .mono ? .monospaced : .default)
        if style == .eyebrow {
            content.font(font).textCase(.uppercase).tracking(0.5)
        } else {
            content.font(font)
        }
    }
}

private struct PanelSymbolModifier: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    @Environment(\.panelTextScale) private var scale

    func body(content: Content) -> some View {
        content.font(.system(size: (size * scale).rounded(), weight: weight))
    }
}

extension View {
    /// Sets one of the panel's text styles, scaled by `panelTextScale`.
    func panelFont(_ style: DS.Panel.TextStyle) -> some View {
        modifier(PanelFontModifier(style: style))
    }

    /// Sizes an SF Symbol beside panel text, so it grows with `panelTextScale` as the text does.
    func panelSymbol(_ size: CGFloat, _ weight: Font.Weight = .regular) -> some View {
        modifier(PanelSymbolModifier(size: size, weight: weight))
    }
}

// MARK: - Panel button styles

/// The one main action on screen ("Allow Microphone"): solid iris, white text.
struct PanelPrimaryButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .panelFont(.headline)
            .foregroundStyle(Color.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: DS.Panel.controlCornerRadius, style: .continuous)
                    .fill(isHovered || configuration.isPressed ? AnyShapeStyle(DS.Panel.accentFillPressed) : AnyShapeStyle(DS.Panel.accentFill)))
            .opacity(configuration.isPressed ? 0.88 : 1)
            .contentShape(RoundedRectangle(cornerRadius: DS.Panel.controlCornerRadius, style: .continuous))
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { isHovered = $0 }
            .pointerCursor()
    }
}

/// A supporting action, or the lowest-emphasis one (Quit, details): text on a quiet fill that
/// appears on hover. `isFilled` keeps the fill visible when the button must read as a button at rest.
struct PanelQuietButtonStyle: ButtonStyle {
    var isFilled = false
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .panelFont(.callout)
            .foregroundStyle(isHovered || configuration.isPressed ? AnyShapeStyle(DS.Panel.textPrimary) : AnyShapeStyle(DS.Panel.textSecondary))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minHeight: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fill(isPressed: configuration.isPressed)))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { isHovered = $0 }
            .pointerCursor()
    }

    private func fill(isPressed: Bool) -> AnyShapeStyle {
        if isPressed || isHovered { return AnyShapeStyle(DS.Panel.quietFillHover) }
        return isFilled ? AnyShapeStyle(DS.Panel.quietFill) : AnyShapeStyle(Color.clear)
    }
}

/// The round close button in the panel's header: the one icon-only control.
struct PanelCloseButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(isHovered ? AnyShapeStyle(DS.Panel.textPrimary) : AnyShapeStyle(DS.Panel.textSecondary))
            .frame(width: 22, height: 22)
            .background(Circle().fill(isHovered || configuration.isPressed ? AnyShapeStyle(DS.Panel.quietFillHover) : AnyShapeStyle(DS.Panel.quietFill)))
            .contentShape(Circle())
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { isHovered = $0 }
            .pointerCursor()
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
        overlay { PointerCursorOverlay(isEnabled: isEnabled) }
    }
}

/// True while views are drawn to an image off screen (`--render-states`). SwiftUI's ImageRenderer
/// cannot draw AppKit views and puts a yellow "no entry" placeholder in their place, which hid
/// every button in the panel render. The cursor view draws nothing anyway, so it is left out then.
private struct DrawsForSnapshotKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var drawsForSnapshot: Bool {
        get { self[DrawsForSnapshotKey.self] }
        set { self[DrawsForSnapshotKey.self] = newValue }
    }
}

private struct PointerCursorOverlay: View {
    let isEnabled: Bool
    @Environment(\.drawsForSnapshot) private var drawsForSnapshot

    var body: some View {
        if isEnabled && !drawsForSnapshot { PointerCursorView() }
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
