import AVFoundation
import Foundation
import HFCore

/// Plays a sound file into the recogniser at normal speed, as if it came from the microphone.
///
/// For testing the real recogniser on this Mac without a microphone, without a permission and
/// without making a sound: `say -o phrase.aiff "Hey Handsfree"` writes the phrase to a file, and
/// this feeds it in. Silence is added before (so the recogniser has settled) and after (so the
/// wake can happen with nothing more arriving, as when a person stops speaking).
final class FileAudioInput: AudioInput, @unchecked Sendable {
    let url: URL
    let leadingSilence: Double
    let trailingSilence: Double
    /// Called with the steady-clock time at which the file's own audio ended.
    let onAudioEnded: @Sendable (Double) -> Void

    private let lock = NSLock()
    /// Each start gets a number; a playback thread stops as soon as the number moves on.
    private var playbackID = 0
    private var file: AVAudioFile?

    init(url: URL, leadingSilence: Double, trailingSilence: Double, onAudioEnded: @escaping @Sendable (Double) -> Void) {
        self.url = url
        self.leadingSilence = leadingSilence
        self.trailingSilence = trailingSilence
        self.onAudioEnded = onAudioEnded
    }

    func checkPermission(request: Bool) async throws {}

    func prepare() throws -> AVAudioFormat {
        do {
            let file = try AVAudioFile(forReading: url)
            lock.withLock { self.file = file }
            return file.processingFormat
        } catch {
            throw SpeakableError("I couldn't read the sound file.")
        }
    }

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void, onInterrupted: @escaping (String) -> Void) throws {
        guard let file = lock.withLock({ file }) else { throw SpeakableError("The sound file wasn't ready.") }
        let format = file.processingFormat
        let chunk: AVAudioFrameCount = 4096
        let myID = lock.withLock { () -> Int in
            playbackID += 1
            return playbackID
        }
        let thread = Thread { [weak self] in
            guard let self else { return }
            var isStopped: Bool { self.lock.withLock { self.playbackID != myID } }
            let started = ProcessInfo.processInfo.systemUptime
            var delivered = 0.0  // seconds of audio handed over so far
            func pace() {
                // Hand over audio no faster than it would arrive from a microphone.
                let wait = started + delivered - ProcessInfo.processInfo.systemUptime
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            }
            func silence(_ seconds: Double) {
                var remaining = AVAudioFrameCount(seconds * format.sampleRate)
                while remaining > 0, !isStopped {
                    let frames = min(chunk, remaining)
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
                    buffer.frameLength = frames
                    for audio in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                        if let data = audio.mData { memset(data, 0, Int(audio.mDataByteSize)) }
                    }
                    onBuffer(buffer)
                    delivered += Double(frames) / format.sampleRate
                    remaining -= frames
                    pace()
                }
            }
            silence(self.leadingSilence)
            file.framePosition = 0
            while !isStopped {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
                    (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0
                else { break }
                onBuffer(buffer)
                delivered += Double(buffer.frameLength) / format.sampleRate
                pace()
            }
            if !isStopped { self.onAudioEnded(ProcessInfo.processInfo.systemUptime) }
            silence(self.trailingSilence)
        }
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func stop() {
        lock.withLock { playbackID += 1 }
    }
}

extension WakeListener {
    /// A listener that hears a sound file instead of the microphone, through the same real
    /// on-device recogniser. For testing only: no sound is played and no permission is needed.
    /// Each `start` plays the file again from the beginning.
    ///
    /// - Parameters:
    ///   - leadingSilence: seconds of silence before the file.
    ///   - trailingSilence: seconds of silence after it.
    ///   - onAudioEnded: told when the file's own audio has been fed in, on the steady clock
    ///     (`ProcessInfo.systemUptime`), for measuring the delay from the end of the phrase to the wake.
    public convenience init(
        configuration: Configuration,
        replaying url: URL,
        leadingSilence: Double = 1,
        trailingSilence: Double = 4,
        onAudioEnded: @escaping @Sendable (Double) -> Void = { _ in }
    ) {
        self.init(configuration: configuration) {
            let engine = try RecognitionEngines.make(
                configuration.recognizer, locale: configuration.locale,
                contextualStrings: configuration.contextualStrings)
            let input = FileAudioInput(
                url: url, leadingSilence: leadingSilence, trailingSilence: trailingSilence, onAudioEnded: onAudioEnded)
            return StreamingTranscriber(input: input, engine: engine, requestPermission: false)
        }
    }
}
