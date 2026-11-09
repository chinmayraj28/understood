import Foundation
import HFCore
import os

// Own-listening mode (docs/spikes/own_listening.md, DECISIONS.md 8 Nov): the conversation is
// text-only, the app hears the person itself, and the agent's replies are spoken here with
// ElevenLabs streaming text-to-speech. The audio is handed to a sink the app provides (the turn
// recorder's player), so the echo canceller has the exact sound to take out of the microphone.
// HFVoice never imports HFUnderstand: the app connects the two.

/// Turns reply text into speech, as it is made.
public protocol SpeechStreaming: Sendable {
    /// Raw 16-bit little-endian mono PCM at 16 kHz, in chunks as they arrive. Every chunk has
    /// an even number of bytes. Cancelling the consuming task stops the request.
    func stream(_ text: String) -> AsyncThrowingStream<Data, Error>
}

/// ElevenLabs streaming text-to-speech: `POST /v1/text-to-speech/{voice_id}/stream` with
/// `output_format=pcm_16000` (raw PCM, 16 kHz, mono, 16-bit), the agent's own voice.
public struct ElevenLabsSpeechStream: SpeechStreaming {
    public let apiKey: String
    public let voiceID: String
    /// Flash: the lowest-latency ElevenLabs model, the one the agent speaks with.
    public let modelID: String
    /// Audio is passed on in pieces this big: 3,200 bytes is 0.1 s.
    public let chunkBytes: Int

    public init(apiKey: String, voiceID: String, modelID: String = "eleven_flash_v2_5", chunkBytes: Int = 3_200) {
        self.apiKey = apiKey
        self.voiceID = voiceID
        self.modelID = modelID
        self.chunkBytes = max(2, chunkBytes & ~1)
    }

