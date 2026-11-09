import AVFoundation
import Foundation

// Audio helpers for the turn recorder: a rolling store of the last half-minute of 16 kHz
// samples, loudness in decibels, turning microphone buffers into 16 kHz mono, and WAV encoding.
// The names start with "TurnRecorder" so they never clash with other files in this package.

/// The last `capacitySeconds` of 16 kHz mono audio, with its place on the audio clock.
/// A turn is cut out of it once the detector says where the turn starts and ends.
struct TurnRecorderSampleStore {
    static let sampleRate: Double = 16_000
    private(set) var samples: [Float] = []
    /// Audio time, in seconds, of `samples[0]`.
    private(set) var startTime: Double = 0
    let capacitySeconds: Double

    init(capacitySeconds: Double) { self.capacitySeconds = capacitySeconds }

    /// Seconds of audio stored so far, from the start of recording.
    var endTime: Double { startTime + Double(samples.count) / Self.sampleRate }

    mutating func append(_ more: [Float]) {
        samples.append(contentsOf: more)
        let capacity = Int(capacitySeconds * Self.sampleRate)
        // Drop in big steps (a second at a time), so the array is not shifted on every buffer.
        if samples.count > capacity + Int(Self.sampleRate) {
            let drop = samples.count - capacity
            samples.removeFirst(drop)
            startTime += Double(drop) / Self.sampleRate
        }
    }

    /// The samples between two audio times, clipped to what is stored.
    func slice(from start: Double, to end: Double) -> [Float] {
        let first = max(0, Int(((start - startTime) * Self.sampleRate).rounded()))
        let last = min(samples.count, Int(((end - startTime) * Self.sampleRate).rounded()))
        guard last > first else { return [] }
        return Array(samples[first..<last])
    }
}

enum TurnRecorderLevels {
    /// Loudness of some samples in dBFS: 0 is the loudest possible, silence is about -100.
    static func decibels(_ samples: ArraySlice<Float>) -> Double {
        guard !samples.isEmpty else { return -100 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        let rms = (sum / Float(samples.count)).squareRoot()
        return max(-100, 20 * log10(Double(max(rms, 1e-5))))
    }
}

/// Turns microphone buffers (often 48 kHz, and several channels when voice processing is on)
/// into 16 kHz mono. With voice processing, macOS reports extra channels; the first is the
/// cleaned-up voice, so only that one is used rather than mixing them all together.
final class TurnRecorderResampler {
    let monoFormat: AVAudioFormat
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: TurnRecorderSampleStore.sampleRate, channels: 1, interleaved: false)!
    private let converter: AVAudioConverter

    init?(inputSampleRate: Double) {
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputSampleRate, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: mono, to: outputFormat)
        else { return nil }
        self.monoFormat = mono
        self.converter = converter
    }

    /// The first channel of `buffer`, as a mono buffer at the input rate (what the live
    /// recogniser is given). Nil for a format it cannot read.
    func firstChannel(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0, let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
            let destination = mono.floatChannelData?[0]
        else { return nil }
        mono.frameLength = buffer.frameLength
        let frames = Int(buffer.frameLength)
        if let source = buffer.floatChannelData?[0] {
            if buffer.format.isInterleaved {
                let stride = Int(buffer.format.channelCount)
                for index in 0..<frames { destination[index] = source[index * stride] }
            } else {
                destination.update(from: source, count: frames)
            }
        } else if let source = buffer.int16ChannelData?[0] {
            let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
            for index in 0..<frames { destination[index] = Float(source[index * stride]) / 32768 }
        } else {
            return nil
        }
        return mono
    }

    /// A mono buffer at the input rate, as 16 kHz samples.
    func resample(_ mono: AVAudioPCMBuffer) -> [Float] {
        let ratio = outputFormat.sampleRate / mono.format.sampleRate
        let capacity = AVAudioFrameCount((Double(mono.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return mono
        }
        guard status != .error, let data = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
    }
}

enum TurnRecorderWAV {
    /// A WAV file: 16-bit PCM, mono, at `sampleRate`. What every recogniser accepts.
    static func encode(_ samples: [Float], sampleRate: Int = 16_000) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let payload = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + payload)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))  // size of this chunk
        append(UInt16(1))  // PCM
        append(UInt16(1))  // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))  // bytes per second
        append(UInt16(2))  // bytes per frame
        append(UInt16(16))  // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(payload)
        for sample in samples {
            let clipped = max(-1, min(1, sample))
            append(Int16((clipped * 32767).rounded()))
        }
        return data
    }
}
