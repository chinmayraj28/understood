import AVFoundation
import Foundation
import HFCore

// WAV helpers. Every recogniser in this package is sent the same thing: a WAV file at 16 kHz,
// mono, 16-bit. That is small (32 KB a second), and ElevenLabs, OpenRouter and Apple all accept it.

/// Reads, writes and converts the 16 kHz mono 16-bit WAV audio the recognisers are sent.
public enum WAV {
    /// The sample rate every recording is converted to.
    public static let sampleRate: Double = 16_000

    /// Opens any audio file AVFoundation can read (WAV, AIFF, M4A, MP3, CAF and others) and
    /// converts it to 16 kHz mono 16-bit WAV. `source` is the file name.
    public static func load(contentsOf url: URL) throws -> RecordedTurn {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw SpeakableError("I couldn't open the sound file \(url.lastPathComponent).")
        }
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0 else { throw SpeakableError("The sound file \(url.lastPathComponent) is empty.") }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw SpeakableError("I couldn't read the sound file \(url.lastPathComponent).")
        }
        do {
            try file.read(into: buffer)
        } catch {
            throw SpeakableError("I couldn't read the sound file \(url.lastPathComponent).")
        }
        let samples = monoSamples(buffer)
        let wav = encode(samples: samples, sampleRate: format.sampleRate)
        return RecordedTurn(wav: wav, durationSeconds: duration(of: wav), source: url.lastPathComponent)
    }

    /// Mono samples from -1 to 1 in, 16 kHz mono 16-bit WAV bytes out. Audio at another rate is
    /// resampled first.
    public static func encode(samples: [Float], sampleRate: Double) -> Data {
        let resampled = sampleRate == Self.sampleRate ? samples : resample(samples, from: sampleRate, to: Self.sampleRate)
        var data = Data(capacity: 44 + resampled.count * 2)
        let byteCount = UInt32(resampled.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLittleEndian(UInt32(36) + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.appendLittleEndian(UInt32(16))  // size of the format block
        data.appendLittleEndian(UInt16(1))  // plain PCM
        data.appendLittleEndian(UInt16(1))  // one channel
        data.appendLittleEndian(UInt32(Self.sampleRate))
        data.appendLittleEndian(UInt32(Self.sampleRate) * 2)  // bytes a second
        data.appendLittleEndian(UInt16(2))  // bytes a frame
        data.appendLittleEndian(UInt16(16))  // bits a sample
        data.append(contentsOf: Array("data".utf8))
        data.appendLittleEndian(byteCount)
        for sample in resampled {
            let clipped = max(-1, min(1, sample.isFinite ? sample : 0))
            data.appendLittleEndian(UInt16(bitPattern: Int16((clipped * Float(Int16.max)).rounded())))
        }
        return data
    }

    /// The samples of a 16-bit PCM WAV (any rate, any number of channels, mixed down to mono),
    /// with its sample rate. Nil when the bytes are not a WAV file of that kind.
    public static func decode(_ wav: Data) -> (samples: [Float], sampleRate: Double)? {
        let bytes = [UInt8](wav)
        guard bytes.count >= 12, String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF",
            String(decoding: bytes[8..<12], as: UTF8.self) == "WAVE"
        else { return nil }
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }

        var channels = 0, rate = 0, bits = 0, formatTag = 0
        var offset = 12
        // A WAV file is a list of blocks; walk them to find "fmt " and "data".
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            let size = u32(offset + 4)
            let body = offset + 8
            if id == "fmt ", body + 16 <= bytes.count {
                formatTag = u16(body)
                channels = u16(body + 2)
                rate = u32(body + 4)
                bits = u16(body + 14)
            } else if id == "data" {
                // 1 is plain PCM; 0xFFFE is the extended header, still PCM for 16-bit audio.
                guard formatTag == 1 || formatTag == 0xFFFE, bits == 16, channels > 0, rate > 0 else { return nil }
                let end = min(bytes.count, body + size)
                let frameBytes = 2 * channels
                let frameCount = max(0, end - body) / frameBytes
                var samples = [Float](repeating: 0, count: frameCount)
                for frame in 0..<frameCount {
                    var sum: Float = 0
                    for channel in 0..<channels {
                        let at = body + frame * frameBytes + channel * 2
                        sum += Float(Int16(bitPattern: UInt16(u16(at)))) / Float(Int16.max)
                    }
                    samples[frame] = sum / Float(channels)
                }
                return (samples, Double(rate))
            }
            offset = body + size + (size % 2)  // blocks are padded to an even length
        }
        return nil
    }

    /// Seconds of audio in a WAV made by `encode`, or by any 16-bit PCM WAV. Zero when unreadable.
    public static func duration(of wav: Data) -> Double {
        guard let decoded = decode(wav), decoded.sampleRate > 0 else { return 0 }
        return Double(decoded.samples.count) / decoded.sampleRate
    }

    // MARK: - Helpers

    /// Averages the channels of a float buffer into one.
    static func monoSamples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0, let data = buffer.floatChannelData else { return [] }
        var mono = [Float](repeating: 0, count: frames)
        let interleaved = buffer.format.isInterleaved
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels {
                sum += interleaved ? data[0][frame * channels + channel] : data[channel][frame]
            }
            mono[frame] = sum / Float(channels)
        }
        return mono
    }

    /// Changes the sample rate with Apple's converter, which filters before it drops samples, so
    /// 48 kHz microphone audio does not pick up hiss. Falls back to straight-line interpolation if
    /// the converter cannot be made.
    static func resample(_ samples: [Float], from inputRate: Double, to outputRate: Double) -> [Float] {
        guard !samples.isEmpty, inputRate > 0, outputRate > 0 else { return [] }
        guard
            let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false),
            let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputRate, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
            let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return interpolate(samples, from: inputRate, to: outputRate) }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }

        var output: [Float] = []
        output.reserveCapacity(Int(Double(samples.count) * outputRate / inputRate) + 64)
        var supplied = false
        // The converter hands back audio in chunks; keep asking until it says the input is used up.
        while true {
            guard let chunk = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else { break }
            var error: NSError?
            let status = converter.convert(to: chunk, error: &error) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return input
            }
            if status == .error { return interpolate(samples, from: inputRate, to: outputRate) }
            if chunk.frameLength > 0, let data = chunk.floatChannelData {
                output.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(chunk.frameLength)))
            }
            if status == .endOfStream || (status == .inputRanDry && chunk.frameLength == 0) { break }
        }
        return output
    }

    /// Simple resampling: each new sample is read off the straight line between its neighbours.
    static func interpolate(_ samples: [Float], from inputRate: Double, to outputRate: Double) -> [Float] {
        let count = Int((Double(samples.count) * outputRate / inputRate).rounded())
        guard count > 0 else { return [] }
        let step = inputRate / outputRate
        return (0..<count).map { index in
            let position = Double(index) * step
            let lower = min(samples.count - 1, Int(position))
            let upper = min(samples.count - 1, lower + 1)
            let fraction = Float(position - Double(lower))
            return samples[lower] * (1 - fraction) + samples[upper] * fraction
        }
    }
}

extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
