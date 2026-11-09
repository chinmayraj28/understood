import AVFoundation
import Foundation
import HFCore
import os

// Stage 1 of docs/SPEECH_PLAN.md: record each turn of the person's speech, patiently.
//
//   microphone (AVAudioEngine, echo cancellation on)
//     ├─► 16 kHz mono samples ─► TurnEndDetector (when does the turn start and end?)
//     │                            └─► the turn, cut out as a WAV file ─► RecordedTurn
//     └─► Apple's live on-device recogniser ─► "stop" at once, a final "done", liveTranscript
//
// The recorder never pauses while the agent speaks: the person must be able to say "stop" over
// the agent. Echo cancellation is relied on to keep the agent's voice out. What it leaves
// behind is described in docs/spikes/own_listening.md.

let turnRecorderLog = Logger(subsystem: "com.handsfree", category: "understand")

/// How the turn recorder listens.
public struct TurnRecorderSettings: Sendable, Equatable {
    /// When a turn starts and ends (end silence 2.5 s, longest turn 30 s, "done", "stop").
    public var endOfTurn: TurnEndSettings
    /// Apple's echo cancellation on our microphone input, so the agent's voice from the
    /// speakers is not recorded as the person. On by default; the recorder still works if the
    /// Mac refuses it (see `TurnRecorder.isEchoCancelling`).
    public var voiceProcessing: Bool
    /// Run Apple's live recogniser for "stop", "done" and `liveTranscript`.
    public var liveRecognition: Bool
    /// BCP-47 language for the live recogniser, such as "en-GB".
    public var languageCode: String
    /// Words the live recogniser should expect (names, commands). "stop" and "done" are added.
    public var hints: [String]
    /// Show the system's microphone prompt if it has never been asked. Off for tests and tools.
    public var requestPermission: Bool
    /// If the microphone sends no sound at all for this long after starting, say so. A closed
    /// laptop lid does exactly this: the engine runs and nothing arrives.
    public var silentMicrophoneSeconds: Double

    public init(
        endOfTurn: TurnEndSettings = TurnEndSettings(),
        voiceProcessing: Bool = true,
        liveRecognition: Bool = true,
        languageCode: String = "en-GB",
        hints: [String] = [],
        requestPermission: Bool = false,
        silentMicrophoneSeconds: Double = 3
    ) {
        self.endOfTurn = endOfTurn
        self.voiceProcessing = voiceProcessing
        self.liveRecognition = liveRecognition
        self.languageCode = languageCode
        self.hints = hints
        self.requestPermission = requestPermission
        self.silentMicrophoneSeconds = silentMicrophoneSeconds
    }
}

/// What the turn recorder reports, in order.
public enum TurnRecorderEvent: Sendable, Equatable {
    /// The person started speaking (sound for longer than a blip).
    case speechStarted
    /// How loud the person is, 0...1, about twenty times a second during a turn. For the waveform.
    case level(Double)
    /// "stop", "cancel" or "wait" appeared in the live transcript. Sent the moment it is
    /// heard, before the turn ends, so the agent and any task can be stopped at once.
    case stopHeard(word: String, liveText: String)
    /// A finished turn, ready for the hearers.
    case turnFinished(RecordedTurn, reason: TurnEndReason)
    /// Something is wrong with listening, in words that can be spoken to the person.
    case problem(String)
}

/// Records the person's turns from the microphone. See the top of this file.
///
/// ```swift
/// let recorder = TurnRecorder()
/// try await recorder.start()
/// for await event in recorder.events {
///     if case .turnFinished(let turn, _) = event { /* hear, repair, decide */ }
/// }
/// ```
/// `events` has one reader. It stays open across `stop()` and `start()`.
public final class TurnRecorder: @unchecked Sendable {
    /// Everything the recorder notices, in order.
    public let events: AsyncStream<TurnRecorderEvent>
    private let continuation: AsyncStream<TurnRecorderEvent>.Continuation

    private let lock = NSLock()
    private var settings: TurnRecorderSettings
    private var core: TurnRecorderCore
    private var running = false
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var resampler: TurnRecorderResampler?
    private var recognizer: TurnRecorderLiveRecognizer?
    /// Bumped for every recogniser session, so a late result from an old one is ignored.
    private var recognizerSession = 0
    /// Where the current recogniser session started on the audio clock.
    private var recognizerOffset: Double = 0
    private var renewing = false
    private var configurationObserver: NSObjectProtocol?
    private var watchdog: Task<Void, Never>?
    private var loudestSampleSinceStart: Float = 0
    private var echoCancelling = false

