//
//  PalettePNG.swift
//  Handsfree
//
//  Writes an image as a 256-colour PNG, for the review renders that are kept
//  in docs/. Flat interface pictures need few colours, and a palette PNG is
//  about a third of the size of a full-colour one with no visible change.
//  (No PNG optimiser is installed on the build Mac, so this is done here.)
//  Colours are chosen by median cut: the set of colours in the picture is
//  split, again and again, across its widest channel, until there are 256
//  groups; each group's average becomes one palette entry. Design review only.
//  New for Handsfree.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PalettePNG {

    /// Writes `image` (opaque; any transparency is dropped) to `url`. Returns false on failure.
    static func write(_ image: CGImage, to url: URL, colours: Int = 256) -> Bool {
        let width = image.width
        let height = image.height
        guard let pixels = rgbPixels(of: image) else { return false }

        // Each distinct colour and how often it appears.
        var counts: [UInt32: Int] = [:]
        for pixel in pixels { counts[pixel, default: 0] += 1 }
        let palette = medianCut(counts.map { ($0.key, $0.value) }, into: colours)

        // Map each distinct colour to its nearest palette entry once, then every pixel.
        var lookup: [UInt32: UInt8] = [:]
        lookup.reserveCapacity(counts.count)
        for colour in counts.keys { lookup[colour] = nearest(colour, in: palette) }
        var indices = [UInt8](repeating: 0, count: width * height)
        for (offset, pixel) in pixels.enumerated() { indices[offset] = lookup[pixel] ?? 0 }

        var table = [UInt8]()
        for entry in palette { table += [UInt8(entry >> 16 & 0xFF), UInt8(entry >> 8 & 0xFF), UInt8(entry & 0xFF)] }
        guard let base = CGColorSpace(name: CGColorSpace.sRGB),
            let space = CGColorSpace(indexedBaseSpace: base, last: palette.count - 1, colorTable: table),
            let provider = CGDataProvider(data: Data(indices) as CFData),
            let indexed = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, indexed, nil)
        return CGImageDestinationFinalize(destination)
    }

    /// The picture as 0xRRGGBB values, drawn onto white so any transparency is resolved.
    private static func rgbPixels(of image: CGImage) -> [UInt32]? {
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 255, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let drawn: Bool = buffer.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var pixels = [UInt32](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            let offset = index * 4
            pixels[index] = UInt32(buffer[offset]) << 16 | UInt32(buffer[offset + 1]) << 8 | UInt32(buffer[offset + 2])
        }
        return pixels
    }

    /// Median cut over weighted colours. Returns up to `count` colours as 0xRRGGBB.
    private static func medianCut(_ colours: [(colour: UInt32, count: Int)], into count: Int) -> [UInt32] {
        func channel(_ colour: UInt32, _ index: Int) -> Int { Int(colour >> UInt32(16 - index * 8) & 0xFF) }

        var boxes: [[(colour: UInt32, count: Int)]] = [colours]
        while boxes.count < count {
            // Split the box whose widest channel, weighted by how many pixels it holds, is largest.
            var best: (box: Int, channel: Int, score: Double)?
            for (boxIndex, box) in boxes.enumerated() where box.count > 1 {
                let pixelsInBox = box.reduce(0) { $0 + $1.count }
                for channelIndex in 0..<3 {
                    let values = box.map { channel($0.colour, channelIndex) }
                    let range = (values.max() ?? 0) - (values.min() ?? 0)
                    let score = Double(range) * Double(pixelsInBox).squareRoot()
                    if range > 0, score > (best?.score ?? 0) { best = (boxIndex, channelIndex, score) }
                }
            }
            guard let best else { break }
            let sorted = boxes[best.box].sorted { channel($0.colour, best.channel) < channel($1.colour, best.channel) }
            let half = sorted.reduce(0) { $0 + $1.count } / 2
            var running = 0
            var split = 1
            for (index, entry) in sorted.enumerated() {
                running += entry.count
                if running >= half { split = min(max(index + 1, 1), sorted.count - 1); break }
            }
            boxes[best.box] = Array(sorted[..<split])
            boxes.append(Array(sorted[split...]))
        }

        return boxes.map { box in
            let total = Double(box.reduce(0) { $0 + $1.count })
            var sums = [0.0, 0.0, 0.0]
            for entry in box {
                for channelIndex in 0..<3 { sums[channelIndex] += Double(channel(entry.colour, channelIndex)) * Double(entry.count) }
            }
            let average = sums.map { UInt32(($0 / total).rounded()) }
            return average[0] << 16 | average[1] << 8 | average[2]
        }
    }

    private static func nearest(_ colour: UInt32, in palette: [UInt32]) -> UInt8 {
        let red = Int(colour >> 16 & 0xFF), green = Int(colour >> 8 & 0xFF), blue = Int(colour & 0xFF)
        var bestIndex = 0
        var bestDistance = Int.max
        for (index, entry) in palette.enumerated() {
            let dr = red - Int(entry >> 16 & 0xFF), dg = green - Int(entry >> 8 & 0xFF), db = blue - Int(entry & 0xFF)
            // Weighted towards green, as the eye is most sensitive to it.
            let distance = 2 * dr * dr + 4 * dg * dg + 3 * db * db
            if distance < bestDistance { bestDistance = distance; bestIndex = index }
        }
        return UInt8(bestIndex)
    }
}
