//
//  CompanionGlyphs.swift
//  Handsfree
//
//  The round symbol beside the pointer, one look per state.
//
//  Adapted from Clicky (github.com/farzaa/clicky, MIT): the waveform is
//  BlueCursorWaveformView and the spinner is BlueCursorSpinnerView, both in
//  OverlayWindow.swift. Their motion is kept (the bar profile, the 36 fps
//  timeline, the level easing, the 0.8 s linear spin); they are drawn larger,
//  in white on a dark disc, so they read on any background. The disc, the
//  resting dot and the action, hold, stop and result symbols are new.
//

import SwiftUI

/// The companion's symbol. Shrinks to a small calm dot when nothing is happening.
struct CompanionGlyphView: View {
    let glyph: CompanionState.Glyph
    let isResting: Bool
    let voiceLevel: Double

    var body: some View {
        ZStack {
            RestingDot()
                .opacity(isResting ? 1 : 0)
                .scaleEffect(isResting ? 1 : 0.4)

            ZStack {
                Circle().fill(discFill)
                Circle().strokeBorder(ringColor, lineWidth: DS.Companion.glyphRingWidth)
                if glyph == .thinking || glyph == .connecting {
                    SpinnerRing(color: glyph == .connecting ? DS.Colors.muted : DS.Colors.iris300)
                }
                if glyph == .holding || glyph == .asking {
                    PulsingRing(color: DS.Colors.hold)
                }
                if glyph == .waking {
                    // A ripple going out: "I heard you".
                    PulsingRing(color: DS.Colors.accent)
                }
                symbol
                    .id(glyph)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            .frame(width: DS.Companion.glyphDiameter, height: DS.Companion.glyphDiameter)
            .overlay(Circle().stroke(DS.Companion.surfaceEdge, lineWidth: 1).padding(-1))
            .shadow(color: glowColor.opacity(0.55), radius: 10)
            .shadow(color: DS.Companion.shadow, radius: 6, y: 2)
            .opacity(isResting ? 0 : (glyph == .asleep ? 0.9 : 1))
            .scaleEffect(isResting ? 0.35 : (glyph == .asleep ? DS.Companion.asleepGlyphScale : 1))
        }
        .frame(width: DS.Companion.glyphDiameter + 20, height: DS.Companion.glyphDiameter + 20)
        .animation(DS.Companion.stateSpring, value: isResting)
        .animation(DS.Companion.stateSpring, value: glyph)
    }

    @ViewBuilder private var symbol: some View {
        switch glyph {
        case .asleep:
            // Still and dim: no breathing, no glow. It is not listening to the user.
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DS.Colors.iris300.opacity(0.8))
        case .waking:
            Image(systemName: "ear.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
        case .userSpeaking:
            WaveformBars(level: voiceLevel)
        case .agentSpeaking:
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(DS.Colors.iris300)
                .symbolEffect(.variableColor.iterative, options: .repeating)
        case .listening:
            Circle().fill(DS.Colors.accent).frame(width: 9, height: 9)
        case .connecting:
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .heavy)).foregroundStyle(DS.Colors.muted)
        case .thinking:
            Image(systemName: "eye.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
        case .moving:
            Image(systemName: "cursorarrow.motionlines").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
        case .clicking:
            Image(systemName: "hand.tap.fill").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
        case .typing:
            Image(systemName: "keyboard.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
        case .scrolling:
            Image(systemName: "arrow.up.arrow.down").font(.system(size: 13, weight: .heavy)).foregroundStyle(.white)
        case .holding:
            Image(systemName: "pause.fill").font(.system(size: 14, weight: .heavy)).foregroundStyle(DS.Colors.hold)
        case .asking:
            Image(systemName: "questionmark").font(.system(size: 16, weight: .heavy)).foregroundStyle(DS.Colors.hold)
        case .stopped:
            Image(systemName: "stop.fill").font(.system(size: 13, weight: .heavy)).foregroundStyle(.white)
        case .done:
            Image(systemName: "checkmark").font(.system(size: 15, weight: .heavy)).foregroundStyle(DS.Colors.success)
        case .failed:
            Image(systemName: "exclamationmark").font(.system(size: 16, weight: .heavy)).foregroundStyle(DS.Colors.stopText)
        case .cancelled:
            Image(systemName: "xmark").font(.system(size: 13, weight: .heavy)).foregroundStyle(DS.Colors.muted)
        case .disconnected:
            Image(systemName: "wifi.slash").font(.system(size: 13, weight: .bold)).foregroundStyle(DS.Colors.muted)
        }
    }

    private var discFill: Color {
        glyph == .stopped ? DS.Colors.stop : DS.Companion.surface
    }

    private var ringColor: Color {
        switch glyph {
        case .holding, .asking: return DS.Colors.hold
        case .stopped: return Color.white.opacity(0.9)
        case .done: return DS.Colors.success
        case .failed: return DS.Colors.stop
        case .cancelled, .disconnected, .connecting: return DS.Colors.muted
        // A night-time tint of the companion's own colour: still Handsfree, clearly not the
        // grey of "not connected", and much dimmer than the bright ring of an awake state.
        case .asleep: return DS.Colors.accent.opacity(0.4)
        case .thinking: return DS.Colors.accent.opacity(0.35)
        default: return DS.Colors.accent
        }
    }

    private var glowColor: Color {
        switch glyph {
        case .holding, .asking: return DS.Colors.hold
        case .stopped, .failed: return DS.Colors.stop
        case .done: return DS.Colors.success
        case .cancelled, .disconnected, .connecting, .asleep: return .clear
        default: return DS.Colors.accent
        }
    }
}

/// The resting companion: a small iris dot that breathes slowly, like a status
/// light, so the user can see at a glance that it is there and listening.
struct RestingDot: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let phase = (sin(timeline.date.timeIntervalSinceReferenceDate * 2 * .pi / 2.8) + 1) / 2
            Circle()
                .fill(DS.Colors.accent)
                .frame(width: DS.Companion.restingDotDiameter, height: DS.Companion.restingDotDiameter)
                .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1.5))
                .shadow(color: DS.Colors.accent.opacity(0.35 + 0.35 * phase), radius: 4 + 5 * phase)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .scaleEffect(0.92 + 0.12 * phase)
        }
    }
}

