import AppKit
import CoreGraphics
import Foundation
import HFCore
import Testing
@testable import HFScreenAgent

// Live tests: real calls to the Anthropic API, run only with HF_LIVE=1.
// They never touch the real screen, pointer or keyboard: the "screen" is a
// picture drawn below, and the hands are fakes that only record.
//
//   cd Packages/HFScreenAgent && HF_LIVE=1 swift test --filter Live

private let isLive = ProcessInfo.processInfo.environment["HF_LIVE"] == "1"

private func liveClient() throws -> ClaudeClient {
    let settings = Settings.load()
    try #require(!settings.anthropicAPIKey.isEmpty, "ANTHROPIC_API_KEY is not set in .env")
    return ClaudeClient(settings: settings)
}

@Suite("Live", .serialized, .enabled(if: isLive, "set HF_LIVE=1 to call the real API"))
struct LiveTests {
    @Test func oneCheapMessage() async throws {
        let client = try liveClient()
        let response = try await client.createMessage([
            "model": "claude-haiku-5-5", "max_tokens": 16,
            "messages": [["role": "user", "content": "Reply with the single word OK."]],
        ])
        let text = response["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        #expect(text.uppercased().contains("OK"))
    }

    @Test func structuredExtraction() async throws {
        let client = try liveClient()
        let schema: JSONValue = [
            "type": "object",
            "properties": ["contact": ["type": "string"], "app": ["type": "string"]],
            "required": ["contact", "app"], "additionalProperties": false,
        ]
        let result = try await client.extract(
            instructions: "Extract who the user chose and in which app.",
            input: "Assistant: Priya Shah or Priya Patel on WhatsApp? User: Shah.",
            schema: schema
        )
        #expect(result["contact"]?.stringValue?.contains("Shah") == true)
        #expect(result["app"]?.stringValue?.lowercased().contains("whatsapp") == true)
    }

    /// Runs the real agent loop with real Claude on a drawn chat window, for each
    /// candidate model. Checks the click lands on Send, that the backstop asks
    /// about it, and prints seconds per turn.
    @Test(arguments: ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"])
    func clicksSendOnDrawnScreen(model: String) async throws {
        let settings = Settings.load()
        try #require(!settings.anthropicAPIKey.isEmpty)
        let screen = DrawnChatScreen()
        let hands = FakeHands()
        let labels = FakeLabels()
        labels.add(screen.sendButtonPoints, .button, "Send")
        let context = FakeContext(goal: "Click the Send button in this chat window. Do nothing else.")
        context.confirmAnswer = false  // the person says no: the agent must not click and must stop
        context.maxSteps = 3
        let agent = ScreenAgent(
            hands: hands, eyes: screen, labels: labels, client: ClaudeClient(settings: settings),
            configuration: ScreenAgentConfiguration(model: model)
        )
        let started = Date()
        var outcome = ""
        do { outcome = try await agent.run(goal: context.goal, context: context) } catch { outcome = "threw: \(error)" }
        let stats = agent.lastRunStats
        print("LIVE \(model): total \(String(format: "%.1f", Date().timeIntervalSince(started)))s, turns \(stats.modelSeconds.map { String(format: "%.1f", $0) }), input \(stats.inputTokens) cached \(stats.cachedInputTokens) output \(stats.outputTokens), confirms \(context.confirms.map(\.description)), outcome: \(outcome)")

        #expect(!context.confirms.isEmpty, "the backstop should have asked about the click")
        #expect(context.confirms.first?.description.contains("\"Send\"") == true, "the click should have targeted Send")
        #expect(hands.presses.isEmpty, "declined, so nothing may be clicked (the glide to Send is allowed)")
    }
}

/// A 1440x900-point "screen" drawn as a 1280x800 image: one chat window with a
/// message field and a Send button, so the model has something real to click.
final class DrawnChatScreen: Eyes, @unchecked Sendable {
    let screenSize = CGSize(width: 1440, height: 900)
    private let pixelSize = CGSize(width: 1280, height: 800)
    /// Where the Send button is, in screen points.
    let sendButtonPoints = CGRect(x: 1215, y: 790, width: 135, height: 54)
    private lazy var png: Data = draw()

    func grab(maxLongEdge: Int) async throws -> Shot {
        Shot(png: png, pixelWidth: Int(pixelSize.width), pixelHeight: Int(pixelSize.height), screenRect: CGRect(origin: .zero, size: screenSize))
    }

    func grab(region: CGRect, maxLongEdge: Int) async throws -> Shot { try await grab(maxLongEdge: maxLongEdge) }

    private func draw() -> Data {
        let scale = pixelSize.width / screenSize.width
        let image = NSImage(size: pixelSize, flipped: true) { _ in
            func rect(_ points: CGRect) -> CGRect {
                CGRect(x: points.minX * scale, y: points.minY * scale, width: points.width * scale, height: points.height * scale)
            }
            func label(_ text: String, _ points: CGRect, size: CGFloat, color: NSColor = .black) {
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size * scale), .foregroundColor: color]
                NSString(string: text).draw(in: rect(points), withAttributes: attributes)
            }
            NSColor(white: 0.85, alpha: 1).setFill()
            NSBezierPath(rect: CGRect(origin: .zero, size: self.pixelSize)).fill()
            NSColor(white: 0.95, alpha: 1).setFill()
            NSBezierPath(rect: rect(CGRect(x: 0, y: 0, width: 1440, height: 28))).fill()
            label("WhatsApp   File   Edit   View   Chat", CGRect(x: 12, y: 5, width: 600, height: 22), size: 14)
            NSColor.white.setFill()
            NSBezierPath(rect: rect(CGRect(x: 80, y: 60, width: 1300, height: 800))).fill()
            label("Amma", CGRect(x: 420, y: 80, width: 400, height: 30), size: 20)
            label("Chats", CGRect(x: 100, y: 80, width: 200, height: 30), size: 20)
            label("Amma", CGRect(x: 100, y: 130, width: 200, height: 24), size: 16)
            label("Priya Shah", CGRect(x: 100, y: 170, width: 200, height: 24), size: 16)
            NSColor(calibratedRed: 0.86, green: 0.97, blue: 0.78, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect(CGRect(x: 900, y: 600, width: 300, height: 44)), xRadius: 8, yRadius: 8).fill()
            label("Are you coming tonight?", CGRect(x: 915, y: 610, width: 280, height: 30), size: 16)
            NSColor(white: 0.93, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect(CGRect(x: 420, y: 795, width: 780, height: 44)), xRadius: 20, yRadius: 20).fill()
            label("running late", CGRect(x: 440, y: 805, width: 500, height: 30), size: 16)
            NSColor(calibratedRed: 0.0, green: 0.6, blue: 0.4, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect(self.sendButtonPoints), xRadius: 12, yRadius: 12).fill()
            label("Send", CGRect(x: 1255, y: 803, width: 100, height: 30), size: 18, color: .white)
            return true
        }
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(pixelSize.width), pixelsHigh: Int(pixelSize.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        bitmap.size = pixelSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: CGRect(origin: .zero, size: pixelSize))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])!
    }
}
