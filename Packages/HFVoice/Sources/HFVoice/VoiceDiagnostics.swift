import Foundation
import LiveKit

/// What the audio engine is doing about echo, for the settings panel and the live audio test.
///
/// Voice sessions play the agent through LiveKit's AVAudioEngine, whose input on
/// macOS is Apple's voice-processing unit: the echo canceller that stops the
/// agent hearing itself through laptop speakers. This reports what is applied.
public enum VoiceDiagnostics {
    @MainActor
    public static func echoCancellationReport() -> String {
        let manager = AudioManager.shared
        let platform = manager.platformVoiceProcessingState
        return [
            "platform voice processing allowed: \(manager.isPlatformVoiceProcessingAllowed)",
            "voice processing bypassed: \(manager.isVoiceProcessingBypassed)",
            "platform state: \(platform)",
            "resolved processing: \(manager.audioProcessingState)",
        ].joined(separator: "\n")
    }

    /// True while LiveKit's audio engine runs, which in voice mode means it holds the microphone.
    /// After a voice session closes this should be false, so the wake listener can use the microphone.
    @MainActor
    public static var isAudioEngineRunning: Bool { AudioManager.shared.isEngineRunning }

    /// How many SDK conversations this process created are still in memory, and how many of
    /// those are still connected. Both should be 0 once every session has closed.
    @MainActor
    public static var leftoverConversations: (inMemory: Int, active: Int) {
        (ElevenLabsDriver.conversationsStillInMemory, ElevenLabsDriver.conversationsStillActive)
    }
}

// MARK: - Measurements

import AVFoundation

extension VoiceDiagnostics {
    /// For measurements only: mixes a sound file into what the microphone sends, as if
    /// someone said it, and returns where in the file the speech starts and ends, in seconds.
    /// Needs an active voice session.
    @MainActor
    public static func playIntoMicrophone(_ file: URL) throws -> (start: TimeInterval, end: TimeInterval) {
        let audio = try AVAudioFile(forReading: file)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try audio.read(into: buffer)
        AudioManager.shared.mixer.capture(appAudio: buffer)
        return speechSpan(in: buffer)
    }

    /// For measurements only: 0 silences the real microphone, 1 restores it.
    @MainActor
    public static func setRoomMicrophoneVolume(_ volume: Float) {
        AudioManager.shared.mixer.micVolume = volume
    }

    /// Where the sound is above about -30 dB: first and last such sample, in seconds.
    static func speechSpan(in buffer: AVAudioPCMBuffer) -> (start: TimeInterval, end: TimeInterval) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return (0, 0) }
        let loud = (0..<Int(buffer.frameLength)).filter { abs(samples[$0]) > 0.03 }
        let rate = buffer.format.sampleRate
        return (Double(loud.first ?? 0) / rate, Double(loud.last ?? 0) / rate)
    }
}
