import CoreGraphics
import Foundation
import HFCore
import Testing

@testable import HFEyes

/// The mapping from image pixels to screen points must be exact, or every click misses.

@Test(arguments: [
    // (display points, backing scale, long edge asked, expected image size)
    (CGSize(width: 1470, height: 956), 2.0, 1280, (1280, 832)),  // Retina, "more space"
    (CGSize(width: 1280, height: 832), 2.0, 1280, (1280, 832)),  // Retina, default (this Mac)
    (CGSize(width: 1920, height: 1080), 1.0, 1280, (1280, 720)),  // ordinary external display
    (CGSize(width: 1512, height: 982), 3.0, 1568, (1568, 1018)),  // a hypothetical 3x panel
    (CGSize(width: 800, height: 600), 1.0, 1280, (800, 600)),  // never upscaled past real pixels
])
func fullScreenPlanFitsTheLongEdgeAndShowsTheWholeScreen(
    display: CGSize, scale: Double, maxLongEdge: Int, expected: (Int, Int)
) throws {
    let plan = try CapturePlan.make(
        region: CGRect(origin: .zero, size: display), displaySize: display, backingScale: scale,
        maxLongEdge: maxLongEdge)
    #expect(plan.pixelWidth == expected.0)
    #expect(plan.pixelHeight == expected.1)
    #expect(plan.screenRect == CGRect(origin: .zero, size: display))

    // The image's corners and centre land exactly on the screen's.
    let shot = plan.shot(png: Data())
    #expect(shot.screenPoint(imageX: 0, imageY: 0) == .zero)
    let corner = shot.screenPoint(imageX: Double(plan.pixelWidth), imageY: Double(plan.pixelHeight))
    #expect(abs(corner.x - display.width) < 1e-9 && abs(corner.y - display.height) < 1e-9)
    let centre = shot.screenPoint(imageX: Double(plan.pixelWidth) / 2, imageY: Double(plan.pixelHeight) / 2)
    #expect(abs(centre.x - display.width / 2) < 1e-9 && abs(centre.y - display.height / 2) < 1e-9)
}

@Test func retinaRegionGetsFullDetailAndKeepsItsOffset() throws {
    // A 300x100 point region on a 2x display: 600x200 real pixels, so a 1280 limit gives 600x200.
    let plan = try CapturePlan.make(
        region: CGRect(x: 1000, y: 700, width: 300, height: 100),
        displaySize: CGSize(width: 1470, height: 956), backingScale: 2, maxLongEdge: 1280)
    #expect(plan.pixelWidth == 600 && plan.pixelHeight == 200)
    let shot = plan.shot(png: Data())
    #expect(shot.screenPoint(imageX: 0, imageY: 0) == CGPoint(x: 1000, y: 700))
    #expect(shot.screenPoint(imageX: 300, imageY: 100) == CGPoint(x: 1150, y: 750))
}

@Test func regionIsClippedToTheDisplay() throws {
    let display = CGSize(width: 1280, height: 832)
    let plan = try CapturePlan.make(
        region: CGRect(x: 1200, y: -50, width: 400, height: 200), displaySize: display, backingScale: 2,
        maxLongEdge: 2000)
    #expect(plan.screenRect == CGRect(x: 1200, y: 0, width: 80, height: 150))
    #expect(plan.pixelWidth == 160 && plan.pixelHeight == 300)  // 2 pixels per point, under the limit
}

@Test func regionOffTheDisplayOrEmptyIsASpeakableError() {
    let display = CGSize(width: 1280, height: 832)
    #expect(throws: SpeakableError.self) {
        try CapturePlan.make(
            region: CGRect(x: 5000, y: 5000, width: 10, height: 10), displaySize: display, backingScale: 2,
            maxLongEdge: 1280)
    }
    #expect(throws: SpeakableError.self) {
        try CapturePlan.make(
            region: CGRect(x: 10, y: 10, width: 0, height: 50), displaySize: display, backingScale: 2,
            maxLongEdge: 1280)
    }
}

@Test func roundingToWholePixelsKeepsEachAxisExact() throws {
    // 1470/956 does not scale to whole pixels evenly; each axis is mapped by its own ratio.
    let plan = try CapturePlan.make(
        region: CGRect(x: 0, y: 0, width: 1470, height: 956), displaySize: CGSize(width: 1470, height: 956),
        backingScale: 2, maxLongEdge: 1000)
    #expect(plan.pixelWidth == 1000 && plan.pixelHeight == 650)
    let shot = plan.shot(png: Data())
    let bottomRight = shot.screenPoint(imageX: 1000, imageY: 650)
    #expect(bottomRight == CGPoint(x: 1470, y: 956))
    // A pixel in the middle maps to the matching proportion of the screen on each axis.
    let point = shot.screenPoint(imageX: 250, imageY: 325)
    #expect(abs(point.x - 367.5) < 1e-9 && abs(point.y - 478) < 1e-9)
}

@Test func tinyLimitsAreRaisedToAUsableMinimum() throws {
    let plan = try CapturePlan.make(
        region: CGRect(x: 0, y: 0, width: 1280, height: 832), displaySize: CGSize(width: 1280, height: 832),
        backingScale: 2, maxLongEdge: 0)
    #expect(plan.pixelWidth == 16)
}
