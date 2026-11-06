import AVFoundation
import Foundation
import HFCore
import os

// The seams that let the listener be tested without a microphone.
//
//   AudioInput         the microphone (real: MicrophoneInput, AVAudioEngine)
//   RecognitionEngine  makes recognition sessions (real: AnalyzerEngine on macOS 26,
//                      OnDeviceRecognizerEngine before that; both on the device only)
//   StreamingTranscriber  keeps one microphone open and feeds it to one session after another,
//                      replacing a session that ends or has run long, without dropping audio
//   TranscriptSource   what WakeListener sees: start, stop, and a stream of transcripts

let wakeLog = Logger(subsystem: "com.handsfree", category: "wake")

/// Where audio comes from.
protocol AudioInput: AnyObject {
    /// Throws a `SpeakableError` when the permission this input needs is missing.
    func checkPermission(request: Bool) async throws
    /// Gets the device ready and returns the format its buffers will have.
    func prepare() throws -> AVAudioFormat
    /// Starts delivering buffers. `onInterrupted` is called if the device stops by itself
    /// (unplugged, the default microphone changed).
    func start(
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onInterrupted: @escaping (String) -> Void
    ) throws
    /// Stops and releases the device completely, so another part of the app can open it.
    func stop()
}

/// What a recognition session reports. `segment` is local to the session.
struct RecognitionCallbacks: Sendable {
    var onTranscript: @Sendable (_ segment: Int, _ text: String, _ isFinal: Bool) -> Void
    /// The session ended by itself: a recognition timeout, a finished task or an error.
    var onEnded: @Sendable (_ error: Error?) -> Void
}

/// One stretch of recognition, fed buffer by buffer.
protocol RecognitionSession: AnyObject, Sendable {
    /// Called on the audio thread with each microphone buffer. Must copy what it keeps,
    /// because the microphone reuses the buffer.
    func append(_ buffer: AVAudioPCMBuffer)
    /// Ends the session now. No more transcripts are wanted from it.
    func cancel() async
}

/// Makes recognition sessions. Every implementation recognises on the device only.
protocol RecognitionEngine: AnyObject, Sendable {
    /// For logs and the command-line tool, e.g. "SpeechAnalyzer (en_IN)".
    var name: String { get }
    /// Checks permission and that on-device recognition is available, downloading Apple's
    /// speech model if it is missing. Throws a `SpeakableError` saying what is wrong.
    func prepare(requestPermission: Bool) async throws
    /// How long one session may run before it is replaced at the next quiet moment.
    var preferredSessionSeconds: Double { get }
    func makeSession(inputFormat: AVAudioFormat, callbacks: RecognitionCallbacks) async throws -> RecognitionSession
}

/// What the wake listener listens to.
protocol TranscriptSource: AnyObject, Sendable {
    var name: String { get }
    func start(
        onUpdate: @escaping @Sendable (TranscriptUpdate) -> Void,
        onInterrupted: @escaping @Sendable (String) -> Void
    ) async throws
    /// Releases the microphone completely before returning.
    func stop() async
}

// MARK: - The microphone

/// The microphone, through AVAudioEngine. A fresh engine is made for every start and thrown away
/// on stop, so nothing of ours holds the audio device while the conversation has it.
final class MicrophoneInput: AudioInput {
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private var tapInstalled = false

    func checkPermission(request: Bool) async throws {
        try await WakePermissions.requireMicrophone(request: request)
    }

    func prepare() throws -> AVAudioFormat {
        stop()
        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SpeakableError("I can't find a microphone to listen for the wake phrase.")
        }
        self.engine = engine
        return format
    }

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void, onInterrupted: @escaping (String) -> Void) throws {
        guard let engine else { throw SpeakableError("The microphone wasn't ready.") }
        let input = engine.inputNode
        // 4096 frames is about 85 ms at 48 kHz: small enough to keep the delay low, large enough
        // that the audio thread wakes only about twelve times a second.
        input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { buffer, _ in
            onBuffer(buffer)
        }
        tapInstalled = true
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in
            // A headset was plugged in, AirPods connected, or the default input changed. The
            // engine has stopped; the listener starts a fresh one on the new device.
            onInterrupted("the microphone changed")
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw SpeakableError("I couldn't open the microphone to listen for the wake phrase.")
        }
    }

    func stop() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        if let engine {
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            engine.stop()
            engine.reset()
        }
        tapInstalled = false
        engine = nil
    }
}

// MARK: - The streaming transcriber