    /// Creates a recorder. Nothing is opened until `start()`.
    public init(settings: TurnRecorderSettings = TurnRecorderSettings()) {
        self.settings = settings
        self.core = TurnRecorderCore(settings: settings.endOfTurn)
        (events, continuation) = AsyncStream.makeStream(of: TurnRecorderEvent.self, bufferingPolicy: .bufferingNewest(256))
    }

    deinit { continuation.finish() }

    /// True when Apple's echo cancellation is on for our microphone input.
    public var isEchoCancelling: Bool { lock.withLock { echoCancelling } }

    /// The live recogniser in use, for logs and the panel. Nil when it is off or not started.
    public var liveRecognizerName: String? { lock.withLock { recognizer?.name } }

    /// How much quiet ends a turn. Can be changed while recording; the next silence uses it.
    public var endSilenceSeconds: Double {
        get { lock.withLock { core.detector.settings.endSilenceSeconds } }
        set { lock.withLock { core.detector.settings.endSilenceSeconds = newValue } }
    }

    // MARK: Starting and stopping

    /// Opens the microphone and starts listening for turns.
    /// Throws a `SpeakableError` saying what is missing: the microphone permission, a
    /// microphone, or Apple's speech model.
    public func start() async throws {
        guard !lock.withLock({ running }) else { return }
        let settings = lock.withLock { self.settings }
        try await TurnRecorderPermissions.requireMicrophone(request: settings.requestPermission)

        var recognizer: TurnRecorderLiveRecognizer?
        if settings.liveRecognition {
            let hints = Array(Set(settings.hints + Array(settings.endOfTurn.stopWords) + [settings.endOfTurn.doneWord]))
            let made = TurnRecorderRecognizers.make(languageCode: settings.languageCode, hints: hints)
            try await made.prepare()
            recognizer = made
        }

        let engine = AVAudioEngine()
        // A player on the same engine, for `playAgentAudio`: what it plays is the echo
        // canceller's reference, so the agent's voice can be taken out of the recording exactly.
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: Self.playbackFormat)
        // Order matters (docs/spikes/elevenlabs.md, section 7): the output side must exist
        // before voice processing is turned on, or the engine fails to start (-10875).
        _ = engine.outputNode
        var echoCancelling = false
        if settings.voiceProcessing {
            do {
                try engine.inputNode.setVoiceProcessingEnabled(true)
                // Do not turn the agent's voice down while we listen: the person needs to hear it.
                engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
                echoCancelling = true
            } catch {
                turnRecorderLog.error("echo cancellation refused, recording without it: \(String(describing: error), privacy: .public)")
                try? engine.inputNode.setVoiceProcessingEnabled(false)
            }
        }
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, let resampler = TurnRecorderResampler(inputSampleRate: format.sampleRate) else {
            throw SpeakableError("I can't find a microphone to listen with.")
        }