/// Five bars that move with the user's voice. Clicky's waveform, at 1.7× its height,
/// in white so it reads on the dark disc.
struct WaveformBars: View {
    let level: Double
    private let barProfile: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 36.0)) { timeline in
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<barProfile.count, id: \.self) { barIndex in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.white)
                        .frame(width: 3, height: barHeight(barIndex, timeline.date))
                }
            }
            .animation(.linear(duration: 0.08), value: level)
        }
    }

    /// Clicky's formula: a slow idle ripple plus a part that follows the level,
    /// eased so quiet speech still moves the bars.
    private func barHeight(_ barIndex: Int, _ date: Date) -> CGFloat {
        let phase = CGFloat(date.timeIntervalSinceReferenceDate * 3.6) + CGFloat(barIndex) * 0.35
        let normalizedLevel = max(CGFloat(level) - 0.008, 0)
        let easedLevel = pow(min(normalizedLevel * 2.85, 1), 0.76)
        let reactiveHeight = easedLevel * 15 * barProfile[barIndex]
        let idlePulse = (sin(phase) + 1) / 2 * 2.5
        return 4 + reactiveHeight + idlePulse
    }
}

/// Clicky's spinner: a trimmed circle with an angular gradient, one turn every
/// 0.8 s. Here it runs around the edge of the disc.
struct SpinnerRing: View {
    let color: Color
    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0.12, to: 0.82)
            .stroke(
                AngularGradient(colors: [color.opacity(0), color], center: .center),
                style: StrokeStyle(lineWidth: DS.Companion.glyphRingWidth + 0.5, lineCap: .round))
            .padding(DS.Companion.glyphRingWidth / 2)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { isSpinning = true }
            }
    }
}

/// A ring that keeps swelling outward and fading: "waiting for you".
struct PulsingRing: View {
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let progress = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
            Circle()
                .stroke(color, lineWidth: 2)
                .scaleEffect(1 + 0.7 * progress)
                .opacity(0.8 * (1 - progress))
        }
    }
}

/// Demo mode only: a drawn pointer arrow standing in for the real pointer, so the
/// demo can show the pointer travelling without moving the user's real one.
struct SimulatedPointerArrow: View {
    var body: some View {
        PointerArrowShape()
            .fill(Color.white)
            .overlay(PointerArrowShape().stroke(Color.black, style: StrokeStyle(lineWidth: 1.3, lineJoin: .round)))
            .frame(width: 14, height: 21)
            .shadow(color: .black.opacity(0.35), radius: 1.5, x: 0, y: 1)
    }
}

/// The classic arrow, tip at the top left of its frame.
struct PointerArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + height * 0.82))
        path.addLine(to: CGPoint(x: rect.minX + width * 0.29, y: rect.minY + height * 0.64))
        path.addLine(to: CGPoint(x: rect.minX + width * 0.50, y: rect.minY + height * 0.98))
        path.addLine(to: CGPoint(x: rect.minX + width * 0.68, y: rect.minY + height * 0.90))
        path.addLine(to: CGPoint(x: rect.minX + width * 0.48, y: rect.minY + height * 0.58))
        path.addLine(to: CGPoint(x: rect.minX + width * 0.86, y: rect.minY + height * 0.58))
        path.closeSubpath()
        return path
    }
}
