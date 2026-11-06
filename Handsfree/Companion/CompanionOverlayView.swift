//
//  CompanionOverlayView.swift
//  Handsfree
//
//  What one screen's overlay draws: the companion beside the pointer (glyph,
//  caption, question or confirmation card) and the target ring where the agent
//  is about to act.
//
//  Adapted from Clicky (github.com/farzaa/clicky, MIT): BlueCursorView in
//  OverlayWindow.swift. Kept: one view per screen that shows the companion only
//  on the screen the pointer is on; the companion offset beside the pointer and
//  moved with Clicky's spring (response 0.2, damping 0.6); measuring the bubble
//  so it can be placed beside the pointer; views kept in
//  the tree and cross-faded rather than inserted and removed. Changed: the
//  companion never leaves the pointer (Clicky's buddy flew off to point at
//  things; ours stays because the real pointer is what acts), captions are a
//  dark high-contrast surface instead of a blue bubble, and the card for a held
//  action is new.
//

import AppKit
import HFCore
import SwiftUI

struct CompanionOverlayView: View {
    /// This screen's frame in AppKit coordinates.
    let screenFrame: CGRect
    /// Height of the main display, for converting HFCore's top-left points.
    let mainDisplayHeight: CGFloat
    let showsSimulatedPointer: Bool
    @ObservedObject var model: CompanionModel
    @ObservedObject var pointer: PointerTracker

    @State private var stackSize: CGSize = .zero
    private let cursorScale = PointerTracker.systemCursorScale()

    var body: some View {
        let state = model.state
        let pointerOnThisScreen = Self.screen(screenFrame, contains: pointer.location)
        let pointerOnCanvas = OverlayGeometry.canvasPoint(fromAppKit: pointer.location, screenFrame: screenFrame)
        let placement = OverlayGeometry.companionPlacement(
            pointer: pointerOnCanvas, canvasSize: screenFrame.size, cursorScale: cursorScale, stackSize: stackSize)

        ZStack(alignment: .topLeading) {
            Color.clear

            // Where the agent is acting. Drawn on whichever screen the target is on.
            if let marker = state.target, let markerPoint = canvasPoint(forTopLeft: marker.point) {
                TargetMarkerView(marker: marker)
                    .position(markerPoint)
                    .transition(.opacity)
            } else if state.prompt?.isConfirmation == true && pointerOnThisScreen {
                // Held without a known target: the halo sits on the pointer's tip.
                HeldHalo()
                    .frame(width: DS.Companion.targetRingDiameter, height: DS.Companion.targetRingDiameter)
                    .position(pointerOnCanvas)
                    .transition(.opacity)
            }

            if pointerOnThisScreen {
                if showsSimulatedPointer {
                    SimulatedPointerArrow()
                        .position(x: pointerOnCanvas.x + 7, y: pointerOnCanvas.y + 10.5)
                }

                CompanionGlyphView(glyph: state.glyph, isResting: state.isResting, voiceLevel: state.voiceLevel)
                    .position(placement.glyphCenter)
                    .animation(DS.Companion.followSpring, value: placement.glyphCenter)

                CompanionStack(state: state, alignsTrailing: placement.opensToLeft)
                    .fixedSize()
                    // Measure the stack so it can be placed beside the glyph and kept on screen.
                    // (Clicky used a PreferenceKey for this; inside our hosting view the
                    // preference never arrived, so the size stayed zero and the stack sat
                    // on top of the pointer. onGeometryChange reports it directly.)
                    .onGeometryChange(for: CGSize.self) { geometry in geometry.size } action: { newSize in
                        stackSize = newSize
                    }
                    .position(placement.stackCenter)
                    .animation(DS.Companion.followSpring, value: placement.stackCenter)
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .animation(DS.Companion.fadeIn, value: state.target?.phase)
        .allowsHitTesting(false)
        // The overlay is never offered to accessibility (see OverlayWindow).
        .accessibilityHidden(true)
    }

    /// An HFCore point (top-left origin) on this canvas, or nil if it is on another screen.
    private func canvasPoint(forTopLeft point: CGPoint) -> CGPoint? {
        let appKitPoint = OverlayGeometry.appKitPoint(fromTopLeft: point, mainDisplayHeight: mainDisplayHeight)
        guard Self.screen(screenFrame, contains: appKitPoint) else { return nil }
        return OverlayGeometry.canvasPoint(fromAppKit: appKitPoint, screenFrame: screenFrame)
    }

    /// Like CGRect.contains, but counting the top and right edges, where the
    /// pointer can rest (the menu bar row, the right edge).
    private static func screen(_ frame: CGRect, contains point: CGPoint) -> Bool {
        point.x >= frame.minX && point.x <= frame.maxX && point.y >= frame.minY && point.y <= frame.maxY
    }
}

/// The caption and the card, stacked beside the glyph.
struct CompanionStack: View {
    let state: CompanionState
    /// True when the stack is to the left of the pointer, so it lines up on its right edge.
    let alignsTrailing: Bool

    var body: some View {
        VStack(alignment: alignsTrailing ? .trailing : .leading, spacing: 8) {
            if state.sleepHint != nil {
                SleepHintPill(wakePhrase: state.wakePhrase)
                    .transition(.opacity)
            }
            if let caption = state.caption {
                CaptionPill(caption: caption)
                    .id(caption.text)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: alignsTrailing ? .trailing : .leading)),
                        removal: .opacity))
            }
            if let prompt = state.prompt {
                PromptCard(prompt: prompt)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: alignsTrailing ? .topTrailing : .topLeading)))
            }
        }
        .animation(DS.Companion.stateSpring, value: state.caption?.text)
        .animation(DS.Companion.stateSpring, value: state.prompt)
        .animation(DS.Companion.fadeOut, value: state.sleepHint)
    }
}

