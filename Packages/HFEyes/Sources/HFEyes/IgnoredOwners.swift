import AppKit
import CoreGraphics
import Foundation

/// Processes whose windows the labels look through: Handsfree's own overlay, menu bar panel and
/// any demo backdrop. The model never sees them (ScreenEyes leaves them out of screenshots), so
/// the labels must not name them either, or the gate would judge a click against our own window.
public struct IgnoredOwners: Sendable, Equatable {
    public var processIDs: Set<pid_t>
    public var bundleIdentifiers: Set<String>

    /// The Handsfree app's bundle identifier.
    public static let handsfreeBundleIdentifier = "com.handsfree.Handsfree"

    /// This process plus the Handsfree app. A tool or test (another process) still looks through
    /// the app's windows; the app itself is covered by its own process id as well.
    public static var `default`: IgnoredOwners {
        IgnoredOwners(processIDs: [getpid()], bundleIdentifiers: [handsfreeBundleIdentifier])
    }

    public init(processIDs: Set<pid_t> = [], bundleIdentifiers: Set<String> = []) {
        self.processIDs = processIDs
        self.bundleIdentifiers = bundleIdentifiers
    }

    public func contains(_ processID: pid_t) -> Bool {
        if processIDs.contains(processID) { return true }
        guard !bundleIdentifiers.isEmpty, let bundle = NSRunningApplication(processIdentifier: processID)?.bundleIdentifier
        else { return false }
        return bundleIdentifiers.contains(bundle)
    }
}

/// One on-screen window, as the window server lists it (front to back).
public struct ScreenWindow: Sendable, Equatable {
    public var processID: pid_t
    public var ownerName: String
    /// Screen points, top-left origin.
    public var frame: CGRect
    public var layer: Int
    public var alpha: Double

    public init(processID: pid_t, ownerName: String, frame: CGRect, layer: Int = 0, alpha: Double = 1) {
        self.processID = processID
        self.ownerName = ownerName
        self.frame = frame
        self.layer = layer
        self.alpha = alpha
    }

    /// Every on-screen window, frontmost first. Read-only; no Screen Recording needed for these fields.
    public static func onScreen() -> [ScreenWindow] {
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let pid = row[kCGWindowOwnerPID as String] as? pid_t,
                let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: bounds)
            else { return nil }
            return ScreenWindow(
                processID: pid, ownerName: row[kCGWindowOwnerName as String] as? String ?? "", frame: frame,
                layer: row[kCGWindowLayer as String] as? Int ?? 0, alpha: row[kCGWindowAlpha as String] as? Double ?? 1)
        }
    }
}

/// Finds the control at a point while looking through ignored windows. Pure logic over injected
/// lookups, so it is tested with a fake window list.
public enum PointResolver {
    /// Processes whose windows contain the point, frontmost first, without ignored ones, invisible
    /// windows or the window server's own (the menu bar strip, the cursor), each once.
    public static func candidateProcesses(
        at point: CGPoint, windows: [ScreenWindow], isIgnored: (pid_t) -> Bool
    ) -> [pid_t] {
        var seen = Set<pid_t>()
        var result: [pid_t] = []
        for window in windows where window.frame.contains(point) && window.alpha > 0 {
            if window.ownerName == "Window Server" || isIgnored(window.processID) { continue }
            if seen.insert(window.processID).inserted { result.append(window.processID) }
        }
        return result
    }

    /// The hit at a point that does not belong to an ignored owner.
    ///
    /// 1. The ordinary system-wide hit test, kept when its owner is not ignored (the usual case,
    ///    no extra cost).
    /// 2. Otherwise the TOPMOST window under the point that is not ours decides. Its app is asked
    ///    for the control at the point within that app only. If it does not answer (a password
    ///    prompt that exposes nothing to accessibility), the result is `placeholder` for that
    ///    window: an unnamed element OF THAT APP. It never falls through to a window beneath,
    ///    because the click would land on the top window, not on the one beneath.
    /// 3. When only the window server's own strips are there (the menu bar), the front app that is
    ///    not ignored is asked: menu bar items belong to it.
    /// Nil when nothing but ignored windows is there: the gate then treats the target as unknown.
    public static func resolve<Hit>(
        at point: CGPoint,
        systemWideHit: () -> Hit?,
        owner: (Hit) -> pid_t,
        isIgnored: (pid_t) -> Bool,
        windows: () -> [ScreenWindow],
        hitInApp: (pid_t) -> Hit?,
        placeholder: (ScreenWindow) -> Hit?,
        frontApp: () -> pid_t?
    ) -> Hit? {
        if let hit = systemWideHit(), !isIgnored(owner(hit)) { return hit }
        let onScreen = windows()
        if let top = topWindow(at: point, windows: onScreen, isIgnored: isIgnored) {
            if let hit = hitInApp(top.processID), !isIgnored(owner(hit)) { return hit }
            return placeholder(top)
        }
        if let front = frontApp(), !isIgnored(front), let hit = hitInApp(front), !isIgnored(owner(hit)) {
            return hit
        }
        return nil
    }

    /// The topmost visible window under the point that is neither ours nor the window server's.
    public static func topWindow(at point: CGPoint, windows: [ScreenWindow], isIgnored: (pid_t) -> Bool) -> ScreenWindow? {
        windows.first {
            $0.frame.contains(point) && $0.alpha > 0 && $0.ownerName != "Window Server" && !isIgnored($0.processID)
        }
    }
}
