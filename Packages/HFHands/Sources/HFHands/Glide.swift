import CoreGraphics
import Foundation

/// How the pointer travels: a straight line with a minimum-jerk speed profile
/// (slow start, quick middle, gentle landing), which is how a person's hand
/// moves a mouse and is easy for someone watching to follow.
enum Glide {
    /// About 120 positions a second: smooth on screen, and the stop flag is
    /// checked between every one of them.
    static let stepInterval: TimeInterval = 1.0 / 120.0

    /// Duration grows with the logarithm of the distance, like human pointing
    /// (Fitts's law): 10 pt takes about 0.2 s, 100 pt 0.37 s, 500 pt 0.6 s and
    /// a full screen width about 0.8 s. Capped so long moves never drag on.
    static func duration(forDistance distance: CGFloat) -> TimeInterval {
        guard distance >= 1 else { return 0 }
        let seconds = 0.15 + 0.12 * log2(1 + Double(distance) / 40)
        return min(1.0, max(0.12, seconds))
    }

    /// Minimum-jerk easing: 10t³ − 15t⁴ + 6t⁵. Starts and ends at rest.
    static func ease(_ progress: Double) -> Double {
        let clamped = min(1, max(0, progress))
        return clamped * clamped * clamped * (10 + clamped * (-15 + 6 * clamped))
    }

    /// The intermediate positions of a glide, ending exactly on `end`.
    static func path(from start: CGPoint, to end: CGPoint, duration: TimeInterval) -> [CGPoint] {
        let steps = max(1, Int((duration / stepInterval).rounded()))
        var points: [CGPoint] = []
        points.reserveCapacity(steps)
        for step in 1...steps {
            if step == steps {
                points.append(end)
                break
            }
            let fraction = ease(Double(step) / Double(steps))
            points.append(CGPoint(
                x: start.x + (end.x - start.x) * fraction,
                y: start.y + (end.y - start.y) * fraction))
        }
        return points
    }

    static func distance(_ start: CGPoint, _ end: CGPoint) -> CGFloat {
        hypot(end.x - start.x, end.y - start.y)
    }
}
