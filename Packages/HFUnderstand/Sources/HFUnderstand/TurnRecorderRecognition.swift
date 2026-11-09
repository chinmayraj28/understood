import AVFoundation
import Foundation
import HFCore
import Speech

// The live recogniser inside the turn recorder. Apple's, on the device only. It is used for
// three small things: catching "stop" the moment it is said, catching a final "done", and the
// turn's `liveTranscript`. The real hearing of the turn is done afterwards by the hearers.
//
// The patterns follow HFWake/Engines.swift (SpeechAnalyzer on macOS 26, SFSpeechRecognizer
// forced on-device before that). HFWake is not imported: packages depend only on HFCore.

/// One update from the live recogniser. A later update with the same key replaces the text.
struct TurnRecorderTranscriptUpdate: Sendable {
    var key: Int
    /// Where this stretch of speech starts, in seconds from the start of the session, when the
    /// recogniser says. SpeechAnalyzer does; the older recogniser does not.
    var segmentStart: Double?
    var text: String
}

/// A live on-device recogniser fed buffer by buffer.
protocol TurnRecorderLiveRecognizer: AnyObject, Sendable {
    /// For logs: "SpeechAnalyzer (en_GB)".
    var name: String { get }
    /// True when a session should be started afresh after every turn. The older recogniser
    /// keeps one growing transcript and gives up after about a minute, so it is renewed.
    var renewsEachTurn: Bool { get }
    /// Checks the permission and that the model is there (downloading it if needed).
    func prepare() async throws
    /// Starts a session for audio in `format`.
    func startSession(
        format: AVAudioFormat, onUpdate: @escaping @Sendable (TurnRecorderTranscriptUpdate) -> Void,
        onEnded: @escaping @Sendable (Error?) -> Void
    ) async throws
    /// Called on the audio thread. Must copy what it keeps.
    func append(_ buffer: AVAudioPCMBuffer)
    func stopSession() async
}

enum TurnRecorderRecognizers {
    /// SpeechAnalyzer when this Mac has it, otherwise the older recogniser, both on-device.
    static func make(languageCode: String, hints: [String]) -> TurnRecorderLiveRecognizer {
        let locale = Locale(identifier: languageCode)
        if #available(macOS 26.0, *), SpeechTranscriber.isAvailable {
            return TurnRecorderAnalyzer(locale: locale, hints: hints)
        }
        return TurnRecorderOnDeviceRecognizer(locale: locale, hints: hints)
    }
}

// MARK: - SpeechAnalyzer (macOS 26)

@available(macOS 26.0, *)
final class TurnRecorderAnalyzer: TurnRecorderLiveRecognizer, @unchecked Sendable {
    let requestedLocale: Locale
    let hints: [String]
    private let lock = NSLock()
    private var locale: Locale?
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var resultsTask: Task<Void, Never>?

    init(locale: Locale, hints: [String]) {
        self.requestedLocale = locale
        self.hints = hints
    }

    var name: String { "SpeechAnalyzer (\(lock.withLock { locale ?? requestedLocale }.identifier))" }
    var renewsEachTurn: Bool { false }

    private static func transcriber(_ locale: Locale) -> SpeechTranscriber {
        // volatileResults: guesses while the words are still being spoken, so "stop" is seen at once.
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
    }

    func prepare() async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw SpeakableError("On-device speech recognition doesn't support \(requestedLocale.identifier), so I can't hear \"stop\" while you speak.")
        }
        let transcriber = Self.transcriber(locale)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .unsupported:
            throw SpeakableError("On-device speech recognition doesn't support this language, so I can't hear \"stop\" while you speak.")
        case .supported, .downloading:
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
            } catch {
                throw SpeakableError("Apple's speech model isn't downloaded yet. Connect to the internet once so it can download.")
            }
        default:
            break
        }
        lock.withLock { self.locale = locale }
    }

    func startSession(
        format: AVAudioFormat, onUpdate: @escaping @Sendable (TurnRecorderTranscriptUpdate) -> Void,
        onEnded: @escaping @Sendable (Error?) -> Void
    ) async throws {
        guard let locale = lock.withLock({ self.locale }) else { throw SpeakableError("The speech recogniser wasn't ready.") }
        let transcriber = Self.transcriber(locale)
        guard let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: format),
            let converter = AVAudioConverter(from: format, to: best)
        else { throw SpeakableError("The microphone's sound format isn't one the speech recogniser can use.") }
        // Bounded, so a stalled recogniser can never make memory grow: the oldest audio is dropped.
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .bufferingNewest(128))
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        if !hints.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = hints
            try? await analyzer.setContext(context)
        }
        try await analyzer.prepareToAnalyze(in: best)
        let results = Task {
            do {
                for try await result in transcriber.results {
                    let start = result.range.start.seconds
                    onUpdate(TurnRecorderTranscriptUpdate(
                        key: Int((start * 100).rounded()), segmentStart: start.isFinite ? start : nil,
                        text: String(result.text.characters)))
                }
                if !Task.isCancelled { onEnded(nil) }
            } catch {
                if !Task.isCancelled { onEnded(error) }
            }
        }
        lock.withLock {
            self.analyzer = analyzer
            self.continuation = continuation
            self.converter = converter
            self.analyzerFormat = best
            self.resultsTask = results
        }
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            await stopSession()
            throw error
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let (converter, format, continuation) = lock.withLock { (self.converter, self.analyzerFormat, self.continuation) }
        guard let converter, let format, let continuation else { return }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return }
        continuation.yield(AnalyzerInput(buffer: output))
    }

    func stopSession() async {
        let (analyzer, continuation, results) = lock.withLock { () -> (SpeechAnalyzer?, AsyncStream<AnalyzerInput>.Continuation?, Task<Void, Never>?) in
            defer {
                self.analyzer = nil
                self.continuation = nil
                self.converter = nil
                self.resultsTask = nil
            }
            return (self.analyzer, self.continuation, self.resultsTask)
        }
        results?.cancel()
        continuation?.finish()
        await analyzer?.cancelAndFinishNow()
    }
}

