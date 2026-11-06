import AVFoundation
import Foundation
import HFCore
import Speech

// The two ways of recognising speech on this Mac. Both keep the audio on the device.
//
// SpeechAnalyzer (macOS 26 and later) is the one used. Apple built it for long-running audio,
// it never sends audio to Apple's servers, and it needs no Speech Recognition permission, only
// the microphone. SFSpeechRecognizer is the fallback for older macOS: it is forced on-device
// with `requiresOnDeviceRecognition`, and it does need the Speech Recognition permission.

/// Which recogniser to use.
public enum WakeRecognizer: String, Sendable, CaseIterable {
    /// SpeechAnalyzer when this Mac has it, otherwise the older recogniser, on-device.
    case automatic
    /// Apple's SpeechAnalyzer (macOS 26 and later).
    case speechAnalyzer
    /// Apple's older SFSpeechRecognizer, forced to run on the device.
    case onDeviceRecognizer
}

/// Builds the engine for a choice, or explains why there is none.
enum RecognitionEngines {
    static func make(_ choice: WakeRecognizer, locale: Locale, contextualStrings: [String]) throws -> RecognitionEngine {
        switch choice {
        case .automatic:
            if #available(macOS 26.0, *), SpeechTranscriber.isAvailable {
                return AnalyzerEngine(locale: locale, contextualStrings: contextualStrings)
            }
            return OnDeviceRecognizerEngine(locale: locale, contextualStrings: contextualStrings)
        case .speechAnalyzer:
            if #available(macOS 26.0, *), SpeechTranscriber.isAvailable {
                return AnalyzerEngine(locale: locale, contextualStrings: contextualStrings)
            }
            throw SpeakableError("This Mac doesn't have Apple's newer speech recogniser, so I can't listen for the wake phrase with it.")
        case .onDeviceRecognizer:
            return OnDeviceRecognizerEngine(locale: locale, contextualStrings: contextualStrings)
        }
    }
}

// MARK: - SpeechAnalyzer

@available(macOS 26.0, *)
final class AnalyzerEngine: RecognitionEngine, @unchecked Sendable {
    let requestedLocale: Locale
    let contextualStrings: [String]
    private let lock = NSLock()
    private var resolvedLocale: Locale?

    init(locale: Locale, contextualStrings: [String]) {
        self.requestedLocale = locale
        self.contextualStrings = contextualStrings
    }

    var name: String { "SpeechAnalyzer (\(lock.withLock { resolvedLocale ?? requestedLocale }.identifier))" }
    /// SpeechAnalyzer is made for long audio; a session is still renewed every ten minutes, at a
    /// quiet moment, so that nothing it keeps can grow over a day of listening.
    var preferredSessionSeconds: Double { 600 }

    static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        // volatileResults: guesses while the words are still being spoken, so the phrase is seen
        // early. fastResults: lower delay at a small cost in accuracy, which suits two words.
        SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [])
    }

    func prepare(requestPermission: Bool) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw SpeakableError("On-device speech recognition isn't available on this Mac, so I can't listen for the wake phrase.")
        }
        // The Mac's language, or the nearest one Apple supports ("en_IN" stays "en_IN").
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            let language = Locale.current.localizedString(forIdentifier: requestedLocale.identifier) ?? requestedLocale.identifier
            throw SpeakableError("On-device speech recognition doesn't support \(language), so I can't listen for the wake phrase.")
        }
        let transcriber = Self.makeTranscriber(locale: locale)
        // The speech model is a system download. Fetching it sends no audio anywhere.
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .unsupported:
            throw SpeakableError("On-device speech recognition doesn't support this language, so I can't listen for the wake phrase.")
        case .installed:
            break
        case .supported, .downloading:
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
            } catch {
                throw SpeakableError("Apple's speech model for listening isn't downloaded yet. Connect to the internet once so it can download.")
            }
        @unknown default:
            break
        }
        lock.withLock { resolvedLocale = locale }
    }

    func makeSession(inputFormat: AVAudioFormat, callbacks: RecognitionCallbacks) async throws -> RecognitionSession {
        let locale = lock.withLock { resolvedLocale ?? requestedLocale }
        return try await AnalyzerSession.make(
            locale: locale, contextualStrings: contextualStrings, inputFormat: inputFormat, callbacks: callbacks)
    }
}

