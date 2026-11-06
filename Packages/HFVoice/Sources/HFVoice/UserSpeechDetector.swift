import Foundation

/// Decides, from the server's voice-activity scores, whether the user is speaking right now.
///
/// The screen agent checks this before each new action and holds while it is true,
/// so the pointer stops taking new actions the moment the user starts to talk,
/// long before the final transcript (about 0.9 s after the last word) arrives.
///
/// It turns true when a score reaches `threshold`, and stays true:
/// - for `tail` seconds after the last high score, so pauses between words do not flicker it;
/// - and after that until the transcript for the utterance has reached the transcript
///   listeners (the stop watcher), but at most `transcriptWait` seconds, so a cough or
///   a noise that never becomes a transcript cannot hold the screen agent for ever.
///
/// Pure and clock-driven, so it is easy to test. `VoiceSession` keeps one behind a lock.
struct UserSpeechDetector: Sendable {
    struct Settings: Sendable {
        /// Speech scored 0.93 to 1.0 in the measurements; the agent's own voice through the
        /// speakers, with voice processing on, peaked at 0.11. 0.5 sits well between them.
        var threshold: Double = 0.5
        var tail: TimeInterval = 0.5
        var transcriptWait: TimeInterval = 3.0
    }

    var settings = Settings()
    private(set) var speakingSince: TimeInterval?
    private var lastVoiceAt: TimeInterval = -.infinity
    private var awaitingTranscript = false

    /// Forgets everything heard, keeping the settings. Called when a conversation closes,
    /// so a sentence cut off by the close cannot hold the screen agent afterwards.
    mutating func reset() {
        speakingSince = nil
        lastVoiceAt = -.infinity
        awaitingTranscript = false
    }

    /// A voice-activity score from the server.
    mutating func heard(level: Double, at now: TimeInterval) {
        guard level >= settings.threshold else { return }
        voiceDetected(at: now)
    }

    /// The server's interruption event: it also means the user started talking.
    mutating func voiceDetected(at now: TimeInterval) {
        if !isSpeaking(at: now) { speakingSince = now }
        lastVoiceAt = now
        awaitingTranscript = true
    }

    /// The transcript for the utterance has been handed to every transcript listener.
    mutating func transcriptDelivered(at now: TimeInterval) {
        awaitingTranscript = false
        if now - lastVoiceAt > settings.tail { speakingSince = nil }
    }

    func isSpeaking(at now: TimeInterval) -> Bool {
        guard speakingSince != nil else { return false }
        let silentFor = now - lastVoiceAt
        if silentFor <= settings.tail { return true }
        return awaitingTranscript && silentFor <= settings.transcriptWait
    }
}
