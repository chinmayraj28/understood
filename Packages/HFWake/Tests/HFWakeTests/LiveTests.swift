import AVFoundation
import Foundation
import HFCore
import Speech
import Testing

@testable import HFWake

// Live tests: the real on-device recogniser on this Mac.
//
//     HF_LIVE=1 swift test --filter Live
//
// The replay tests need no microphone, no permission and play no sound: the phrase is written to
// a file with `say -o` and fed to SpeechAnalyzer at normal speed. The microphone tests skip with a
// reason unless the host app (the terminal, e.g. Orca) has the Microphone permission; take the
// live lock first (`scripts/live_lock.sh acquire wake`) because they open the microphone.
// HF_LIVE_SPEAKER=1 also plays "Hey Handsfree" through the speakers once, at a moderate volume.

private let live = ProcessInfo.processInfo.environment["HF_LIVE"] == "1"
private let speakerAllowed = ProcessInfo.processInfo.environment["HF_LIVE_SPEAKER"] == "1"

/// Writes `text` as speech to a temporary sound file. Nothing is played.
private func speechFile(_ text: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("hf-wake-live-\(UUID().uuidString).aiff")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    process.arguments = ["-o", url.path, text]
    try process.run()
    process.waitUntilExit()
    return url
}

private func recogniserAvailable() -> Bool {
    if #available(macOS 26.0, *) { return SpeechTranscriber.isAvailable }
    return false
}

/// Waits for one wake, or nil after `seconds`.
private func firstWake(of listener: WakeListener, within seconds: Double) async throws -> String? {
    let woke = Locked<String?>(nil)
    try await listener.start { rest in woke.value = rest }
    _ = await eventually(timeout: seconds) { woke.value != nil }
    await listener.stop()
    return woke.value
}

@Suite(.serialized, .enabled(if: live, "set HF_LIVE=1 to use the real recogniser"))
struct LiveReplayTests {
    @Test func aSpokenPhraseWakesThroughTheRealRecogniser() async throws {
        guard recogniserAvailable() else { try Test.cancel("SpeechAnalyzer isn't available on this Mac") }
        let file = try speechFile("Hey Handsfree, open Spotify")
        defer { try? FileManager.default.removeItem(at: file) }
        let listener = WakeListener(configuration: .init(), replaying: file)
        let rest = try await firstWake(of: listener, within: 10)
        #expect(rest?.lowercased() == "open spotify")
    }

    @Test func aBarePhraseWakesWithNothingAfterIt() async throws {
        guard recogniserAvailable() else { try Test.cancel("SpeechAnalyzer isn't available on this Mac") }
        let file = try speechFile("Hey Handsfree")
        defer { try? FileManager.default.removeItem(at: file) }
        let listener = WakeListener(configuration: .init(), replaying: file)
        #expect(try await firstWake(of: listener, within: 10) == "")
    }

    @Test func ordinarySpeechWithTheNameDoesNotWake() async throws {
        guard recogniserAvailable() else { try Test.cancel("SpeechAnalyzer isn't available on this Mac") }
        let file = try speechFile("I use hands free in the car, it is much safer")
        defer { try? FileManager.default.removeItem(at: file) }
        let listener = WakeListener(configuration: .init(), replaying: file)
        #expect(try await firstWake(of: listener, within: 9) == nil)
    }

    @Test func listeningResumesAfterStopAndStart() async throws {
        guard recogniserAvailable() else { try Test.cancel("SpeechAnalyzer isn't available on this Mac") }
        let file = try speechFile("Hey Handsfree, open Mail")
        defer { try? FileManager.default.removeItem(at: file) }
        let listener = WakeListener(configuration: .init(), replaying: file)
        for round in 1...3 {
            let rest = try await firstWake(of: listener, within: 10)
            #expect(rest?.lowercased() == "open mail", "round \(round)")
        }
    }

    @Test func aDifferentPhraseCanBeConfigured() async throws {
        guard recogniserAvailable() else { try Test.cancel("SpeechAnalyzer isn't available on this Mac") }
        let file = try speechFile("Okay computer, what's the time")
        defer { try? FileManager.default.removeItem(at: file) }
        let listener = WakeListener(configuration: .init(phrase: "Okay Computer"), replaying: file)
        let rest = try await firstWake(of: listener, within: 10)
        #expect(rest?.lowercased().hasPrefix("what") == true)
    }
}

@Suite(.serialized, .enabled(if: live, "set HF_LIVE=1 to use the real microphone"))
struct LiveMicrophoneTests {
    private func requireMicrophone() throws {
        let state = WakePermissions.microphone
        guard state == .granted else {
            try Test.cancel("the Microphone permission for the terminal's host app is \(state.rawValue); grant it to run this")
        }
    }

    @Test func stopReleasesTheMicrophoneForAVoiceProcessingEngineAndListeningResumes() async throws {
        try requireMicrophone()
        guard recogniserAvailable() else { try Test.cancel("SpeechAnalyzer isn't available on this Mac") }
        let listener = WakeListener()
        try await listener.start { _ in }
        #expect(listener.isListening)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let stopStarted = Date()
        await listener.stop()
        #expect(!listener.isListening)
        #expect(Date().timeIntervalSince(stopStarted) < 1.0, "stop must release the microphone promptly")

        // What the ElevenLabs SDK does when the conversation opens: voice processing on the input.
        let engine = AVAudioEngine()
        try engine.inputNode.setVoiceProcessingEnabled(true)
        let buffers = Locked(0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: engine.inputNode.outputFormat(forBus: 0)) { _, _ in
            buffers.update { $0 += 1 }
        }
        engine.prepare()
        try engine.start()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try engine.inputNode.setVoiceProcessingEnabled(false)
        #expect(buffers.value > 5, "the voice-processing engine got the microphone")

        try await listener.start { _ in }
        #expect(listener.isListening)
        await listener.stop()
    }

    @Test(.enabled(if: speakerAllowed, "HF_LIVE_SPEAKER=1 plays the phrase through the speakers"))
    func thePhrasePlayedAloudWakesIt() async throws {
        try requireMicrophone()
        let listener = WakeListener()
        let woke = Locked<String?>(nil)
        try await listener.start { rest in woke.value = rest }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["[[volm 0.45]] Hey Handsfree, open Spotify"]
        try say.run()
        say.waitUntilExit()
        _ = await eventually(timeout: 6) { woke.value != nil }
        await listener.stop()
        #expect(woke.value?.lowercased() == "open spotify")
    }
}
