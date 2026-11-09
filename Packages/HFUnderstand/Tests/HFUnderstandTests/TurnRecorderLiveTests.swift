import AVFoundation
import Foundation
import HFCore
import Testing

@testable import HFUnderstand

// The turn recorder on the real microphone and speakers (docs/spikes/own_listening.md).
// Only with HF_LIVE=1. They play sound: take the live lock first.
//   scripts/live_lock.sh acquire mic
//   HF_LIVE=1 swift test --filter TurnRecorderLive
//   scripts/live_lock.sh release mic
// The "person" is the Mac's `say` voice played with `afplay`, outside our engine. The "agent" is
// ElevenLabs text-to-speech (pcm_16000) played through TurnRecorder.playAgentAudio, or `say`
// when no key is set. Results are printed; the expectations are only the plumbing.

private let live = ProcessInfo.processInfo.environment["HF_LIVE"] == "1"
private let scratch = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HF_SPIKE_DIR"] ?? NSTemporaryDirectory())
private let agentSentence = "I've opened your calendar. Tomorrow you have a dentist appointment at ten, and lunch with Sam at one. Would you like me to add anything?"

private func report(_ line: String) { print("LIVE: \(line)"); fflush(stdout) }

private func run(_ tool: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
}

/// `say` to a 16 kHz 16-bit WAV file. `[[slnc 1500]]` in the text is a 1.5 s pause.
private func sayFile(_ text: String, voice: String, name: String) throws -> URL {
    let url = scratch.appendingPathComponent("live-\(name).wav")
    try run("/usr/bin/say", ["-v", voice, "-o", url.path, "--file-format=WAVE", "--data-format=LEI16@16000", text])
    return url
}

/// The samples of a WAV file, without its header.
private func pcm(ofWav url: URL) throws -> Data {
    let data = try Data(contentsOf: url)
    guard let range = data.range(of: Data("data".utf8)) else { return Data() }
    return data.subdata(in: (range.upperBound + 4)..<data.count)
}

/// The agent's voice: ElevenLabs text-to-speech in the agent's voice, or `say` without a key.
private func agentSpeech() async throws -> (pcm: Data, source: String) {
    let key = Settings.load().elevenLabsAPIKey
    if !key.isEmpty {
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/Xb7hH8MSUJpSbSDYk0k2?output_format=pcm_16000")!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": agentSentence, "model_id": "eleven_flash_v2_5"])
        let (data, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 200, data.count > 32_000 { return (data, "ElevenLabs TTS") }
    }
    return (try pcm(ofWav: try sayFile(agentSentence, voice: "Daniel", name: "agent")), "say -v Daniel")
}

private func sleep(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

/// Collects a recorder's events in the background.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [(Double, TurnRecorderEvent)] = []
    private var task: Task<Void, Never>?
    let started = ProcessInfo.processInfo.systemUptime
    init(_ recorder: TurnRecorder) {
        task = Task { [weak self] in
            for await event in recorder.events {
                guard let self else { return }
                self.lock.withLock { self.list.append((ProcessInfo.processInfo.systemUptime - self.started, event)) }
            }
        }
    }
    var events: [(Double, TurnRecorderEvent)] { lock.withLock { list } }
    func cancel() { task?.cancel() }
    var turns: [(RecordedTurn, TurnEndReason)] {
        events.compactMap { if case .turnFinished(let turn, let reason) = $0.1 { return (turn, reason) } else { return nil } }
    }
    var stops: [(Double, String, String)] {
        events.compactMap { if case .stopHeard(let word, let text) = $0.1 { return ($0.0, word, text) } else { return nil } }
    }
    var speechStarts: [Double] { events.compactMap { if case .speechStarted = $0.1 { return $0.0 } else { return nil } } }
    var problems: [String] { events.compactMap { if case .problem(let text) = $0.1 { return text } else { return nil } } }
    func summary() -> String {
        let turnText = turns.map { String(format: "[%@ %.1fs \"%@\"]", $0.1.rawValue, $0.0.durationSeconds, $0.0.liveTranscript) }
        return "speechStarted=\(speechStarts.map { String(format: "%.1f", $0) }) turns=\(turnText) stops=\(stops.map { "\($0.1)@\(String(format: "%.1f", $0.0)): \($0.2)" }) problems=\(problems)"
    }
}

