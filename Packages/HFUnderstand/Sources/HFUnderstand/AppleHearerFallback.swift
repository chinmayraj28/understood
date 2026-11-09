import AVFoundation
import Foundation
import HFCore
import Speech

// AppleHearer's path for Macs before macOS 26: SFSpeechRecognizer, forced on-device. It needs the
// Speech Recognition permission, which only the person at the Mac can give.

enum OnDeviceFileRecognition {
    /// The on-device recogniser for the language, or a spoken reason there is none.
    static func recognizer(for locale: Locale) throws -> SFSpeechRecognizer {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw SpeakableError("This app isn't allowed to use speech recognition, so Apple's recogniser can't help hear you.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            // Never fall back to Apple's servers: the person's voice stays on the Mac.
            throw SpeakableError("Apple's recogniser can't run offline for this language on this Mac.")
        }
        return recognizer
    }

    static func transcribe(_ buffer: AVAudioPCMBuffer, locale: Locale, keyterms: [String]) async throws -> String {
        try Task.checkCancellation()
        let recognizer = try recognizer(for: locale)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.contextualStrings = keyterms
        request.taskHint = .search  // short commands rather than long dictation
        request.addsPunctuation = false
        request.append(buffer)
        request.endAudio()

        let box = RecognitionBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                box.setContinuation(continuation)
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        box.finish(.success(result.bestTranscription.formattedString))
                    } else if let error {
                        // "No speech detected" is an empty transcript; anything else is a failure.
                        box.finish(isNoSpeech(error) ? .success("") : .failure(AppleHearer.stopped))
                    }
                }
                box.setTask(task)
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// Apple reports silence as an error in its assistant domain, code 1110.
    static func isNoSpeech(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == "kAFAssistantErrorDomain" && error.code == 1110
    }

    /// The recognition task and the waiting continuation, behind one lock, so a cancel can arrive
    /// before, during or after the task starts and the continuation is resumed exactly once.
    final class RecognitionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: SFSpeechRecognitionTask?
        private var continuation: CheckedContinuation<String, Error>?
        private var cancelled = false

        func setContinuation(_ continuation: CheckedContinuation<String, Error>) {
            let alreadyCancelled = lock.withLock { () -> Bool in
                self.continuation = continuation
                return cancelled
            }
            if alreadyCancelled { finish(.failure(CancellationError())) }
        }

        func setTask(_ task: SFSpeechRecognitionTask) {
            let alreadyCancelled = lock.withLock { () -> Bool in
                self.task = task
                return cancelled
            }
            if alreadyCancelled { task.cancel() }
        }

        func cancel() {
            let running = lock.withLock { () -> SFSpeechRecognitionTask? in
                cancelled = true
                return task
            }
            running?.cancel()
            finish(.failure(CancellationError()))
        }

        func finish(_ result: Result<String, Error>) {
            let pending = lock.withLock { () -> CheckedContinuation<String, Error>? in
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(with: result)
        }
    }
}
