import AVFoundation
import Foundation
import HFCore
import Speech

// Apple's on-device recogniser, run on the recorded turn. Audio never leaves the Mac.
//
// SpeechAnalyzer (macOS 26 and later) is used when the Mac has it: it needs no Speech
// Recognition permission and takes the keyterms as contextual strings. On older macOS,
// SFSpeechRecognizer is forced on-device; it needs the Speech Recognition permission. Patterns
// copied from HFWake/Engines.swift, not imported, so this package depends only on HFCore.
//
// The turn is heard again from its WAV even when `turn.liveTranscript` is filled: the live pass
// had no keyterms for this turn and used fast settings meant for catching "stop". Pass
// `useLiveTranscript: true` to return the live text instead.
//
// Cancelling the calling task (the time limit, or "stop") ends recognition at once and throws
// CancellationError. Every other failure is a SpeakableError.

/// Apple's on-device recogniser, with the hints' keyterms as contextual strings.
public struct AppleHearer: Hearing {
    /// At most this many keyterms are passed as contextual strings. Apple documents no limit, but
    /// a long list slows the recogniser and the most likely words come first.
    public static let maxKeyterms = 100
    static let stopped = SpeakableError("Apple's recogniser stopped before it finished.")

    public var name: HearerName { .apple }

    let useLiveTranscript: Bool

    /// - Parameter useLiveTranscript: when true and the turn already has a live transcript,
    ///   return it without listening again. False by default, so the keyterms are used.
    public init(useLiveTranscript: Bool = false) {
        self.useLiveTranscript = useLiveTranscript
    }

    /// Gets the recogniser ready before the person's first turn: downloads Apple's speech model
    /// for the language if needed (no audio is sent) and loads it by hearing a moment of silence.
    /// The very first load on a Mac was measured at over four minutes, so the app calls this at
    /// startup. Safe to call again; later calls return quickly.
    public static func prepare(languageCode: String = "en-GB") async throws {
        let locale = Locale(identifier: languageCode.isEmpty ? "en-GB" : languageCode)
        do {
            if #available(macOS 26.0, *), SpeechTranscriber.isAvailable {
                let silence = [Float](repeating: 0, count: Int(WAV.sampleRate / 2))
                guard let buffer = floatBuffer(silence, sampleRate: WAV.sampleRate) else { throw stopped }
                _ = try await AnalyzerFileRecognition.transcribe(buffer, locale: locale, keyterms: [])
            } else {
                _ = try OnDeviceFileRecognition.recognizer(for: locale)
            }
        } catch {
            throw failure(error)
        }
    }

    /// Recognises the turn's WAV on the device. Throws a `SpeakableError` when the recogniser is
    /// missing for the language, the audio cannot be read, or no words were heard.
    public func hear(_ turn: RecordedTurn, hints: HearingHints) async throws -> String {
        if useLiveTranscript {
            let live = turn.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !live.isEmpty { return live }
        }
        try Task.checkCancellation()
        guard let decoded = WAV.decode(turn.wav), !decoded.samples.isEmpty,
            let buffer = Self.floatBuffer(decoded.samples, sampleRate: decoded.sampleRate)
        else { throw SpeakableError("Apple's recogniser couldn't read that recording.") }
        let keyterms = Array(uniqueTerms(hints.keyterms).prefix(Self.maxKeyterms))
        let locale = Locale(identifier: hints.languageCode.isEmpty ? "en-GB" : hints.languageCode)

        let text: String
        do {
            if #available(macOS 26.0, *), SpeechTranscriber.isAvailable {
                text = try await AnalyzerFileRecognition.transcribe(buffer, locale: locale, keyterms: keyterms)
            } else {
                text = try await OnDeviceFileRecognition.transcribe(buffer, locale: locale, keyterms: keyterms)
            }
        } catch {
            throw Self.failure(error)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SpeakableError("Apple's recogniser heard no words.") }
        return trimmed
    }

    /// Cancellation and our own sentences pass through; anything else Apple throws becomes one
    /// plain sentence.
    static func failure(_ error: Error) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if error is SpeakableError { return error }
        understandLog.error("Apple recogniser failed: \(String(describing: error), privacy: .public)")
        return stopped
    }

    /// A mono 32-bit float buffer holding the samples.
    static func floatBuffer(_ samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }

    /// Converts a whole buffer to another format in one go.
    static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .endOfStream
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

// MARK: - SpeechAnalyzer

@available(macOS 26.0, *)
enum AnalyzerFileRecognition {
    /// Holds the analyzer so a cancel that arrives at any point can stop it.
    final class Holder: @unchecked Sendable {
        private let lock = NSLock()
        private var analyzer: SpeechAnalyzer?
        private var cancelled = false

        func set(_ analyzer: SpeechAnalyzer) {
            let stopNow = lock.withLock { () -> Bool in
                self.analyzer = analyzer
                return cancelled
            }
            if stopNow { Task { await analyzer.cancelAndFinishNow() } }
        }

        func cancel() {
            let running = lock.withLock { () -> SpeechAnalyzer? in
                cancelled = true
                return analyzer
            }
            if let running { Task { await running.cancelAndFinishNow() } }
        }
    }

    static func transcribe(_ buffer: AVAudioPCMBuffer, locale requested: Locale, keyterms: [String]) async throws -> String {
        let holder = Holder()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
                throw SpeakableError("Apple's recogniser doesn't support this language on this Mac.")
            }
            try Task.checkCancellation()
            // Final results only: this is a recording, so there is no point in early guesses.
            let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
            try await ensureModelInstalled(transcriber)
            try Task.checkCancellation()

            // processLifetime: keep the model loaded between turns, so each turn starts at once.
            let analyzer = SpeechAnalyzer(
                modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
            holder.set(analyzer)
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
                let converted = AppleHearer.convert(buffer, to: format)
            else { throw SpeakableError("Apple's recogniser couldn't use that recording's sound format.") }
            try Task.checkCancellation()

            if !keyterms.isEmpty {
                // Tells the recogniser to expect these words, so "Amma" is heard as a name.
                let context = AnalysisContext()
                context.contextualStrings[.general] = keyterms
                try await analyzer.setContext(context)
            }
            try await analyzer.prepareToAnalyze(in: format)
            // Start reading results before any audio goes in, so none are missed.
            let collector = Task { () throws -> String in
                var parts: [String] = []
                for try await result in transcriber.results where result.isFinal {
                    parts.append(String(result.text.characters))
                }
                return parts.joined(separator: " ")
            }
            do {
                let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
                continuation.yield(AnalyzerInput(buffer: converted))
                continuation.finish()
                try await analyzer.start(inputSequence: stream)
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                let text = try await collector.value
                try Task.checkCancellation()
                return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            } catch {
                collector.cancel()
                throw error
            }
        } onCancel: {
            holder.cancel()
        }
    }

    /// The speech model is a system download. Fetching it sends no audio anywhere.
    static func ensureModelInstalled(_ transcriber: SpeechTranscriber) async throws {
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            return
        case .unsupported:
            throw SpeakableError("Apple's recogniser doesn't support this language on this Mac.")
        case .supported, .downloading:
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw SpeakableError("Apple's speech model isn't downloaded yet. Connect to the internet once so it can download.")
            }
        @unknown default:
            return
        }
    }
}
