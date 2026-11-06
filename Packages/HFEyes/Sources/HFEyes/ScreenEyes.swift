import CoreGraphics
import Foundation
import HFCore
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import os

/// The agent's eyes: screenshots of the main display, scaled for the model.
///
/// Uses ScreenCaptureKit (`SCScreenshotManager`), the supported capture API on macOS 14 and
/// later; the older `CGWindowListCreateImage` is obsolete from macOS 15.
///
/// Windows that must not be seen by the model (the app's own overlay companion, its menu bar
/// panel) are left out of the capture by ScreenCaptureKit itself, so the pixels under them are
/// the user's real content. By default every window of this process is left out; more can be
/// added by window number or by the owning app's bundle identifier.
///
/// Needs the Screen Recording permission. Without it every grab throws a SpeakableError.
public final class ScreenEyes: Eyes, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.handsfree", category: "HFEyes")
    private let lock = NSLock()
    private var excludedWindowIDs: Set<CGWindowID>
    private let excludedBundleIdentifiers: Set<String>
    private let excludeOwnProcess: Bool
    private let showsCursor: Bool
    private var breakdown = GrabTimings()

    /// How long the parts of the last grab took, in milliseconds. For measuring.
    public struct GrabTimings: Sendable {
        public var listWindows = 0.0
        public var capture = 0.0
        public var encode = 0.0
    }

    /// The timings of the most recent grab.
    public var lastGrabTimings: GrabTimings {
        lock.lock()
        defer { lock.unlock() }
        return breakdown
    }

    /// - Parameters:
    ///   - excludedWindowIDs: window numbers to leave out (`NSWindow.windowNumber`).
    ///   - excludedBundleIdentifiers: apps whose every window is left out.
    ///   - excludeOwnProcess: leave out every window of this process (the overlay). Default true.
    ///   - showsCursor: draw the pointer into the image. Default false: the model is told where
    ///     the pointer is when it matters, and a drawn cursor can hide a small control.
    public init(
        excludedWindowIDs: Set<CGWindowID> = [],
        excludedBundleIdentifiers: Set<String> = [],
        excludeOwnProcess: Bool = true,
        showsCursor: Bool = false
    ) {
        self.excludedWindowIDs = excludedWindowIDs
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
        self.excludeOwnProcess = excludeOwnProcess
        self.showsCursor = showsCursor
    }

    /// Replaces the set of window numbers to leave out, for windows created after start-up.
    public func setExcludedWindowIDs(_ ids: Set<CGWindowID>) {
        lock.lock()
        excludedWindowIDs = ids
        lock.unlock()
    }

    /// True when this process may capture the screen. Never prompts or changes a setting.
    public static var hasScreenRecordingPermission: Bool { CGPreflightScreenCaptureAccess() }

    static let permissionMessage =
        "I need the Screen Recording permission to see the screen. Please allow it in System Settings, under Privacy and Security."

    /// The main display's size in points.
    public var screenSize: CGSize { CGDisplayBounds(CGMainDisplayID()).size }

    /// Backing pixels per point on the main display (2 on a Retina panel).
    public static var mainDisplayScale: CGFloat {
        let displayID = CGMainDisplayID()
        let points = CGDisplayBounds(displayID).width
        guard points > 0, let mode = CGDisplayCopyDisplayMode(displayID) else { return 1 }
        return CGFloat(mode.pixelWidth) / points
    }

    public func grab(maxLongEdge: Int) async throws -> Shot {
        try await grab(region: CGRect(origin: .zero, size: screenSize), maxLongEdge: maxLongEdge)
    }

    public func grab(region: CGRect, maxLongEdge: Int) async throws -> Shot {
        guard Self.hasScreenRecordingPermission else { throw SpeakableError(Self.permissionMessage) }
        let displayID = CGMainDisplayID()
        let plan = try CapturePlan.make(
            region: region, displaySize: CGDisplayBounds(displayID).size,
            backingScale: Self.mainDisplayScale, maxLongEdge: maxLongEdge)

        var timings = GrabTimings()
        var started = Date()
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            logger.error("shareable content failed: \(error.localizedDescription, privacy: .public)")
            throw Self.speakable(error)
        }
        timings.listWindows = Date().timeIntervalSince(started) * 1000
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw SpeakableError("I can't find the main display.")
        }
        let filter = SCContentFilter(display: display, excludingWindows: windowsToExclude(content.windows))
        let configuration = SCStreamConfiguration()
        // sourceRect is in the display's own points, origin top left: the same space as the plan.
        configuration.sourceRect = plan.screenRect
        configuration.width = plan.pixelWidth
        configuration.height = plan.pixelHeight
        configuration.showsCursor = showsCursor
        configuration.scalesToFit = false
        if #available(macOS 14.2, *) { configuration.captureResolution = .best }

        started = Date()
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            logger.error("capture failed: \(error.localizedDescription, privacy: .public)")
            throw Self.speakable(error)
        }
        timings.capture = Date().timeIntervalSince(started) * 1000
        guard image.width == plan.pixelWidth, image.height == plan.pixelHeight else {
            // The mapping in Shot depends on the image being exactly the planned size.
            logger.error("capture size \(image.width)x\(image.height) differs from plan \(plan.pixelWidth)x\(plan.pixelHeight)")
            throw SpeakableError("The screenshot came out the wrong size, so I can't trust where things are.")
        }
        started = Date()
        guard let png = Self.pngData(image) else { throw SpeakableError("I couldn't save the screenshot.") }
        timings.encode = Date().timeIntervalSince(started) * 1000
        record(timings)
        return plan.shot(png: png)
    }

    private func record(_ timings: GrabTimings) {
        lock.lock()
        breakdown = timings
        lock.unlock()
    }

    /// The windows to leave out of this capture.
    func windowsToExclude(_ windows: [SCWindow]) -> [SCWindow] {
        lock.lock()
        let ids = excludedWindowIDs
        lock.unlock()
        let ownPID = getpid()
        return windows.filter { window in
            if ids.contains(window.windowID) { return true }
            guard let owner = window.owningApplication else { return false }
            if excludeOwnProcess && owner.processID == ownPID { return true }
            return excludedBundleIdentifiers.contains(owner.bundleIdentifier)
        }
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func speakable(_ error: Error) -> SpeakableError {
        let code = (error as NSError).code
        // SCStreamError.userDeclined (-3801): the permission is missing or was turned off.
        if code == SCStreamError.Code.userDeclined.rawValue || !hasScreenRecordingPermission {
            return SpeakableError(permissionMessage)
        }
        return SpeakableError("I couldn't take a screenshot just now.")
    }
}
