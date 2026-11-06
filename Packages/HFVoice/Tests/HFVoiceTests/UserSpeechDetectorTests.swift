import Testing

@testable import HFVoice

@Suite struct UserSpeechDetectorTests {
    @Test func turnsTrueAtTheThreshold() {
        var detector = UserSpeechDetector()
        detector.heard(level: 0.3, at: 0)
        #expect(!detector.isSpeaking(at: 0))
        detector.heard(level: 0.6, at: 0.1)
        #expect(detector.isSpeaking(at: 0.1))
        #expect(detector.speakingSince == 0.1)
    }

    @Test func theAgentsOwnVoiceThroughTheSpeakersDoesNotTripIt() {
        // With voice processing on, the agent's voice reached the server as at most 0.11.
        var detector = UserSpeechDetector()
        for step in 0..<100 { detector.heard(level: 0.11, at: Double(step) * 0.1) }
        #expect(!detector.isSpeaking(at: 10))
    }

    @Test func staysTrueBetweenWordsAndUntilTheTranscriptIsDelivered() {
        var detector = UserSpeechDetector()
        detector.heard(level: 0.95, at: 0)
        detector.heard(level: 0.95, at: 0.4)
        #expect(detector.isSpeaking(at: 0.8), "a pause between words")
        #expect(detector.isSpeaking(at: 2.0), "speech ended; waiting for the transcript")
        detector.transcriptDelivered(at: 2.1)
        #expect(!detector.isSpeaking(at: 2.1))
    }

    @Test func aNoiseThatNeverBecomesATranscriptLetsGo() {
        var detector = UserSpeechDetector()
        detector.heard(level: 0.9, at: 0)
        #expect(detector.isSpeaking(at: 2.9))
        #expect(!detector.isSpeaking(at: 3.1))
    }

    @Test func aTranscriptWhileStillTalkingKeepsItTrue() {
        var detector = UserSpeechDetector()
        detector.heard(level: 0.9, at: 0)
        detector.heard(level: 0.9, at: 1.0)
        detector.transcriptDelivered(at: 1.1)  // the first sentence; the user goes on talking
        #expect(detector.isSpeaking(at: 1.2))
        #expect(!detector.isSpeaking(at: 1.6))
    }

    @Test func aNewUtteranceStartsAgain() {
        var detector = UserSpeechDetector()
        detector.heard(level: 0.9, at: 0)
        detector.transcriptDelivered(at: 1)
        detector.heard(level: 0.9, at: 5)
        #expect(detector.isSpeaking(at: 5))
        #expect(detector.speakingSince == 5)
    }

    @Test func anInterruptionCountsAsSpeech() {
        var detector = UserSpeechDetector()
        detector.voiceDetected(at: 0)
        #expect(detector.isSpeaking(at: 0.2))
    }
}
