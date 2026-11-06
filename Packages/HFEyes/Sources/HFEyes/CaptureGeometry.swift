import CoreGraphics
import Foundation
import HFCore

/// The arithmetic of a screenshot, kept apart from ScreenCaptureKit so it can be tested
/// at any display scale.
///
/// Three sizes are in play on a Retina Mac and they must not be mixed up:
/// - screen POINTS: what the pointer, the accessibility API and every HFCore contract use
///   (origin top left of the main display);
/// - BACKING PIXELS: what the panel really has (points times the scale factor, 2 on this Mac);
/// - IMAGE PIXELS: the scaled picture the model sees.
///
/// A capture plan says which rectangle of the screen, in points, the image shows, and how many
/// image pixels wide and high the image is. `Shot` then maps image pixels to points by simple
/// proportion on each axis, which is exact because the image is that rectangle stretched to
/// exactly that many pixels.
public struct CapturePlan: Equatable, Sendable {
    /// The part of the screen the image shows, in points, top-left origin.
    public let screenRect: CGRect
    /// The size of the image to produce.
    public let pixelWidth: Int
    public let pixelHeight: Int

    /// Plans a capture of `region` (points) of a display `displaySize` points big whose
    /// backing store has `backingScale` pixels per point, with the image's long edge at most
    /// `maxLongEdge` pixels.
    ///
    /// - The region is clipped to the display.
    /// - The image is never larger than the display's real pixels for that region: asking for
    ///   more detail than the panel has would only blur the picture.
    /// - Throws a SpeakableError when the region lies entirely off the display or is empty.
    public static func make(
        region: CGRect, displaySize: CGSize, backingScale: CGFloat, maxLongEdge: Int
    ) throws -> CapturePlan {
        let display = CGRect(origin: .zero, size: displaySize)
        let clipped = region.standardized.intersection(display)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else {
            throw SpeakableError("That part of the screen is outside the display.")
        }
        let longEdgePoints = max(clipped.width, clipped.height)
        let nativeLongEdgePixels = longEdgePoints * max(backingScale, 1)
        let targetLongEdge = min(CGFloat(max(maxLongEdge, 16)), nativeLongEdgePixels)
        let pixelsPerPoint = targetLongEdge / longEdgePoints
        let width = max(1, Int((clipped.width * pixelsPerPoint).rounded()))
        let height = max(1, Int((clipped.height * pixelsPerPoint).rounded()))
        return CapturePlan(screenRect: clipped, pixelWidth: width, pixelHeight: height)
    }

    public init(screenRect: CGRect, pixelWidth: Int, pixelHeight: Int) {
        self.screenRect = screenRect
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// The Shot for this plan once its image is encoded.
    public func shot(png: Data) -> Shot {
        Shot(png: png, pixelWidth: pixelWidth, pixelHeight: pixelHeight, screenRect: screenRect)
    }
}
