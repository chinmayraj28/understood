import Foundation
import HFCore
import Testing

@testable import HFVoice

/// Own listening against the real TEST agent and real ElevenLabs text-to-speech.
/// Run with `HF_LIVE=1 swift test --filter LiveOwnListening`. No microphone is used and no
/// sound is played: the speech is written to a file (HF_SPIKE_DIR, or the temporary folder).
private let isLive = ProcessInfo.processInfo.environment["HF_LIVE"] == "1"

/// Collects what the sink is given, with when the first chunk came.
private final class AudioCatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var audio = Data()
    private var chunks = 0
    private var firstAt: Date?
    func take(_ chunk: Data) {
        lock.withLock {
            if firstAt == nil { firstAt = Date() }
            audio.append(chunk)
            chunks += 1
        }
    }
    var snapshot: (audio: Data, chunks: Int, firstAt: Date?) { lock.withLock { (audio, chunks, firstAt) } }
}

@Suite(.serialized) struct LiveOwnListeningTests {
    @Test(.enabled(if: isLive, "Set HF_LIVE=1 to talk to the real ElevenLabs agent"))
    @MainActor
    func aHeardTurnIsAnsweredAndTheReplyArrivesAsSpeech() async throws {
        let settings = Settings.load()
        try #require(!settings.elevenLabsAPIKey.isEmpty, "ELEVENLABS_API_KEY must be in .env")
        let catcher = AudioCatcher()
        let stops = Recorder<Bool>()
        let ownListening = OwnListening.elevenLabs(
            settings: settings, play: { catcher.take($0) }, stopPlaying: { stops.add(true) })
        let session = VoiceSession(
            settings: settings, agentID: try await TestAgent.resolve(settings: settings), mode: .voice,
            ownListening: ownListening)
        let replies = Recorder<String>()
        let heard = Recorder<String>()
        session.addReplyListener { replies.add($0) }
        await session.start(tools: [], memorySummary: "Nothing yet.", onUserSentence: { heard.add($0) })
        let connected = await session.waitUntilConnected(timeout: 25)
        try #require(connected, "could not connect to the agent")

        let sentAt = Date()
        try await session.sendHeardTurn(
            "Please reply with exactly this sentence and nothing else: The purple elephant danced quietly under seven orange umbrellas.")
        let replyAfter = await waitFor(15) { !replies.all.isEmpty }
        let audioAfter = await waitFor(15) { catcher.snapshot.firstAt != nil }
        // Let the rest of the reply's speech arrive and the speaker finish.
        _ = await waitFor(15) { !session.isAgentSpeaking && catcher.snapshot.chunks > 0 }
        let result = catcher.snapshot
        await session.stop()

        #expect(heard.all.count == 1, "the heard turn reached the transcript listeners")
        #expect(replyAfter != nil, "the agent did not reply")
        #expect(audioAfter != nil, "no speech audio arrived")
        #expect(result.audio.count % 2 == 0)
        #expect(result.audio.count > 32_000, "under a second of speech for a whole sentence")

        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HF_SPIKE_DIR"] ?? NSTemporaryDirectory())
        let file = folder.appendingPathComponent("own-listening-reply.pcm")
        try result.audio.write(to: file)
        let firstChunk = result.firstAt.map { $0.timeIntervalSince(sentAt) } ?? -1
        print(String(format: "LIVE own listening: reply text after %.2f s; first audio chunk %.2f s after sending (%.2f s after asking for speech); %d bytes (%.1f s of audio) in %d chunks; written to %@",
                     replyAfter ?? -1, firstChunk, session.lastSpeechStartDelay ?? -1,
                     result.audio.count, Double(result.audio.count) / 32_000, result.chunks, file.path))
        print("LIVE own listening: replies = \(replies.all)")
    }
}
