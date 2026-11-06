import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import HFCore
import ImageIO
import Testing

@testable import HFEyes

/// Tests against the real Mac. Run with `HF_LIVE=1 swift test`. Read-only: nothing is clicked or typed.
/// Each one is skipped, with the reason shown, when its macOS permission is missing.
enum Live {
    static let enabled = ProcessInfo.processInfo.environment["HF_LIVE"] == "1"
    static let canCapture = enabled && CGPreflightScreenCaptureAccess()
    static let canRead = enabled && AXIsProcessTrusted()

    /// Chrome's web accessibility switch, read only; nil when Chrome is not running.
    static func chromeEnhancedUserInterface() -> Bool? {
        guard let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first
        else { return nil }
        var value: AnyObject?
        let app = AXUIElementCreateApplication(chrome.processIdentifier)
        guard AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }
}

@Suite(.serialized) struct LiveEyesTests {
    @Test(.enabled(if: Live.canCapture, "needs HF_LIVE=1 and the Screen Recording permission for the terminal app"))
    func realFullScreenGrabHasTheRightSizeAndMapping() async throws {
        let eyes = ScreenEyes()
        let screen = eyes.screenSize
        let start = Date()
        let shot = try await eyes.grab(maxLongEdge: 1280)
        let seconds = Date().timeIntervalSince(start)

        #expect(shot.screenRect == CGRect(origin: .zero, size: screen))
        #expect(max(shot.pixelWidth, shot.pixelHeight) == min(1280, Int(max(screen.width, screen.height) * ScreenEyes.mainDisplayScale)))
        // The aspect ratio survives to within one pixel of rounding.
        let expectedHeight = Double(shot.pixelWidth) * screen.height / screen.width
        #expect(abs(Double(shot.pixelHeight) - expectedHeight) <= 1)

        // The PNG really is that size.
        let source = try #require(CGImageSourceCreateWithData(shot.png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == shot.pixelWidth && image.height == shot.pixelHeight)

        // Image corners map to screen corners.
        #expect(shot.screenPoint(imageX: 0, imageY: 0) == .zero)
        let corner = shot.screenPoint(imageX: Double(shot.pixelWidth), imageY: Double(shot.pixelHeight))
        #expect(abs(corner.x - screen.width) < 1e-6 && abs(corner.y - screen.height) < 1e-6)
        #expect(seconds < 2.0)  // a cold first grab; warm grabs measured at 75 to 105 ms
    }

    @Test(.enabled(if: Live.canCapture, "needs HF_LIVE=1 and the Screen Recording permission for the terminal app"))
    func realRegionGrabIsAtFullRetinaDetail() async throws {
        let eyes = ScreenEyes()
        let region = CGRect(x: 100, y: 100, width: 300, height: 100)
        let shot = try await eyes.grab(region: region, maxLongEdge: 2000)
        let scale = ScreenEyes.mainDisplayScale
        #expect(shot.screenRect == region)
        #expect(shot.pixelWidth == Int(300 * scale) && shot.pixelHeight == Int(100 * scale))
        #expect(shot.screenPoint(imageX: Double(shot.pixelWidth) / 2, imageY: Double(shot.pixelHeight) / 2)
            == CGPoint(x: 250, y: 150))
    }

    @Test(.enabled(if: Live.canRead, "needs HF_LIVE=1 and the Accessibility permission for the terminal app"))
    func realLookupsNameTheMenuBarAndTheFrontApp() async {
        let labels = AccessibilityLabels()
        let front = await labels.frontmost()
        #expect(!front.app.isEmpty)

        // The Apple menu sits at the top left of every menu bar.
        let start = Date()
        let info = await labels.element(at: CGPoint(x: 18, y: 10))
        let took = Date().timeIntervalSince(start)
        #expect(info?.role == .menuBarItem, "got: \(String(describing: info))")
        #expect(info?.label == "Apple")
        #expect(info.map { $0.frame.contains(CGPoint(x: 18, y: 10)) } == true)
        #expect(took < 0.4)

        let action = await labels.clickAction(at: CGPoint(x: 18, y: 10))
        #expect(action.description.hasPrefix("Click menu bar item \"Apple\" in "))

        // A key press always yields a description, known target or not.
        #expect(await labels.keyAction(KeyChord(key: "return")).description.hasPrefix("Press Return in "))
    }

    @Test(.enabled(if: Live.canRead, "needs HF_LIVE=1 and the Accessibility permission for the terminal app"))
    func creatingTheRealLabelsChangesNoBrowser() async {
        // Fix from review: creating the labels must not switch on web accessibility in Chrome.
        let before = Live.chromeEnhancedUserInterface()
        _ = AccessibilityLabels()
        _ = await AccessibilityLabels().element(at: CGPoint(x: 18, y: 10))
        #expect(Live.chromeEnhancedUserInterface() == before)
    }

    @Test(.enabled(if: Live.canRead, "needs HF_LIVE=1 and the Accessibility permission for the terminal app"))
    func realVisibleControlsAreListedQuickly() async {
        let start = Date()
        let controls = await AccessibilityLabels().visibleControls(limit: 200)
        #expect(Date().timeIntervalSince(start) < 2.5)
        for control in controls {
            #expect(!control.app.isEmpty)
            #expect(control.frame.width >= 0 && control.frame.height >= 0)
        }
    }
}