        lock.withLock {
            self.engine = engine
            self.player = player
            self.resampler = resampler
            self.recognizer = recognizer
            self.echoCancelling = echoCancelling
            self.core = TurnRecorderCore(settings: self.settings.endOfTurn)
            self.loudestSampleSinceStart = 0
            self.running = true
        }
        do {
            if recognizer != nil { try await startRecognizerSession() }
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                self?.take(buffer)
            }
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                // A headset was plugged in or the default microphone changed: the engine has
                // stopped. Start again on the new device.
                Task { await self?.restartAfterDeviceChange() }
            }
            engine.prepare()
            try engine.start()
        } catch {
            await stop()
            throw SpeakableError("I couldn't open the microphone to listen.")
        }
        startWatchdog(after: settings.silentMicrophoneSeconds)
        turnRecorderLog.notice("turn recorder started: \(format.sampleRate, privacy: .public) Hz, \(format.channelCount, privacy: .public) ch, echo cancellation \(echoCancelling ? "on" : "off", privacy: .public), live recogniser \(recognizer?.name ?? "off", privacy: .public)")
    }

    /// Closes the microphone and the live recogniser. A turn in progress is dropped.
    public func stop() async {
        let (engine, recognizer, observer, watchdog) = lock.withLock {
            () -> (AVAudioEngine?, TurnRecorderLiveRecognizer?, NSObjectProtocol?, Task<Void, Never>?) in
            running = false
            recognizerSession += 1
            defer {
                self.engine = nil
                self.player = nil
                self.recognizer = nil
                self.configurationObserver = nil
                self.watchdog = nil
            }
            return (self.engine, self.recognizer, self.configurationObserver, self.watchdog)
        }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        watchdog?.cancel()
        // The microphone first: stopping must release it promptly, whatever the recogniser does.
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
        }
        await recognizer?.stopSession()
    }

    // MARK: Playing the agent's voice

    /// What `playAgentAudio` plays: ElevenLabs text-to-speech `pcm_16000` (16 kHz, mono).
    static let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    /// Plays the agent's voice through the recorder's own engine: raw 16-bit mono samples at
    /// 16 kHz, as ElevenLabs text-to-speech returns them with `output_format=pcm_16000`.
    /// Played here, the voice is the echo canceller's reference, so it is removed from the
    /// recording exactly (the earlier spike measured 20 to 25 dB less echo this way). Chunks
    /// queue one after another. Does nothing when the recorder is not running.
    public func playAgentAudio(pcm16 data: Data) {
        guard let player = lock.withLock({ running ? self.player : nil }) else { return }
        let frames = data.count / 2
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: Self.playbackFormat, frameCapacity: AVAudioFrameCount(frames)),
            let destination = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            for index in 0..<frames {
                destination[index] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32768
            }
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    /// Stops the agent's voice at once and drops what was queued: for "stop".
    public func stopAgentAudio() {
        lock.withLock { self.player }?.stop()
    }

    private func restartAfterDeviceChange() async {
        guard lock.withLock({ running }) else { return }
        await stop()
        do {
            try await start()
        } catch {
            continuation.yield(.problem((error as? SpeakableError)?.spokenMessage ?? "The microphone changed and I couldn't listen again."))
        }
    }

    private func startWatchdog(after seconds: Double) {
        guard seconds > 0 else { return }
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            let silent = self.lock.withLock { self.running && self.loudestSampleSinceStart == 0 }
            if silent {
                turnRecorderLog.error("the microphone sent no sound at all")
                self.continuation.yield(.problem("The microphone isn't sending any sound. If this is a laptop with its lid closed, open it or plug in a microphone."))
            }
        }
        lock.withLock { watchdog = task }
    }

    // MARK: Audio, on the audio thread

    private func take(_ buffer: AVAudioPCMBuffer) {
        guard let (resampler, recognizer) = lock.withLock({ running ? (self.resampler, self.recognizer) : nil }),
            let resampler, let mono = resampler.firstChannel(of: buffer)
        else { return }
        recognizer?.append(mono)
        let samples = resampler.resample(mono)
        let loudest = samples.reduce(Float(0)) { max($0, abs($1)) }
        let (events, renew) = lock.withLock { () -> ([TurnRecorderEvent], Bool) in
            loudestSampleSinceStart = max(loudestSampleSinceStart, loudest)
            let events = core.ingest(samples)
            let finished = events.contains { if case .turnFinished = $0 { return true } else { return false } }
            return (events, finished && (self.recognizer?.renewsEachTurn ?? false))
        }
        for event in events { continuation.yield(event) }
        if renew { Task { await self.renewRecognizer(reason: "a turn ended") } }
    }

    // MARK: The live recogniser

    private func startRecognizerSession() async throws {
        guard let (recognizer, format, session) = lock.withLock({ () -> (TurnRecorderLiveRecognizer, AVAudioFormat, Int)? in
            guard running, let recognizer = self.recognizer, let format = resampler?.monoFormat else { return nil }
            recognizerSession += 1
            recognizerOffset = core.time
            return (recognizer, format, recognizerSession)
        }) else { return }
        try await recognizer.startSession(
            format: format,
            onUpdate: { [weak self] update in self?.heard(update, session: session) },
            onEnded: { [weak self] error in
                guard let self, self.lock.withLock({ self.running && self.recognizerSession == session }) else { return }
                if let error { turnRecorderLog.debug("live recogniser ended: \(String(describing: error), privacy: .public)") }
                Task { await self.renewRecognizer(reason: "the session ended") }
            })
    }

    private func heard(_ update: TurnRecorderTranscriptUpdate, session: Int) {
        let events: [TurnRecorderEvent] = lock.withLock {
            guard running, session == recognizerSession else { return [] }
            return core.transcript(
                key: session << 24 | (update.key & 0xFFFFFF),
                segmentStart: update.segmentStart.map { $0 + recognizerOffset },
                text: update.text)
        }
        for event in events { continuation.yield(event) }
    }

    /// Replaces the recogniser session. Audio in the moment between sessions reaches only the
    /// turn audio, not the live recogniser; a "stop" said in that moment is still in the turn.
    private func renewRecognizer(reason: String) async {
        guard let recognizer = lock.withLock({ () -> TurnRecorderLiveRecognizer? in
            guard running, !renewing else { return nil }
            renewing = true
            recognizerSession += 1  // results from the old session are no longer wanted
            return self.recognizer
        }) else { return }
        defer { lock.withLock { renewing = false } }
        await recognizer.stopSession()
        var delay = 0.25
        for attempt in 1...5 {
            guard lock.withLock({ running }) else { return }
            do {
                try await startRecognizerSession()
                turnRecorderLog.debug("live recogniser renewed (\(reason, privacy: .public))")
                return
            } catch {
                turnRecorderLog.error("live recogniser would not restart, attempt \(attempt): \(String(describing: error), privacy: .public)")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                delay = min(delay * 2, 2)
            }
        }
        continuation.yield(.problem("I can't hear \"stop\" while you speak right now. Turns are still recorded."))
    }
}

