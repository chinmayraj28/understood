//
//  PanelComponents.swift
//  Handsfree
//
//  Small building blocks shared by the panel's views: a card, a section
//  heading, an icon tile, a status tag (icon and word, so colour is never the
//  only signal), a gently pulsing dot, and a scroll area that is only as tall
//  as its content up to a limit. New for Handsfree.
//

import SwiftUI

/// The colour family of an icon or tag. Each meaning has one colour, as on the companion.
enum PanelTone {
    case neutral, accent, hold, success, stop

    var foreground: AnyShapeStyle {
        switch self {
        case .neutral: return AnyShapeStyle(DS.Panel.textSecondary)
        case .accent: return AnyShapeStyle(DS.Panel.accent)
        case .hold: return AnyShapeStyle(DS.Panel.hold)
        case .success: return AnyShapeStyle(DS.Panel.success)
        case .stop: return AnyShapeStyle(DS.Panel.stop)
        }
    }

    var tint: AnyShapeStyle {
        switch self {
        case .neutral: return AnyShapeStyle(DS.Panel.quietFill)
        case .accent: return AnyShapeStyle(DS.Panel.accentTint)
        case .hold: return AnyShapeStyle(DS.Panel.holdTint)
        case .success: return AnyShapeStyle(DS.Panel.successTint)
        case .stop: return AnyShapeStyle(DS.Panel.stopTint)
        }
    }
}

extension PanelSnapshot.Activity {
    var symbol: String {
        switch self {
        case .asleep: return "moon.zzz.fill"
        case .waking, .listening: return "ear"
        case .connecting: return "antenna.radiowaves.left.and.right"
        case .hearing: return "waveform"
        case .speaking: return "speaker.wave.2.fill"
        case .working: return "cursorarrow.motionlines"
        case .question: return "questionmark.bubble.fill"
        case .waitingForYes: return "hand.raised.fill"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .stopped: return "stop.circle.fill"
        case .cancelled: return "xmark.circle.fill"
        case .notConnected: return "wifi.slash"
        }
    }

    var tone: PanelTone {
        switch self {
        case .asleep, .cancelled, .notConnected, .connecting: return .neutral
        case .question, .waitingForYes: return .hold
        case .done: return .success
        case .failed, .stopped: return .stop
        default: return .accent
        }
    }

    /// Something is happening right now, so its icon may breathe (never under Reduce Motion).
    var isLive: Bool {
        switch self {
        case .listening, .hearing, .speaking, .working, .waking, .connecting: return true
        default: return false
        }
    }
}

/// A grouped surface, like a group of rows in System Settings.
struct PanelCard<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.Panel.cardCornerRadius, style: .continuous).fill(DS.Panel.card))
            .clipShape(RoundedRectangle(cornerRadius: DS.Panel.cardCornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Panel.cardCornerRadius, style: .continuous).strokeBorder(DS.Panel.cardEdge, lineWidth: 1))
    }
}

/// A small heading over a group, read as a heading by VoiceOver.
struct PanelSectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .panelFont(.eyebrow)
                .foregroundStyle(DS.Panel.textTertiary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .panelFont(.footnote)
                    .foregroundStyle(DS.Panel.textTertiary)
            }
        }
        .padding(.horizontal, 4)
    }
}

/// A rounded square holding a symbol, like the icons in System Settings.
struct PanelIconTile: View {
    let symbol: String
    var tone: PanelTone = .neutral
    var size: CGFloat = DS.Panel.iconTile
    @Environment(\.panelTextScale) private var scale

    var body: some View {
        let side = size * min(scale, 1.3)
        Image(systemName: symbol)
            .font(.system(size: side * 0.48, weight: .semibold))
            .foregroundStyle(tone.foreground)
            .frame(width: side, height: side)
            .background(RoundedRectangle(cornerRadius: side * 0.26, style: .continuous).fill(tone.tint))
            .accessibilityHidden(true)
    }
}

/// An icon and a word, in one colour: "✓ Done", "! Turned off". The word carries the meaning.
struct PanelStatusTag: View {
    let symbol: String
    let text: String
    let tone: PanelTone
    /// Without the tinted capsule, for states that should not draw the eye (a step not yet reached).
    var isQuiet = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .panelSymbol(10, .bold)
                .accessibilityHidden(true)
            Text(text)
                .panelFont(.footnote)
                .fontWeight(.semibold)
        }
        .foregroundStyle(tone.foreground)
        // No capsule, no inset: a quiet tag lines up with the text around it.
        .padding(.horizontal, isQuiet ? 0 : 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(isQuiet ? AnyShapeStyle(Color.clear) : tone.tint))
        .fixedSize()
    }
}

/// A dot with a ring that slowly spreads out: "this is happening now". Still under Reduce Motion.
struct PanelPulsingDot: View {
    var tone: PanelTone = .accent
    var diameter: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(tone.foreground)
            .frame(width: diameter, height: diameter)
            .overlay(
                Circle()
                    .stroke(tone.foreground, lineWidth: 1.5)
                    .scaleEffect(isPulsing ? 2.4 : 1)
                    .opacity(isPulsing ? 0 : 0.6))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { isPulsing = true }
            }
            .accessibilityHidden(true)
    }
}

/// The Handsfree mark (the menu bar icon, in white) on an iris tile.
struct PanelBrandTile: View {
    var size: CGFloat = DS.Panel.iconTile

    var body: some View {
        Image(nsImage: BrandMarks.menuBarIcon())
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .frame(width: size * 0.64, height: size * 0.64)
            .foregroundStyle(Color.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(LinearGradient(colors: [DS.Colors.iris500, DS.Colors.iris700], startPoint: .top, endPoint: .bottom)))
            .accessibilityHidden(true)
    }
}

// MARK: - A scroll area only as tall as its content

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    // Siblings combine by the tallest. Each area stops its own value at its edge (see transformPreference
    // below), so an outer area never sees a nested one's full, unclipped height.
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Scrolls only when its content is taller than `maxHeight`; otherwise it is exactly as tall as
/// the content, so the panel fits snugly. With `keepsBottomInView`, it scrolls to `bottomID`
/// whenever that changes (the newest line of the conversation).
///
/// When drawn to an image (`--render-states`) there is no scrolling: the content is clipped to
/// `maxHeight`, showing its bottom or its top, exactly as the live panel would at rest.
struct CappedScrollArea<Content: View>: View {
    let maxHeight: CGFloat
    var keepsBottomInView = false
    var bottomID: Int?
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 0
    @Environment(\.drawsForSnapshot) private var drawsForSnapshot

    var body: some View {
        if drawsForSnapshot {
            content
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: maxHeight, alignment: keepsBottomInView ? .bottom : .top)
                .clipped()
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    content
                        .fixedSize(horizontal: false, vertical: true)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: ContentHeightKey.self, value: geometry.size.height)
                        })
                }
                .frame(height: max(1, min(contentHeight, maxHeight)))
                .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
                .transformPreference(ContentHeightKey.self) { $0 = 0 }
                .scrollBounceBehavior(.basedOnSize)
                .onAppear { scrollToBottom(proxy, animated: false) }
                .onChange(of: bottomID) { _, _ in scrollToBottom(proxy, animated: true) }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard keepsBottomInView, let bottomID else { return }
        if animated {
            withAnimation(.easeOut(duration: DS.Animation.normal)) { proxy.scrollTo(bottomID, anchor: .bottom) }
        } else {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
    }
}