@available(macOS 26.0, *)
final class AnalyzerSession: RecognitionSession, @unchecked Sendable {
    private let analyzer: SpeechAnalyzer
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let converter: AudioConverter
    private var resultsTask: Task<Void, Never>?

    private init(analyzer: SpeechAnalyzer, continuation: AsyncStream<AnalyzerInput>.Continuation, converter: AudioConverter) {
        self.analyzer = analyzer
        self.continuation = continuation
        self.converter = converter
    }

    static func make(
        locale: Locale, contextualStrings: [String], inputFormat: AVAudioFormat, callbacks: RecognitionCallbacks
    ) async throws -> AnalyzerSession {
        let transcriber = AnalyzerEngine.makeTranscriber(locale: locale)
        guard
            let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber], considering: inputFormat),
            let converter = AudioConverter(from: inputFormat, to: analyzerFormat)
        else { throw SpeakableError("The microphone's sound format isn't one the speech recogniser can use.") }

        // Bounded, so a stalled recogniser can never make memory grow: the oldest audio is dropped.
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .bufferingNewest(128))
        // processLifetime: keep the model loaded between sessions, so listening resumes at once
        // after each conversation instead of reloading it.
        let analyzer = SpeechAnalyzer(
            modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        let session = AnalyzerSession(analyzer: analyzer, continuation: continuation, converter: converter)
        do {
            if !contextualStrings.isEmpty {
                // Tells the recogniser to expect the phrase's words, so "Handsfree" is heard as a word.
                let context = AnalysisContext()
                context.contextualStrings[.general] = contextualStrings
                try await analyzer.setContext(context)
            }
            try await analyzer.prepareToAnalyze(in: analyzerFormat)
            session.resultsTask = Task {
                do {
                    for try await result in transcriber.results {
                        // A segment is a stretch of audio: guesses and the final text for the same
                        // stretch share its start time.
                        let segment = Int((result.range.start.seconds * 100).rounded())
                        callbacks.onTranscript(segment, String(result.text.characters), result.isFinal)
                    }
                    if !Task.isCancelled { callbacks.onEnded(nil) }
                } catch {
                    if !Task.isCancelled { callbacks.onEnded(error) }
                }
            }
            try await analyzer.start(inputSequence: stream)
        } catch {
            // Leave nothing running behind a session that never started.
            await session.cancel()
            throw error
        }
        return session
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = converter.convert(buffer) else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    func cancel() async {
        resultsTask?.cancel()
        continuation.finish()
        await analyzer.cancelAndFinishNow()
    }
}

/// Converts microphone audio (often 48 kHz, 32-bit float) to what the recogniser wants
/// (16 kHz, 16-bit, mono). It keeps its state between buffers, so the stream stays continuous.
final class AudioConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    let outputFormat: AVAudioFormat

    init?(from input: AVAudioFormat, to output: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: input, to: output) else { return nil }
        self.converter = converter
        self.outputFormat = output
    }

    /// Always returns a new buffer, so the result can outlive the microphone's buffer.
    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}

// MARK: - SFSpeechRecognizer, forced on-device

final class OnDeviceRecognizerEngine: RecognitionEngine, @unchecked Sendable {
    let locale: Locale
    let contextualStrings: [String]
    private let lock = NSLock()
    private var recognizer: SFSpeechRecognizer?

    init(locale: Locale, contextualStrings: [String]) {
        self.locale = locale
        self.contextualStrings = contextualStrings
    }

    var name: String { "SFSpeechRecognizer on-device (\(lock.withLock { recognizer?.locale ?? locale }.identifier))" }
    /// Apple's guidance for this recogniser is to plan for a one-minute limit per task.
    var preferredSessionSeconds: Double { 50 }

    func prepare(requestPermission: Bool) async throws {
        try await WakePermissions.requireSpeechRecognition(request: requestPermission)
        let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.supportsOnDeviceRecognition else {
            // Never fall back to Apple's servers: audio heard while asleep stays on the Mac.
            throw SpeakableError("Speech recognition on this Mac can't run offline for this language, so I won't listen for the wake phrase.")
        }
        lock.withLock { self.recognizer = recognizer }
    }