// MARK: - The part that needs no microphone

/// The end-of-turn detector and the rolling audio, fed 16 kHz samples and live transcripts.
/// Turns their events into `TurnRecorderEvent`s, cutting finished turns out as WAV files.
/// Not thread-safe: `TurnRecorder` holds a lock around it. Tests use it directly.
struct TurnRecorderCore {
    /// Audio is judged in 50 ms chunks: fine enough for a 0.3 s blip, coarse enough to be cheap.
    static let chunkSamples = 800
    var detector: TurnEndDetector
    private var store: TurnRecorderSampleStore
    private var pending: [Float] = []

    init(settings: TurnEndSettings) {
        detector = TurnEndDetector(settings: settings)
        store = TurnRecorderSampleStore(capacitySeconds: settings.maxTurnSeconds + settings.preRollSeconds + 3)
    }

    /// Seconds of audio judged so far.
    var time: Double { detector.time }

    mutating func ingest(_ samples: [Float]) -> [TurnRecorderEvent] {
        store.append(samples)
        pending.append(contentsOf: samples)
        var events: [TurnRecorderEvent] = []
        var index = 0
        while pending.count - index >= Self.chunkSamples {
            let chunk = pending[index..<(index + Self.chunkSamples)]
            index += Self.chunkSamples
            let decibels = TurnRecorderLevels.decibels(chunk)
            events += convert(detector.audio(decibels: decibels, duration: Double(Self.chunkSamples) / TurnRecorderSampleStore.sampleRate))
        }
        pending.removeFirst(index)
        return events
    }

    mutating func transcript(key: Int, segmentStart: Double?, text: String) -> [TurnRecorderEvent] {
        convert(detector.transcript(key: key, segmentStart: segmentStart, text: text))
    }

    private func convert(_ events: [TurnDetectorEvent]) -> [TurnRecorderEvent] {
        events.compactMap { event in
            switch event {
            case .speechStarted: return .speechStarted
            case .level(let level): return .level(level)
            case .stopHeard(let word, let text): return .stopHeard(word: word, liveText: text)
            case .blipIgnored: return nil
            case .turnEnded(let boundary):
                let samples = store.slice(from: boundary.audioStart, to: boundary.audioEnd)
                let turn = RecordedTurn(
                    wav: TurnRecorderWAV.encode(samples),
                    durationSeconds: Double(samples.count) / TurnRecorderSampleStore.sampleRate,
                    liveTranscript: boundary.liveTranscript,
                    source: "mic")
                return .turnFinished(turn, reason: boundary.reason)
            }
        }
    }
}