/// Keeps the microphone open and feeds it to one recognition session after another.
///
/// Recognition sessions do not last forever: Apple's older recogniser ends a task after a
/// silence or about a minute, and any session can fail. When one ends, a new one is made at once
/// and the audio that arrived in between is held and handed to it, so there is no gap in which
/// the phrase could be missed. A session that has simply run for a long time is replaced at a
/// quiet moment, with the old one still listening until the new one is ready.
final class StreamingTranscriber: TranscriptSource, @unchecked Sendable {
    let input: AudioInput
    let engine: RecognitionEngine
    let requestPermission: Bool
    /// Replace a long-running session only after this much quiet.
    let quietBeforeReplacing: Double
    private let now: @Sendable () -> Double

    private let lock = NSLock()
    private var running = false
    /// Bumped by every start and stop, so work begun in an earlier run gives up.
    private var runID = 0
    private var format: AVAudioFormat?
    private var current: RecognitionSession?
    /// Never reset, so a late callback from a cancelled session can't pass for the current one.
    private var currentIndex = 0
    /// Sessions that ended within a moment of starting, in a row: slows down the replacements.
    private var quickEnds = 0
    private var currentStartedAt: Double = 0
    private var lastTranscriptAt: Double = 0
    private var replacing = false
    /// Audio that arrived while there was no session to give it to. Bounded to a few seconds.
    private var heldBuffers: [AVAudioPCMBuffer] = []
    private var heldFrames: AVAudioFramePosition = 0
    private var replacementTask: Task<Void, Never>?
    private var onUpdate: (@Sendable (TranscriptUpdate) -> Void)?
    private var onInterrupted: (@Sendable (String) -> Void)?
    /// How many sessions have been made since start, for tests and the command-line tool.
    private(set) var sessionsStarted = 0

    var name: String { engine.name }

    init(
        input: AudioInput, engine: RecognitionEngine, requestPermission: Bool,
        quietBeforeReplacing: Double = 1.5,
        now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.input = input
        self.engine = engine
        self.requestPermission = requestPermission
        self.quietBeforeReplacing = quietBeforeReplacing
        self.now = now
    }

    func start(
        onUpdate: @escaping @Sendable (TranscriptUpdate) -> Void,
        onInterrupted: @escaping @Sendable (String) -> Void
    ) async throws {
        try await input.checkPermission(request: requestPermission)
        try await engine.prepare(requestPermission: requestPermission)
        let format = try input.prepare()
        let firstIndex = lock.withLock { () -> Int in
            self.format = format
            self.onUpdate = onUpdate
            self.onInterrupted = onInterrupted
            self.running = true
            self.runID += 1
            self.currentIndex += 1
            self.quickEnds = 0
            self.sessionsStarted = 0
            self.heldBuffers = []
            self.heldFrames = 0
            return self.currentIndex
        }
        do {
            let session = try await engine.makeSession(inputFormat: format, callbacks: callbacks(forSession: firstIndex))
            lock.withLock {
                current = session
                currentStartedAt = now()
                lastTranscriptAt = now()
                sessionsStarted = 1
            }
            try input.start(
                onBuffer: { [weak self] buffer in self?.route(buffer) },
                onInterrupted: { [weak self] reason in self?.interrupted(reason) })
        } catch {
            await stop()
            throw error
        }
    }

    func stop() async {
        let (session, replacement) = lock.withLock { () -> (RecognitionSession?, Task<Void, Never>?) in
            running = false
            runID += 1
            let session = current
            current = nil
            heldBuffers = []
            heldFrames = 0
            onUpdate = nil
            onInterrupted = nil
            let replacement = replacementTask
            replacementTask = nil
            replacing = false
            return (session, replacement)
        }
        // The microphone first: stopping must release it promptly, whatever the recogniser does.
        input.stop()
        replacement?.cancel()
        await session?.cancel()
    }

    // MARK: Audio, on the audio thread

    private func route(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard running else { lock.unlock(); return }
        if let session = current {
            // Renew a long session at a quiet moment, or regardless once it has run twice as
            // long (a television may mean there is never a quiet moment).
            let age = now() - currentStartedAt
            let shouldReplace =
                !replacing && age >= engine.preferredSessionSeconds
                && (now() - lastTranscriptAt >= quietBeforeReplacing || age >= 2 * engine.preferredSessionSeconds)
            lock.unlock()
            session.append(buffer)
            if shouldReplace { replaceSession(reason: "ran for a long time", keepOldUntilReady: true) }
        } else {
            hold(buffer)
            lock.unlock()
        }
    }

    /// Keeps a copy of audio that has no session to go to yet, at most about five seconds.
    private func hold(_ buffer: AVAudioPCMBuffer) {
        guard let copy = buffer.copied() else { return }
        heldBuffers.append(copy)
        heldFrames += AVAudioFramePosition(copy.frameLength)
        let limit = AVAudioFramePosition(copy.format.sampleRate * 5)
        while heldFrames > limit, !heldBuffers.isEmpty {
            heldFrames -= AVAudioFramePosition(heldBuffers.removeFirst().frameLength)
        }
    }