    public func stream(_ text: String) -> AsyncThrowingStream<Data, Error> {
        let apiKey = apiKey, voiceID = voiceID, modelID = modelID, chunkBytes = chunkBytes
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)/stream?output_format=pcm_16000")!)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 15
                    request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "model_id": modelID])
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        throw SpeakableError("I couldn't say the reply aloud (text-to-speech error \(status)).")
                    }
                    var piece = Data()
                    piece.reserveCapacity(chunkBytes)
                    for try await byte in bytes {
                        piece.append(byte)
                        if piece.count >= chunkBytes {
                            continuation.yield(piece)
                            piece = Data()
                            piece.reserveCapacity(chunkBytes)
                        }
                    }
                    // A trailing odd byte would split a sample in half: drop it.
                    if piece.count % 2 == 1 { piece.removeLast() }
                    if !piece.isEmpty { continuation.yield(piece) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// The setting that turns own-listening mode on. Off (nil) by default: the session then works
/// exactly as before.
public struct OwnListening: Sendable {
    /// Makes the speech.
    public var speech: SpeechStreaming
    /// Plays one chunk of 16 kHz mono PCM16. The app connects this to `TurnRecorder.playAgentAudio`.
    public var play: @Sendable (Data) -> Void
    /// Stops playback at once and drops what is queued. The app connects this to `TurnRecorder.stopAgentAudio`.
    public var stopPlaying: @Sendable () -> Void
    /// How long the agent still counts as speaking after its last sample is due to finish:
    /// covers the player's own buffering.
    public var playbackTail: TimeInterval

    public init(
        speech: SpeechStreaming, play: @escaping @Sendable (Data) -> Void, stopPlaying: @escaping @Sendable () -> Void,
        playbackTail: TimeInterval = 0.3
    ) {
        self.speech = speech
        self.play = play
        self.stopPlaying = stopPlaying
        self.playbackTail = playbackTail
    }

    /// ElevenLabs speech in the agent's own voice, with the key from `Settings`.
    public static func elevenLabs(
        settings: Settings, configuration: AgentConfiguration = AgentConfiguration(),
        play: @escaping @Sendable (Data) -> Void, stopPlaying: @escaping @Sendable () -> Void
    ) -> OwnListening {
        OwnListening(
            speech: ElevenLabsSpeechStream(apiKey: settings.elevenLabsAPIKey, voiceID: configuration.voiceID),
            play: play, stopPlaying: stopPlaying)
    }
}

/// Speaks the agent's replies one after another and says when the agent is audible.
///
/// "Speaking" starts with the first chunk handed to the sink. It ends when the audio handed
/// over is due to have finished playing (16 kHz × 2 bytes = 32,000 bytes a second), plus
/// `playbackTail`. The sink gives no "finished" callback, so this is worked out from the bytes.
@MainActor
final class AgentSpeaker {
    static let bytesPerSecond = 32_000.0
    private let setting: OwnListening
    private let clock: @Sendable () -> TimeInterval
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let onActivity: @MainActor (AgentActivity) -> Void
    /// A reply's audio was all handed over and is due to have finished playing.
    private let onPlayed: @MainActor (Int) -> Void
    /// A reply was cut off (interrupted, closed) or its speech failed: it may not have been heard.
    private let onCutOff: @MainActor (Int) -> Void
    nonisolated private static let logger = Logger(subsystem: "com.handsfree", category: "HFVoice")

    private var waiting: [(id: Int, text: String)] = []
    /// The reply whose speech is being made now.
    private var inProgress: Int?
    /// Replies fully handed over, with when their audio is due to have finished.
    private var awaitingEnd: [(id: Int, endsAt: TimeInterval)] = []
    private var worker: Task<Void, Never>?
    /// Bumped by every interruption, so work begun before it gives up.
    private var generation = 0
    private var playbackEndsAt: TimeInterval = 0
    private(set) var isSpeaking = false
    /// True from the moment a reply is queued until its audio is due to have finished: also
    /// while the speech is still being made, before the first chunk.
    var isBusy: Bool { worker != nil || isSpeaking }
    /// Seconds from asking for the latest reply's speech to its first chunk. For measurements.
    private(set) var lastTimeToFirstChunk: TimeInterval?
    /// Bytes handed to the sink since the session began. For tests and measurements.
    private(set) var bytesPlayed = 0
    /// The latest failure to make speech, in words fine to say. Nil when the last reply was spoken.
    private(set) var lastProblem: String?

    init(
        setting: OwnListening, clock: @escaping @Sendable () -> TimeInterval,
        sleep: @escaping @Sendable (TimeInterval) async -> Void, onActivity: @escaping @MainActor (AgentActivity) -> Void,
        onPlayed: @escaping @MainActor (Int) -> Void = { _ in }, onCutOff: @escaping @MainActor (Int) -> Void = { _ in }
    ) {
        self.setting = setting
        self.clock = clock
        self.sleep = sleep
        self.onActivity = onActivity
        self.onPlayed = onPlayed
        self.onCutOff = onCutOff
    }

    /// Queues a reply to be spoken after any reply still playing. `id` comes back in exactly one
    /// of `onPlayed` or `onCutOff`. Empty text is not spoken and reports nothing.
    func speak(_ text: String, id: Int = 0) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        waiting.append((id, trimmed))
        guard worker == nil else { return }
        let myGeneration = generation
        worker = Task { [weak self] in await self?.work(generation: myGeneration) }
    }

    /// Stops the voice now: what is playing, what is queued, and any speech still being made.
    func interrupt() {
        generation += 1
        let cut = waiting.map(\.id) + (inProgress.map { [$0] } ?? []) + awaitingEnd.map(\.id)
        waiting.removeAll()
        inProgress = nil
        awaitingEnd.removeAll()
        worker?.cancel()
        worker = nil
        setting.stopPlaying()
        playbackEndsAt = 0
        if isSpeaking {
            isSpeaking = false
            onActivity(.listening)
        }
        for id in cut { onCutOff(id) }
    }

    /// Reports every reply whose audio is due to have finished by now.
    private func reportFinished() {
        let now = clock()
        let finished = awaitingEnd.filter { $0.endsAt + setting.playbackTail <= now }
        guard !finished.isEmpty else { return }
        awaitingEnd.removeAll { item in finished.contains { $0.id == item.id } }
        for item in finished { onPlayed(item.id) }
    }

    private func work(generation myGeneration: Int) async {
        while myGeneration == generation, !waiting.isEmpty {
            let reply = waiting.removeFirst()
            inProgress = reply.id
            let complete = await speakOne(reply.text, generation: myGeneration)
            guard myGeneration == generation else { return }
            inProgress = nil
            if complete { awaitingEnd.append((reply.id, playbackEndsAt)) } else { onCutOff(reply.id) }
            reportFinished()
        }
        // Everything is handed over: wait until it is due to have finished playing.
        while myGeneration == generation, isSpeaking || !awaitingEnd.isEmpty {
            reportFinished()
            let left = playbackEndsAt + setting.playbackTail - clock()
            if left <= 0 { break }
            await sleep(min(left, 0.05))
            // A reply queued meanwhile is spoken by this same worker.
            if myGeneration == generation, !waiting.isEmpty { return await work(generation: myGeneration) }
        }
        guard myGeneration == generation else { return }
        reportFinished()
        worker = nil
        if isSpeaking {
            isSpeaking = false
            onActivity(.listening)
        }
    }

    /// Streams one reply into the sink. True when all of it was handed over without a failure.
    private func speakOne(_ text: String, generation myGeneration: Int) async -> Bool {
        let askedAt = clock()
        var first = true
        do {
            for try await chunk in setting.speech.stream(text) {
                guard myGeneration == generation, !Task.isCancelled else { return false }
                let now = clock()
                if first {
                    first = false
                    lastTimeToFirstChunk = now - askedAt
                    lastProblem = nil
                }
                playbackEndsAt = max(playbackEndsAt, now) + Double(chunk.count) / Self.bytesPerSecond
                bytesPlayed += chunk.count
                setting.play(chunk)
                if !isSpeaking {
                    isSpeaking = true
                    onActivity(.speaking)
                }
            }
            // A stream with no audio at all said nothing.
            if first { lastProblem = "I couldn't say the reply aloud (no audio came back)." }
            return !first && myGeneration == generation
        } catch {
            guard myGeneration == generation, !(error is CancellationError) else { return false }
            lastProblem = (error as? SpeakableError)?.spokenMessage ?? "I couldn't say the reply aloud."
            Self.logger.error("Text-to-speech failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