/// Level of the first channel of each microphone buffer, from an engine built the way
/// TurnRecorder builds it (player first, then voice processing), optionally playing `pcm16`.
private func probeLevels(voiceProcessing: Bool, seconds: Double, play pcm16: Data? = nil, playAfter: Double = 1.5)
    async throws -> (buffers: Int, peak: Float, before: Double, during: Double, after: Double, playedFor: Double)
{
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let format16 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: format16)
    _ = engine.outputNode
    if voiceProcessing {
        try engine.inputNode.setVoiceProcessingEnabled(true)
        engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
    }
    let lock = NSLock()
    var levels: [(Double, Double)] = []
    var peak: Float = 0
    let start = ProcessInfo.processInfo.systemUptime
    let format = engine.inputNode.outputFormat(forBus: 0)
    engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var sum: Float = 0, loudest: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += channel[index] * channel[index]; loudest = max(loudest, abs(channel[index])) }
        let db = 10 * log10(Double(max(sum / Float(buffer.frameLength), 1e-12)))
        lock.withLock { levels.append((ProcessInfo.processInfo.systemUptime - start, db)); peak = max(peak, loudest) }
    }
    engine.prepare()
    try engine.start()
    var playedFor = 0.0
    if let pcm16 {
        await sleep(playAfter)
        let frames = pcm16.count / 2
        let buffer = AVAudioPCMBuffer(pcmFormat: format16, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm16.withUnsafeBytes { raw in
            for index in 0..<frames { buffer.floatChannelData![0][index] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32768 }
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
        player.play()
        playedFor = Double(frames) / 16_000
        await sleep(max(seconds - playAfter, playedFor + 1))
    } else {
        await sleep(seconds)
    }
    player.stop()
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    let all = lock.withLock { levels }
    func median(_ values: [Double]) -> Double { values.isEmpty ? .nan : values.sorted()[values.count / 2] }
    let playStart = playAfter, playEnd = playAfter + playedFor
    return (all.count, lock.withLock { peak },
            median(all.filter { $0.0 > 0.3 && $0.0 < playStart }.map(\.1)),
            median(all.filter { $0.0 > playStart + 0.2 && $0.0 < playEnd }.map(\.1)),
            median(all.filter { $0.0 > playEnd + 0.3 }.map(\.1)), playedFor)
}

@Suite("TurnRecorderLive", .serialized, .enabled(if: live))
struct TurnRecorderLiveTests {
    @Test("1. The microphone delivers sound, with voice processing on and off")
    func microphoneDelivers() async throws {
        for vp in [true, false] {
            let result = try await probeLevels(voiceProcessing: vp, seconds: 2)
            report(String(format: "mic VP %@: %d buffers in 2 s, peak %.4f, median %.1f dBFS", vp ? "on" : "off", result.buffers, result.peak, result.before))
            #expect(result.buffers > 5)
            #expect(result.peak > 0)
        }
    }

    @Test("2. A spoken pause of 1.5 s stays one turn; a final \"done\" ends the turn early")
    func turnsFromRealSound() async throws {
        for vp in [true, false] {
            let recorder = TurnRecorder(settings: TurnRecorderSettings(voiceProcessing: vp))
            let collector = Collector(recorder)
            try await recorder.start()
            report("turns VP \(vp ? "on" : "off"): echo cancelling=\(recorder.isEchoCancelling) recogniser=\(recorder.liveRecognizerName ?? "none")")
            await sleep(1.5)
            let paused = try sayFile("Open my calendar [[slnc 1500]] and show me tomorrow", voice: "Samantha", name: "pause")
            let t0 = collector.started
            try run("/usr/bin/afplay", [paused.path])
            let afterPause = ProcessInfo.processInfo.systemUptime - t0
            await sleep(3.5)
            report("  pause phrase (played until \(String(format: "%.1f", afterPause)) s): \(collector.summary())")
            let turnsBefore = collector.turns.count
            let done = try sayFile("Write a note that says hello Sam done", voice: "Samantha", name: "done")
            try run("/usr/bin/afplay", [done.path])
            let doneEndedAt = ProcessInfo.processInfo.systemUptime - t0
            await sleep(3.0)
            let doneTurns = Array(collector.turns.dropFirst(turnsBefore))
            let doneTurnAt = collector.events.last { if case .turnFinished = $0.1 { return true } else { return false } }?.0 ?? .nan
            report(String(format: "  done phrase (played until %.1f s, turn at %.1f s): %@", doneEndedAt, doneTurnAt, collector.summary()))
            await recorder.stop()
            collector.cancel()
            if vp {
                #expect(turnsBefore == 1)
                #expect(doneTurns.first?.1 == .saidDone)
            }
            await sleep(0.5)
        }
    }

    @Test("3. The agent's voice played through playAgentAudio is kept out; a person over it is heard")
    func echo() async throws {
        let (agent, source) = try await agentSpeech()
        report(String(format: "agent speech: %@, %.1f s", source, Double(agent.count) / 32_000))
        for vp in [true, false] {
            let levels = try await probeLevels(voiceProcessing: vp, seconds: 0, play: agent)
            report(String(format: "echo level VP %@: before %.1f dBFS, while agent plays %.1f dBFS, after %.1f dBFS (agent %.1f s)",
                          vp ? "on" : "off", levels.before, levels.during, levels.after, levels.playedFor))
            await sleep(0.5)
        }
        let person = try sayFile("Stop, please read me my emails instead", voice: "Samantha", name: "person")
        for vp in [true, false] {
            // The agent alone.
            let recorder = TurnRecorder(settings: TurnRecorderSettings(voiceProcessing: vp))
            let collector = Collector(recorder)
            try await recorder.start()
            await sleep(1.5)
            recorder.playAgentAudio(pcm16: agent)
            await sleep(Double(agent.count) / 32_000 + 3)
            report("agent alone, recorder VP \(vp ? "on" : "off") (echo cancelling=\(recorder.isEchoCancelling)): \(collector.summary())")
            let agentAloneTurns = collector.turns.count
            // The agent again, and the person speaks over it two seconds in.
            let mark = collector.events.count
            recorder.playAgentAudio(pcm16: agent)
            let playedAt = ProcessInfo.processInfo.systemUptime - collector.started
            await sleep(2)
            try run("/usr/bin/afplay", [person.path])
            await sleep(3)
            recorder.stopAgentAudio()
            await sleep(0.5)
            let overlap = Array(collector.events.dropFirst(mark))
            let stop = overlap.first { if case .stopHeard = $0.1 { return true } else { return false } }
            report(String(format: "barge-in VP %@: agent from %.1f s, person from %.1f s; stop heard at %@; %@", vp ? "on" : "off",
                          playedAt, playedAt + 2, stop.map { String(format: "%.1f s", $0.0) } ?? "never", collector.summary()))
            await recorder.stop()
            collector.cancel()
            if vp { #expect(agentAloneTurns == 0) }
            await sleep(0.5)
        }
    }
}
