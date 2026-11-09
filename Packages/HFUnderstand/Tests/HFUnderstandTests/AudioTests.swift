import Foundation
import HFCore
import Testing
@testable import HFUnderstand

/// A sine tone, for audio tests.
func tone(seconds: Double, sampleRate: Double, frequency: Double = 440, level: Float = 0.5) -> [Float] {
    (0..<Int(seconds * sampleRate)).map { level * Float(sin(2 * .pi * frequency * Double($0) / sampleRate)) }
}

@Suite struct AudioTests {
    @Test func encodeWritesA16kMono16BitHeader() {
        let wav = WAV.encode(samples: tone(seconds: 0.5, sampleRate: 16_000), sampleRate: 16_000)
        #expect(wav.count == 44 + 8_000 * 2)
        #expect(String(decoding: wav[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
        let bytes = [UInt8](wav)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        #expect(u16(20) == 1)  // PCM
        #expect(u16(22) == 1)  // mono
        #expect(u32(24) == 16_000)
        #expect(u16(34) == 16)
        #expect(u32(40) == 16_000)  // data bytes
        #expect(abs(WAV.duration(of: wav) - 0.5) < 0.001)
    }

    @Test func encodeResamplesOtherRates() {
        let wav = WAV.encode(samples: tone(seconds: 1, sampleRate: 48_000), sampleRate: 48_000)
        let decoded = WAV.decode(wav)
        #expect(decoded?.sampleRate == 16_000)
        #expect(abs(WAV.duration(of: wav) - 1) < 0.01)
        // The tone survives: its loudness is about the same after resampling.
        let peak = decoded?.samples.dropFirst(100).dropLast(100).map(abs).max() ?? 0
        #expect(peak > 0.45 && peak < 0.55)
    }

    @Test func encodeClipsLoudAndBrokenSamples() {
        let wav = WAV.encode(samples: [2, -2, .nan, .infinity], sampleRate: 16_000)
        let samples = WAV.decode(wav)?.samples ?? []
        #expect(samples.count == 4)
        #expect(samples[0] == 1)
        #expect(samples[1] == -1)
        #expect(samples[2] == 0 && samples[3] == 0)
    }

    @Test func roundTripKeepsSamples() {
        let original = tone(seconds: 0.1, sampleRate: 16_000)
        let decoded = WAV.decode(WAV.encode(samples: original, sampleRate: 16_000))?.samples ?? []
        #expect(decoded.count == original.count)
        let worst = zip(original, decoded).map { abs($0 - $1) }.max() ?? 1
        #expect(worst < 0.0001)
    }

    @Test func decodeRefusesSomethingThatIsNotAWAV() {
        #expect(WAV.decode(Data("hello there, not audio".utf8)) == nil)
        #expect(WAV.duration(of: Data()) == 0)
    }

    @Test func loadConvertsAStereo44kFileTo16kMono() throws {
        // A stereo 44.1 kHz WAV written by hand: left a tone, right silent.
        let rate = 44_100.0
        let left = tone(seconds: 0.25, sampleRate: rate)
        var data = Data()
        let byteCount = UInt32(left.count * 4)
        data.append(contentsOf: Array("RIFF".utf8)); data.appendLittleEndian(UInt32(36) + byteCount)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1)); data.appendLittleEndian(UInt16(2))
        data.appendLittleEndian(UInt32(rate)); data.appendLittleEndian(UInt32(rate) * 4)
        data.appendLittleEndian(UInt16(4)); data.appendLittleEndian(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); data.appendLittleEndian(byteCount)
        for sample in left {
            data.appendLittleEndian(UInt16(bitPattern: Int16(sample * Float(Int16.max))))
            data.appendLittleEndian(UInt16(0))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hf-audio-\(UUID().uuidString).wav")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let turn = try WAV.load(contentsOf: url)
        #expect(turn.source == url.lastPathComponent)
        #expect(turn.liveTranscript.isEmpty)
        #expect(abs(turn.durationSeconds - 0.25) < 0.01)
        let decoded = try #require(WAV.decode(turn.wav))
        #expect(decoded.sampleRate == 16_000)
        // Mixed to mono: half the left channel's level.
        let peak = decoded.samples.dropFirst(100).dropLast(100).map(abs).max() ?? 0
        #expect(peak > 0.2 && peak < 0.3)
    }

    @Test func loadExplainsAMissingFile() {
        #expect(throws: SpeakableError.self) {
            try WAV.load(contentsOf: URL(fileURLWithPath: "/nonexistent/clip.wav"))
        }
    }
}
