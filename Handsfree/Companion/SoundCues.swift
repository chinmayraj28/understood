//
//  SoundCues.swift
//  Handsfree
//
//  The short sounds for waking and going to sleep. Many users will not be
//  looking at the screen, so they need to hear when it starts listening and
//  when it stops. Two parts, both pure and unit tested:
//
//  - SoundCueRules decides, from the ActivityBus events, when a sound plays.
//  - CueTone builds each sound in code, as WAV data (nothing is copied from
//    Clicky's assets or anyone else's).
//
//  CuePlayer.swift plays them. New for Handsfree.
//

import Foundation
import HFCore

/// The three sounds.
enum SoundCue: String, CaseIterable, Equatable {
    /// Two soft rising notes: the conversation is open and it can hear you now.
    case listening
    /// Two softer falling notes: it has gone back to sleep and stopped listening to you.
    case asleep
    /// Two low notes: it heard the phrase but could not open a conversation.
    case problem
}

/// When each sound plays.
///
/// - The rising sound plays when the conversation is ready to hear, not when the phrase is
///   heard. One sound with one meaning, "speak now", is easier to learn than two, and a user
///   who waits for it never loses their first words to a conversation still connecting.
///   The companion shows "waking" the moment the phrase is heard, for those who look.
/// - The falling sound plays when it goes back to sleep after a conversation, never at launch.
/// - The low sound plays when a wake gives up: it goes back to sleep without ever having been
///   able to hear. Not on a first failed attempt, because the session retries at once and often
///   connects: "failed" followed by "speak now" would only confuse.
struct SoundCueRules: Equatable {
    private enum Phase: Equatable { case unknown, asleep, waking, awake }
    private var phase: Phase = .unknown

    mutating func cue(for event: ActivityEvent) -> SoundCue? {
        switch event {
        case .asleep:
            defer { phase = .asleep }
            switch phase {
            case .awake: return .asleep
            case .waking: return .problem  // the wake gave up
            case .unknown, .asleep: return nil
            }
        case .waking:
            phase = .waking
            return nil
        case .listening:
            let wasWaking = phase == .waking
            phase = .awake
            return wasWaking ? .listening : nil
        default:
            return nil
        }
    }
}

/// Builds the sounds: short sine notes with a soft attack and decay, as 16-bit mono WAV.
enum CueTone {
    struct Note: Equatable {
        var frequency: Double
        var seconds: Double
        /// 0...1 of full scale.
        var loudness: Double
    }

    static let sampleRate = 44_100

    static func notes(for cue: SoundCue) -> [Note] {
        switch cue {
        case .listening:
            // E5 then A5: up a fourth, bright and short.
            return [Note(frequency: 659.26, seconds: 0.09, loudness: 0.32), Note(frequency: 880.0, seconds: 0.14, loudness: 0.32)]
        case .asleep:
            // A5 then E5, quieter: the same two notes falling back down.
            return [Note(frequency: 880.0, seconds: 0.09, loudness: 0.22), Note(frequency: 659.26, seconds: 0.16, loudness: 0.22)]
        case .problem:
            // Two low, equal notes.
            return [Note(frequency: 311.13, seconds: 0.12, loudness: 0.3), Note(frequency: 311.13, seconds: 0.12, loudness: 0.3)]
        }
    }

    /// Silence between notes.
    static let gapSeconds = 0.035

    /// The samples, -1...1.
    static func samples(for cue: SoundCue) -> [Double] {
        var samples: [Double] = []
        let notes = notes(for: cue)
        for (index, note) in notes.enumerated() {
            let count = Int(note.seconds * Double(sampleRate))
            let attack = Int(0.008 * Double(sampleRate))
            for sampleIndex in 0..<count {
                let time = Double(sampleIndex) / Double(sampleRate)
                // A little of the second harmonic makes it rounder than a pure sine.
                let wave = sin(2 * .pi * note.frequency * time) + 0.18 * sin(4 * .pi * note.frequency * time)
                let rise = min(1, Double(sampleIndex) / Double(max(attack, 1)))
                let fall = exp(-3.2 * Double(sampleIndex) / Double(count))
                samples.append(wave / 1.18 * note.loudness * rise * fall)
            }
            if index < notes.count - 1 {
                samples.append(contentsOf: repeatElement(0, count: Int(gapSeconds * Double(sampleRate))))
            }
        }
        // End on a few milliseconds of silence so the speaker does not click.
        samples.append(contentsOf: repeatElement(0, count: Int(0.01 * Double(sampleRate))))
        return samples
    }

    /// A complete WAV file in memory.
    static func wavData(for cue: SoundCue) -> Data {
        let samples = samples(for: cue)
        var data = Data()
        func append<Value: FixedWidthInteger>(_ value: Value) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let bytesPerSample = 2
        let dataSize = UInt32(samples.count * bytesPerSample)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1))  // PCM
        append(UInt16(1))  // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * bytesPerSample))
        append(UInt16(bytesPerSample))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(dataSize)
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * Double(Int16.max)))
        }
        return data
    }
}
