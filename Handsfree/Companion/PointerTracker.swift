//
//  PointerTracker.swift
//  Handsfree
//
//  Where the pointer is, sixty times a second, for the companion to follow.
//
//  Adapted from Clicky (github.com/farzaa/clicky, MIT): BlueCursorView.startTrackingCursor
//  in OverlayWindow.swift polls NSEvent.mouseLocation on a 0.016 s timer. We do
//  the same, in one shared object instead of once per screen, and add a
//  simulated pointer for demo mode so the demo never moves the user's real one.
//

import AppKit
import Combine

@MainActor
final class PointerTracker: ObservableObject {
    enum Mode {
        /// Follow the real pointer. The hands move it; we only watch.
        case realPointer
        /// Demo mode: an imaginary pointer that glides when the demo says the hands moved.
        case simulated
    }

    /// The pointer's position in AppKit screen coordinates (origin bottom left).
    @Published private(set) var location: CGPoint

    let mode: Mode
    private var pollTimer: Timer?

    private struct Glide {
        let start: CGPoint
        let end: CGPoint
        let startedAt: Date
        let seconds: Double
    }
    private var activeGlide: Glide?

    init(mode: Mode) {
        self.mode = mode
        self.location = NSEvent.mouseLocation
    }

    func start() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // .common so the companion keeps following while a menu is being tracked.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Demo mode only: put the imaginary pointer somewhere at once.
    func placeSimulatedPointer(atAppKitPoint point: CGPoint) {
        guard mode == .simulated else { return }
        activeGlide = nil
        location = point
    }

    /// Demo mode only: glide the imaginary pointer the way the real hands would.
    func glideSimulatedPointer(toAppKitPoint point: CGPoint, seconds: Double) {
        guard mode == .simulated else { return }
        activeGlide = Glide(start: location, end: point, startedAt: Date(), seconds: max(seconds, 0.01))
    }

    /// Demo mode only: stop a glide where it is, as the real hands do on "stop".
    func freezeSimulatedPointer() {
        guard mode == .simulated else { return }
        activeGlide = nil
    }

    private func poll() {
        switch mode {
        case .realPointer:
            let current = NSEvent.mouseLocation
            if current != location { location = current }
        case .simulated:
            guard let glide = activeGlide else { return }
            let progress = Date().timeIntervalSince(glide.startedAt) / glide.seconds
            let eased = OverlayGeometry.smoothstep(progress)
            location = CGPoint(
                x: glide.start.x + (glide.end.x - glide.start.x) * eased,
                y: glide.start.y + (glide.end.y - glide.start.y) * eased)
            if progress >= 1 { activeGlide = nil }
        }
    }

    /// The user's pointer size from Accessibility > Display (1 is normal, up to 4).
    /// People with low vision often enlarge it; the companion moves out of its way.
    static func systemCursorScale() -> CGFloat {
        let value = UserDefaults(suiteName: "com.apple.universalaccess")?.double(forKey: "mouseDriverCursorSize") ?? 0
        return value > 0 ? CGFloat(value) : 1
    }
}