/// While asleep: that it is not listening, and what to say to wake it. "Asleep" is quiet; the
/// phrase is bright, because it is the one thing to read. No animation and a dimmer surface,
/// because it stays up all the time the app is asleep, beside a pointer the user cannot move away.
struct SleepHintPill: View {
    let wakePhrase: String

    var body: some View {
        (Text("Asleep. ").foregroundColor(DS.Colors.textTertiary)
            + Text("Say ").foregroundColor(DS.Colors.textSecondary)
            + Text("\u{201C}\(wakePhrase)\u{201D}").foregroundColor(DS.Colors.textPrimary))
            .font(DS.Companion.sleepHintFont)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(hex: "#0F0E13").opacity(DS.Companion.sleepHintSurfaceOpacity))
                    .overlay(Capsule(style: .continuous).strokeBorder(DS.Companion.surfaceEdge, lineWidth: 1))
                    .shadow(color: DS.Companion.shadow, radius: 8, y: 3))
    }
}

/// One line beside the pointer: what was heard, what is being said, what is happening.
struct CaptionPill: View {
    let caption: CompanionState.Caption

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let symbolName {
                Image(systemName: symbolName)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(symbolColor)
            }
            Text(caption.text)
                .font(DS.Companion.captionFont)
                .foregroundStyle(textColor)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: DS.Companion.captionMaxWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Companion.captionCornerRadius, style: .continuous)
                .fill(DS.Companion.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Companion.captionCornerRadius, style: .continuous)
                        .strokeBorder(edgeColor, lineWidth: 1))
                .shadow(color: DS.Companion.shadow, radius: 12, y: 5))
    }

    private var symbolName: String? {
        switch caption.tone {
        case .heard: return "mic.fill"
        case .awake: return "ear"
        case .spoken: return "speaker.wave.2.fill"
        case .progress: return "arrow.forward"
        case .success: return "checkmark.circle.fill"
        case .problem: return "exclamationmark.triangle.fill"
        case .stop: return "stop.circle.fill"
        case .muted: return "wifi.slash"
        }
    }

    private var symbolColor: Color {
        switch caption.tone {
        case .heard: return DS.Colors.textSecondary
        case .spoken, .progress, .awake: return DS.Colors.accentText
        case .success: return DS.Colors.success
        case .problem: return DS.Colors.holdText
        case .stop: return DS.Colors.stopText
        case .muted: return DS.Colors.muted
        }
    }

    private var textColor: Color {
        caption.tone == .muted ? DS.Colors.textSecondary : DS.Colors.textPrimary
    }

    private var edgeColor: Color {
        switch caption.tone {
        case .stop: return DS.Colors.stop.opacity(0.7)
        case .success: return DS.Colors.success.opacity(0.45)
        default: return DS.Companion.surfaceEdge
        }
    }
}

/// The card for a question, or for an action held until the user says yes.
/// The held version is made to be unmistakable: amber edge and glow, a pause
/// symbol, the question in large type, what exactly will happen, and how to answer.
struct PromptCard: View {
    let prompt: CompanionState.Prompt

    var body: some View {
        let toneColor = prompt.isConfirmation ? DS.Colors.hold : DS.Colors.accentText
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: prompt.isConfirmation ? "pause.circle.fill" : "questionmark.circle.fill")
                    .font(.system(size: 15, weight: .bold))
                Text(prompt.isConfirmation ? "WAITING FOR YOUR YES" : "QUESTION")
                    .font(DS.Companion.cardLabelFont)
                    .tracking(0.8)
            }
            .foregroundStyle(toneColor)

            Text(prompt.question ?? (prompt.isConfirmation ? "Go ahead?" : "\u{2026}"))
                .font(DS.Companion.cardQuestionFont)
                .foregroundStyle(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if let action = prompt.heldAction {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text("Holding: \(action)")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(DS.Companion.cardDetailFont)
                .foregroundStyle(DS.Colors.textSecondary)
            }

            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)

            Text(prompt.isConfirmation
                 ? "Say \u{201C}yes\u{201D} to go ahead, or \u{201C}no\u{201D} to stop."
                 : "Say your answer.")
                .font(DS.Companion.cardHintFont)
                .foregroundStyle(prompt.isConfirmation ? DS.Colors.holdText : DS.Colors.textSecondary)
        }
        .padding(16)
        .frame(width: DS.Companion.cardWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Companion.cardCornerRadius, style: .continuous)
                .fill(DS.Companion.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Companion.cardCornerRadius, style: .continuous)
                        .strokeBorder(toneColor.opacity(prompt.isConfirmation ? 1 : 0.6), lineWidth: prompt.isConfirmation ? 2.5 : 1.5))
                .shadow(color: toneColor.opacity(prompt.isConfirmation ? 0.35 : 0.15), radius: 18)
                .shadow(color: DS.Companion.shadow, radius: 14, y: 6))
    }
}
