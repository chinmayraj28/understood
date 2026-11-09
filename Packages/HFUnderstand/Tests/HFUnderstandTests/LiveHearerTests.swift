import Foundation
import HFCore
import Testing
@testable import HFUnderstand

// MARK: - Live

/// Real calls, only with HF_LIVE=1. They make a clip with `say` (written to a file, nothing is
/// played), so they need no live lock. Run: HF_LIVE=1 swift test --filter Hearer
// Serialized so each latency is measured alone, not while another hearer is running.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HF_LIVE"] == "1"))
struct LiveHearerTests {
    static let phrase = "message Amma running late"

    /// Speaks a phrase into an AIFF with `say`, converts it with afconvert, loads it as a turn.
    static func makeTurn(_ text: String) throws -> RecordedTurn {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hf-understand-live", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A fresh name each time, so two tests never write the same file.
        // Short, so a long phrase never makes a file name too long.
        let name = String(text.filter { $0.isLetter || $0 == " " }.prefix(24)).replacingOccurrences(of: " ", with: "-")
            + "-" + UUID().uuidString.prefix(8)
        let aiff = folder.appendingPathComponent("\(name).aiff")
        let wav = folder.appendingPathComponent("\(name).wav")
        try run("/usr/bin/say", ["-o", aiff.path, text])
        try run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path])
        defer {
            try? FileManager.default.removeItem(at: aiff)
            try? FileManager.default.removeItem(at: wav)
        }
        return try WAV.load(contentsOf: wav)
    }

    static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SpeakableError("\(tool) failed") }
    }

    static let hints = HearingHints(keyterms: ["Amma", "WhatsApp", "running late"], languageCode: "en-GB")

    static func timed(_ hearer: some Hearing, _ turn: RecordedTurn, hints: HearingHints = hints) async throws -> String {
        let start = Date()
        let text = try await hearer.hear(turn, hints: hints)
        print("LIVE \(hearer.name.rawValue): \"\(text)\" in \(String(format: "%.2f", Date().timeIntervalSince(start))) s for a \(String(format: "%.1f", turn.durationSeconds)) s clip")
        return text
    }

    static func matches(_ text: String) -> Bool {
        text.lowercased().filter { $0.isLetter || $0 == " " } == phrase.lowercased()
    }

    @Test func liveScribeHearer() async throws {
        let turn = try Self.makeTurn(Self.phrase)
        let hearer = ScribeHearer(apiKey: Settings.load().elevenLabsAPIKey)
        let text = try await Self.timed(hearer, turn)
        #expect(Self.matches(text), "\(text)")
        _ = try await Self.timed(hearer, turn)  // a second call, warm
    }

    @Test func liveGeminiHearer() async throws {
        let turn = try Self.makeTurn(Self.phrase)
        let hearer = GeminiHearer(apiKey: Settings.load().openRouterAPIKey)
        let text = try await Self.timed(hearer, turn)
        #expect(Self.matches(text), "\(text)")
        // With two example clips, as the app will send them.
        let examples = try ["open WhatsApp", "scroll down"].map { SpeechExample(wav: try Self.makeTurn($0).wav, text: $0) }
        let withExamples = HearingHints(keyterms: Self.hints.keyterms, examples: examples, languageCode: "en-GB")
        let second = try await Self.timed(hearer, turn, hints: withExamples)
        #expect(Self.matches(second), "\(second)")
    }

    @Test func liveApplePrepareWarmsTheRecogniser() async throws {
        let start = Date()
        try await AppleHearer.prepare(languageCode: "en-GB")
        print("LIVE apple prepare: \(String(format: "%.2f", Date().timeIntervalSince(start))) s")
    }

    @Test func liveAppleStopsWhenCancelledMidway() async throws {
        let long = try Self.makeTurn(String(repeating: "open WhatsApp and message Amma that I am running late. ", count: 6))
        let task = Task { try await AppleHearer().hear(long, hints: Self.hints) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let cancelledAt = Date()
        task.cancel()
        let result = await task.result
        let seconds = Date().timeIntervalSince(cancelledAt)
        print("LIVE apple cancel: stopped \(String(format: "%.2f", seconds)) s after the cancel, on a \(String(format: "%.1f", long.durationSeconds)) s clip; result: \(result)")
        #expect(seconds < 1)
        if case .failure(let error) = result { #expect(error is CancellationError, "got \(error)") }
    }

    @Test func liveAppleHearer() async throws {
        let turn = try Self.makeTurn(Self.phrase)
        let hearer = AppleHearer()
        let text = try await Self.timed(hearer, turn)
        #expect(text.lowercased().contains("running late"), "\(text)")
        _ = try await Self.timed(hearer, turn)  // a second call, model already loaded
    }
}