// MARK: - SFSpeechRecognizer, forced on-device (before macOS 26)

final class TurnRecorderOnDeviceRecognizer: TurnRecorderLiveRecognizer, @unchecked Sendable {
    let requestedLocale: Locale
    let hints: [String]
    private let lock = NSLock()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    init(locale: Locale, hints: [String]) {
        self.requestedLocale = locale
        self.hints = hints
    }

    var name: String { "SFSpeechRecognizer on-device (\(requestedLocale.identifier))" }
    var renewsEachTurn: Bool { true }

    func prepare() async throws {
        if SFSpeechRecognizer.authorizationStatus() != .authorized {
            throw SpeakableError("\(TurnRecorderPermissions.ownerName) isn't allowed to use speech recognition, so I can't hear \"stop\" while you speak. Someone can turn it on in System Settings, Privacy and Security, Speech Recognition.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: requestedLocale), recognizer.supportsOnDeviceRecognition else {
            // Never fall back to Apple's servers.
            throw SpeakableError("Speech recognition on this Mac can't run offline for this language, so I can't hear \"stop\" while you speak.")
        }
        lock.withLock { self.recognizer = recognizer }
    }

    func startSession(
        format: AVAudioFormat, onUpdate: @escaping @Sendable (TurnRecorderTranscriptUpdate) -> Void,
        onEnded: @escaping @Sendable (Error?) -> Void
    ) async throws {
        guard let recognizer = lock.withLock({ self.recognizer }) else { throw SpeakableError("The speech recogniser wasn't ready.") }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.contextualStrings = hints
        request.addsPunctuation = false
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                onUpdate(TurnRecorderTranscriptUpdate(key: 0, segmentStart: nil, text: result.bestTranscription.formattedString))
                if result.isFinal { onEnded(nil) }
            } else if let error {
                onEnded(error)
            }
        }
        lock.withLock {
            self.request = request
            self.task = task
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let request = lock.withLock({ self.request }),
            let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
            let from = buffer.floatChannelData?[0], let to = copy.floatChannelData?[0]
        else { return }
        copy.frameLength = buffer.frameLength
        to.update(from: from, count: Int(buffer.frameLength))
        request.append(copy)
    }

    func stopSession() async {
        let (request, task) = lock.withLock { () -> (SFSpeechAudioBufferRecognitionRequest?, SFSpeechRecognitionTask?) in
            defer { self.request = nil; self.task = nil }
            return (self.request, self.task)
        }
        request?.endAudio()
        task?.cancel()
    }
}

// MARK: - Permissions

/// The microphone permission, checked without changing any setting. For the app it belongs to
/// Handsfree.app; for the command-line tool and tests, to the terminal's host app (Orca).
enum TurnRecorderPermissions {
    static var ownerName: String {
        if let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String, !name.isEmpty { return name }
        return "This terminal app"
    }

    static func requireMicrophone(request: Bool) async throws {
        var status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined, request {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            status = AVCaptureDevice.authorizationStatus(for: .audio)
        }
        switch status {
        case .authorized:
            return
        case .notDetermined:
            throw SpeakableError("\(ownerName) hasn't been allowed to use the microphone yet, so I can't hear you. It needs to be allowed once at setup.")
        default:
            throw SpeakableError("\(ownerName) isn't allowed to use the microphone, so I can't hear you. Someone can turn it on in System Settings, Privacy and Security, Microphone.")
        }
    }
}
