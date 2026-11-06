//
//  TargetMarkerView.swift
//  Handsfree
//
//  The ring on the screen where the agent is about to act. New for Handsfree.
//
//  Clicky flew its buddy along a bezier arc to point at a target (OverlayWindow.swift,
//  animateBezierFlightArc). Ours does not fly: the real pointer travels, and the
//  companion rides with it. What we add at the target is a ring that closes in
//  as the pointer arrives, so the user can see where it is going early enough to
//  say "stop"; a halo that lands and ripples out when the click happens; and a
//  steady pulsing amber ring while a click is held for the user's yes.
//
//  The ring is drawn twice, a dark stroke under a coloured one, so it reads on
//  white pages and on dark apps alike.
//

import SwiftUI

struct TargetMarkerView: View {
    let marker: CompanionState.TargetMarker

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let elapsed = max(timeline.date.timeIntervalSince(marker.phaseStartedAt), 0)
            switch marker.phase {
            case .approaching:
                approaching(elapsed: elapsed)
            case .clicked:
                clicked(elapsed: elapsed)
            case .held:
                HeldHalo()
            }
        }
        .frame(width: DS.Companion.targetRingDiameter * 2.6, height: DS.Companion.targetRingDiameter * 2.6)
        .allowsHitTesting(false)
    }

    /// The ring starts wide and faint, and closes onto the target as the glide ends.
    private func approaching(elapsed: Double) -> some View {
        let progress = marker.travelSeconds > 0 ? OverlayGeometry.smoothstep(elapsed / marker.travelSeconds) : 1
        let hasArrived = progress >= 1
        return ZStack {
            ContrastRing(color: DS.Colors.accent, lineWidth: DS.Companion.targetRingWidth, dash: hasArrived ? [] : [7, 5])
                .frame(width: DS.Companion.targetRingDiameter, height: DS.Companion.targetRingDiameter)
                .rotationEffect(.degrees(elapsed * 90))
                .scaleEffect(1.9 - 0.9 * progress)
                .opacity(0.35 + 0.65 * progress)
            Circle()
                .fill(DS.Colors.accent)
                .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                .frame(width: 8, height: 8)
                .opacity(progress)
        }
    }

    /// The halo lands: a bright disc that fades, and a ring that ripples outward.
    private func clicked(elapsed: Double) -> some View {
        let progress = min(elapsed / 0.75, 1)
        let easedOut = 1 - pow(1 - progress, 3)
        return ZStack {
            Circle()
                .fill(DS.Colors.accent.opacity(0.55 * (1 - progress)))
                .frame(width: DS.Companion.targetRingDiameter, height: DS.Companion.targetRingDiameter)
                .scaleEffect(0.5 + 0.6 * easedOut)
            ContrastRing(color: DS.Colors.iris300, lineWidth: DS.Companion.targetRingWidth, dash: [])
                .frame(width: DS.Companion.targetRingDiameter, height: DS.Companion.targetRingDiameter)
                .scaleEffect(1 + 1.3 * easedOut)
                .opacity(1 - progress)
            Circle()
                .fill(Color.white)
                .frame(width: 7, height: 7)
                .opacity(1 - progress)
        }
    }
}

/// A steady amber ring with a pulse: the pointer is here and the click is waiting for a yes.
struct HeldHalo: View {
    var body: some View {
        ZStack {
            PulsingRing(color: DS.Colors.hold)
                .frame(width: DS.Companion.targetRingDiameter, height: DS.Companion.targetRingDiameter)
            ContrastRing(color: DS.Colors.hold, lineWidth: DS.Companion.targetRingWidth + 0.5, dash: [])
                .frame(width: DS.Companion.targetRingDiameter, height: DS.Companion.targetRingDiameter)
                .shadow(color: DS.Colors.hold.opacity(0.6), radius: 8)
        }
    }
}

/// A coloured ring over a slightly wider dark ring, for contrast on any background.
struct ContrastRing: View {
    let color: Color
    let lineWidth: CGFloat
    let dash: [CGFloat]

    var body: some View {
        ZStack {
            Circle().stroke(Color.black.opacity(0.45), style: StrokeStyle(lineWidth: lineWidth + 2.5, dash: dash))
            Circle().stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: dash))
        }
    }
}