    // MARK: Sessions

    private func callbacks(forSession index: Int) -> RecognitionCallbacks {
        RecognitionCallbacks(
            onTranscript: { [weak self] segment, text, isFinal in
                guard let self else { return }
                let deliver: (@Sendable (TranscriptUpdate) -> Void)? = self.lock.withLock {
                    guard self.running, index == self.currentIndex else { return nil }
                    self.lastTranscriptAt = self.now()
                    return self.onUpdate
                }
                // Segments are numbered per session; make them unique across sessions.
                deliver?(TranscriptUpdate(segment: index << 20 | (segment & 0xFFFFF), text: text, isFinal: isFinal))
            },
            // The older recogniser can report an end twice (after its final result, then with an
            // error); the second is ignored because a replacement is already under way.
            onEnded: { [weak self] error in
                guard let self else { return }
                let isCurrent = self.lock.withLock { self.running && index == self.currentIndex }
                guard isCurrent else { return }
                if let error { wakeLog.debug("recognition session ended: \(String(describing: error), privacy: .public)") }
                self.replaceSession(reason: error == nil ? "the session finished" : "the session stopped", keepOldUntilReady: false)
            })
    }

    /// Makes the next session. When the old one has ended, audio is held until the new one is
    /// ready; when the old one is still fine (it has just run long), it keeps listening until then.
    private func replaceSession(reason: String, keepOldUntilReady: Bool) {
        let (proceed, ended, run, pause): (Bool, RecognitionSession?, Int, Double) = lock.withLock {
            guard running, !replacing else { return (false, nil, 0, 0) }
            replacing = true
            // A session that ends moments after it began, again and again, must not be replaced
            // in a tight loop: wait a little longer each time.
            if !keepOldUntilReady {
                quickEnds = now() - currentStartedAt < 2 ? quickEnds + 1 : 0
            }
            let pause = quickEnds == 0 ? 0 : min(0.25 * pow(2, Double(quickEnds)), 10)
            if keepOldUntilReady { return (true, nil, runID, pause) }
            let old = current
            current = nil  // route() now holds audio for the new session
            return (true, old, runID, pause)
        }
        guard proceed else { return }
        let task = Task { [weak self] in
            if let ended { await ended.cancel() }
            if pause > 0 { try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000)) }
            await self?.makeReplacement(reason: reason, run: run)
        }
        lock.withLock { if runID == run { replacementTask = task } }
    }

    private func makeReplacement(reason: String, run: Int) async {
        var delay = 0.25
        for attempt in 1...6 {
            guard let (format, index) = lock.withLock({ running && runID == run ? (self.format, currentIndex + 1) : nil }),
                let format
            else { return }
            do {
                let session = try await engine.makeSession(inputFormat: format, callbacks: callbacks(forSession: index))
                guard await install(session, index: index, run: run) else {
                    await session.cancel()  // stopped, or restarted, while it was being made
                    return
                }
                wakeLog.debug("recognition session replaced (\(reason, privacy: .public))")
                return
            } catch {
                if Task.isCancelled { return }
                wakeLog.error("couldn't start a recognition session, attempt \(attempt): \(String(describing: error), privacy: .public)")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                delay = min(delay * 2, 4)
            }
        }
        interrupted("the recogniser wouldn't restart")
    }

    /// Makes `session` the current one. Audio held while there was no session is handed to it
    /// first, in order, before route() may give it anything newer, so it only ever gets audio
    /// from one thread at a time. Returns false if the run has moved on.
    private func install(_ session: RecognitionSession, index: Int, run: Int) async -> Bool {
        var old: RecognitionSession?
        while true {
            let batch: [AVAudioPCMBuffer]? = lock.withLock {
                guard running, runID == run else { return nil }
                if current == nil {
                    // The old session ended: its words are no longer wanted, the new one's are.
                    currentIndex = index
                    if !heldBuffers.isEmpty {
                        let batch = heldBuffers
                        heldBuffers = []
                        heldFrames = 0
                        return batch
                    }
                }
                old = current
                current = session
                currentIndex = index
                currentStartedAt = now()
                lastTranscriptAt = now()
                sessionsStarted += 1
                replacing = false
                replacementTask = nil
                return []
            }
            guard let batch else { return false }
            if batch.isEmpty { break }
            for buffer in batch { session.append(buffer) }
        }
        await old?.cancel()
        return true
    }

    private func interrupted(_ reason: String) {
        let report = lock.withLock { running ? onInterrupted : nil }
        report?(reason)
    }
}

extension AVAudioPCMBuffer {
    /// A copy that owns its samples, for keeping a buffer beyond the tap callback.
    func copied() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
            guard let fromData = from.mData, let toData = to.mData else { continue }
            memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }
}