    func makeSession(inputFormat: AVAudioFormat, callbacks: RecognitionCallbacks) async throws -> RecognitionSession {
        guard let recognizer = lock.withLock({ recognizer }) else {
            throw SpeakableError("The speech recogniser wasn't ready.")
        }
        return OnDeviceRecognizerSession(recognizer: recognizer, contextualStrings: contextualStrings, callbacks: callbacks)
    }
}

final class OnDeviceRecognizerSession: RecognitionSession, @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest
    private var task: SFSpeechRecognitionTask?

    init(recognizer: SFSpeechRecognizer, contextualStrings: [String], callbacks: RecognitionCallbacks) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true  // never send audio to Apple's servers
        request.shouldReportPartialResults = true
        request.contextualStrings = contextualStrings
        request.taskHint = .search  // short commands rather than long dictation
        request.addsPunctuation = false
        self.request = request
        // One task is one growing transcript, so it is one segment.
        task = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                callbacks.onTranscript(0, result.bestTranscription.formattedString, result.isFinal)
                if result.isFinal { callbacks.onEnded(nil) }
            } else if let error {
                callbacks.onEnded(error)
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let copy = buffer.copied() else { return }
        request.append(copy)
    }

    func cancel() async {
        request.endAudio()
        task?.cancel()
        task = nil
    }
}

// MARK: - Permissions

/// The permissions waking needs, checked without changing any setting.
///
/// Microphone: always. Speech Recognition: only for the older recogniser (before macOS 26);
/// SpeechAnalyzer does not need it. For the app, the permissions belong to Handsfree.app; for the
/// command-line tool and tests they belong to the terminal's host app.
public enum WakePermissions {
    public enum State: String, Sendable {
        case granted
        case denied
        case notAsked = "not asked"
        case restricted
    }

    public static var microphone: State {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notAsked
        @unknown default: return .denied
        }
    }

    public static var speechRecognition: State {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notAsked
        @unknown default: return .denied
        }
    }

    /// True when this Mac will use the older recogniser, which needs Speech Recognition too.
    public static var needsSpeechRecognition: Bool {
        if #available(macOS 26.0, *), SpeechTranscriber.isAvailable { return false }
        return true
    }

    /// Who the permission belongs to, for the spoken message: the app, or the terminal.
    static var ownerName: String {
        if let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String, !name.isEmpty { return name }
        return "this terminal app"
    }

    /// Asks for the microphone if it has never been asked. Shows the system prompt; only the
    /// person at the Mac can answer it.
    @discardableResult
    public static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Asks for Speech Recognition if it has never been asked. Without the
    /// NSSpeechRecognitionUsageDescription key in the app's Info.plist macOS would end the app, so
    /// it refuses instead.
    public static func requestSpeechRecognition() async -> State {
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else { return speechRecognition }
        _ = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status) }
        }
        return speechRecognition
    }

    static func requireMicrophone(request: Bool) async throws {
        var state = microphone
        if state == .notAsked && request { state = await requestMicrophone() ? .granted : microphone }
        switch state {
        case .granted: return
        case .notAsked:
            throw SpeakableError("\(ownerName) hasn't been allowed to use the microphone yet, so I can't listen for the wake phrase. It needs to be allowed once at setup.")
        case .denied, .restricted:
            throw SpeakableError("\(ownerName) isn't allowed to use the microphone, so I can't listen for the wake phrase. Someone can turn it on in System Settings, Privacy and Security, Microphone.")
        }
    }

    static func requireSpeechRecognition(request: Bool) async throws {
        var state = speechRecognition
        if state == .notAsked && request { state = await requestSpeechRecognition() }
        switch state {
        case .granted: return
        case .notAsked:
            throw SpeakableError("\(ownerName) hasn't been allowed to use speech recognition yet, so I can't listen for the wake phrase. It needs to be allowed once at setup.")
        case .denied, .restricted:
            throw SpeakableError("\(ownerName) isn't allowed to use speech recognition, so I can't listen for the wake phrase. Someone can turn it on in System Settings, Privacy and Security, Speech Recognition.")
        }
    }
}
