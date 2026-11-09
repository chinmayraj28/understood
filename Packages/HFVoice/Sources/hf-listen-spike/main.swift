// hf-listen-spike: can the app listen for itself while the ElevenLabs agent only speaks?
//
// A spike for docs/SPEECH_PLAN.md section 3 (7 Nov). Results are in docs/spikes/own_listening.md.
// It plays sound and uses the microphone: take the live lock first (scripts/live_lock.sh).
//
//   swift run hf-listen-spike muted [--mute-mode inputMixer|restart|voiceProcessing] [--vp on|off]
//                                   [--no-own-mic] [--say] [--premute]
//       A VOICE conversation with the TEST agent. Its microphone is muted straight after it
//       connects; a typed message is sent; the agent should answer aloud. Meanwhile our own
//       AVAudioEngine records the microphone (voice processing on or off), and afterwards the
//       recording is run through Apple's recogniser to see whether the agent's voice got in.
//       --say plays a sentence through the speakers with `say` while muted, as if the person
//       spoke: the agent must NOT hear it.
//   swift run hf-listen-spike textonly [--vp on|off]
//       The fallback: a text-only conversation, and the reply spoken with ElevenLabs
//       text-to-speech, played through our own engine (so echo cancellation has the reference).
//
// Never prints a key. Recordings go to the scratch folder given by HF_SPIKE_DIR (default /tmp).

import AVFoundation
import Combine
import ElevenLabs
import Foundation
import HFCore
import HFVoice
import LiveKit
import Speech

// MARK: - Timeline

let startedAt = ProcessInfo.processInfo.systemUptime
func now() -> Double { ProcessInfo.processInfo.systemUptime - startedAt }
func log(_ text: String) { print(String(format: "[%6.2f] ", now()) + text); fflush(stdout) }

/// Times the agent was heard speaking (from the SDK's agent state), for the level analysis.
final class Spans: @unchecked Sendable {
    private let lock = NSLock()
    private var open: Double?
    private(set) var closed: [(Double, Double)] = []
    func mark(speaking: Bool) {
        lock.withLock {
            if speaking, open == nil { open = now() }
            if !speaking, let start = open { closed.append((start, now())); open = nil }
        }
    }
    func finish() { mark(speaking: false) }
    func contains(_ time: Double) -> Bool { lock.withLock { closed.contains { $0.0 <= time && time <= $0.1 } } }
}

// MARK: - Our own microphone

/// Our own capture, separate from LiveKit's: AVAudioEngine, voice processing on or off.
/// Writes what it hears to a file and keeps the level of every buffer.
final class OwnRecorder: @unchecked Sendable {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    private var file: AVAudioFile?
    private let lock = NSLock()
    private(set) var levels: [(time: Double, db: Double)] = []
    let url: URL

    init(url: URL) { self.url = url }

    func start(voiceProcessing: Bool) throws {
        let input = engine.inputNode
        // Order matters (docs/spikes/elevenlabs.md section 7): the output side must exist before
        // voice processing is turned on, or the engine fails to start with -10875.
        let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        _ = engine.outputNode
        if voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            // Leave other audio (LiveKit's playback) at its normal volume.
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        }
        log("own engine: voice processing \(input.isVoiceProcessingEnabled ? "ON" : "off")")
        let format = input.outputFormat(forBus: 0)
        log("own engine input format: \(format.sampleRate) Hz, \(format.channelCount) ch")
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false)!
        file = try AVAudioFile(forWriting: url, settings: mono.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.take(buffer, mono: mono)
        }
        engine.prepare()
        try engine.start()
    }

    private func take(_ buffer: AVAudioPCMBuffer, mono: AVAudioFormat) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        let db = 20 * log10(Double(max(rms, 1e-7)))
        guard let copy = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength) else { return }
        copy.frameLength = buffer.frameLength
        memcpy(copy.floatChannelData![0], samples, Int(buffer.frameLength) * 4)
        lock.withLock {
            levels.append((now(), db))
            try? file?.write(from: copy)
        }
    }

    func play(pcm16 data: Data) {
        let frames = data.count / 2
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            let ints = raw.bindMemory(to: Int16.self)
            for index in 0..<frames { buffer.floatChannelData![0][index] = Float(ints[index]) / 32768 }
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
        player.play()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        lock.withLock { file = nil }
    }
}

// MARK: - The agent's voice as it arrives

/// Sits on the agent's incoming audio track and measures what arrives: proof that the agent's
/// voice reached this Mac to be played, without needing a microphone or a listener.
final class AgentAudioMeter: NSObject, AudioRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var seconds: Double = 0
    private(set) var loudSeconds: Double = 0
    private(set) var firstLoudAt: Double?
    private(set) var format = ""

    func render(pcmBuffer buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        var peak: Float = 0
        if let data = buffer.floatChannelData?[0] {
            for index in 0..<frames { peak = max(peak, abs(data[index])) }
        } else if let data = buffer.int16ChannelData?[0] {
            for index in 0..<frames { peak = max(peak, abs(Float(data[index]) / 32768)) }
        }
        let duration = Double(frames) / buffer.format.sampleRate
        lock.withLock {
            if format.isEmpty { format = "\(buffer.format.sampleRate) Hz, \(buffer.format.channelCount) ch, \(buffer.format.commonFormat.rawValue)" }
            seconds += duration
            if peak > 0.02 {
                loudSeconds += duration
                if firstLoudAt == nil { firstLoudAt = now() }
            }
        }
    }

    func summary() -> String {
        lock.withLock {
            String(format: "agent track delivered %.1f s of audio, %.1f s of it audible (format %@)", seconds, loudSeconds, format)
        }
    }
}

// MARK: - What Apple's recogniser hears in a file

func transcribe(_ url: URL) async -> String {
    guard #available(macOS 26.0, *) else { return "(needs macOS 26)" }
    // Found on 7 Nov: SpeechAnalyzer never returns on an empty file, so do not ask it.
    guard let probe = try? AVAudioFile(forReading: url), probe.length > 0 else { return "(nothing was recorded)" }
    do {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-GB")) else { return "(no locale)" }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        let file = try AVAudioFile(forReading: url)
        let collect = Task { () -> String in
            var parts: [String] = []
            for try await result in transcriber.results where result.isFinal { parts.append(String(result.text.characters)) }
            return parts.joined(separator: " ")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        return try await collect.value.trimmingCharacters(in: .whitespaces)
    } catch {
        return "(recognition failed: \(error))"
    }
}

func report(_ recorder: OwnRecorder, spans: Spans, quietBefore: Double) {
    let levels = recorder.levels
    let speaking = levels.filter { spans.contains($0.time) }.map(\.db)
    let quiet = levels.filter { !spans.contains($0.time) && $0.time < quietBefore }.map(\.db)
    func describe(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "no buffers" }
        let sorted = values.sorted()
        let mean = values.reduce(0, +) / Double(values.count)
        return String(format: "mean %.1f dBFS, median %.1f, 90th %.1f, max %.1f (%d buffers)",
                      mean, sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.9)], sorted.last!, values.count)
    }
    log("our recording while the agent spoke: \(describe(speaking))")
    log("our recording while quiet:           \(describe(quiet))")
    log("agent speaking spans: " + spans.closed.map { String(format: "%.2f–%.2f", $0.0, $0.1) }.joined(separator: ", "))
}

// MARK: - Arguments

let arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}
let mode = arguments.first ?? "muted"
let ownVoiceProcessing = (option("--vp") ?? "on") != "off"
let useOwnMic = !arguments.contains("--no-own-mic")
let spikeFolder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HF_SPIKE_DIR"] ?? NSTemporaryDirectory())
let message = option("--message")
    ?? "Please reply with exactly this sentence and nothing else: The purple elephant danced quietly under seven orange umbrellas."

let settings = Settings.load()
guard !settings.elevenLabsAPIKey.isEmpty, let agentID = TestAgent.storedID() else {
    print("Needs ELEVENLABS_API_KEY and \(TestAgent.envKey) in .env.")
    exit(1)
}
let api = ElevenLabsAPI(apiKey: settings.elevenLabsAPIKey)
let variables = ["user_memory": "Nothing yet.", "session_context": "Spike test. Front app: Terminal."]

// MARK: - Muted voice conversation

@MainActor
func runMuted() async -> Int32 {
    let muteMode: MicrophoneMuteMode
    switch option("--mute-mode") ?? "inputMixer" {
    case "restart": muteMode = .restart
    case "voiceProcessing": muteMode = .voiceProcessing
    default: muteMode = .inputMixer
    }
    log("mode: muted voice conversation, LiveKit mute mode \(muteMode), own mic \(useOwnMic ? (ownVoiceProcessing ? "VP on" : "VP off") : "none")")

    let spans = Spans()
    let recorder = OwnRecorder(url: spikeFolder.appendingPathComponent("spike-muted-\(Int(Date().timeIntervalSince1970)).caf"))
    if useOwnMic {
        do { try recorder.start(voiceProcessing: ownVoiceProcessing) } catch {
            log("own engine failed to start: \(error)")
            return 1
        }
    }
    if let wanted = option("--input-device") {
        // In this process only (no system setting changes): LiveKit's microphone becomes another
        // input device. Used on 7 Nov with the lid shut, when the built-in microphone was off.
        let devices = AudioManager.shared.inputDevices
        log("input devices: " + devices.map(\.name).joined(separator: ", "))
        if let device = devices.first(where: { $0.name.localizedCaseInsensitiveContains(wanted) }) {
            AudioManager.shared.inputDevice = device
            log("LiveKit input device: \(AudioManager.shared.inputDevice.name)")
        } else {
            log("no input device matching \(wanted)")
        }
    }
    if arguments.contains("--premute") {
        // Silence what LiveKit sends before its track is even published.
        AudioManager.shared.mixer.micVolume = 0
        log("premute: LiveKit mic mixer volume 0")
    }

    var userTranscripts: [String] = []
    var sentAt: Double?
    var firstReplyTextAt: Double?
    var firstSpeakingAfterSend: Double?
    let config = ConversationConfig(
        dynamicVariables: variables,
        audioConfiguration: AudioPipelineConfiguration(microphoneMuteMode: muteMode),
        onError: { error in log("SDK error: \(error)") },
        onAgentResponse: { text, _ in
            Task { @MainActor in
                if sentAt != nil, firstReplyTextAt == nil { firstReplyTextAt = now() }
                log("AGENT said: \(text)")
            }
        },
        onUserTranscript: { text, _ in
            Task { @MainActor in
                userTranscripts.append(text)
                log("USER transcript (the agent heard the microphone!): \(text)")
            }
        },
        onVadScore: { _ in }
    )
    let token: String
    do { token = try await api.conversationToken(agentID: agentID) } catch {
        log("token failed: \(error)")
        recorder.stop()
        return 1
    }
    let conversation: Conversation
    do {
        conversation = try await ElevenLabs.startConversation(conversationToken: token, config: config)
    } catch {
        log("connect failed: \(error)")
        recorder.stop()
        return 1
    }
    log("connected; SDK says muted=\(conversation.isMuted)")
    var observers: Set<AnyCancellable> = []
    conversation.$agentState.removeDuplicates().sink { state in
        log("agent state: \(state)")
        spans.mark(speaking: state == .speaking)
        if state == .speaking, sentAt != nil, firstSpeakingAfterSend == nil { firstSpeakingAfterSend = now() }
    }.store(in: &observers)

    let meter = AgentAudioMeter()
    var meterAttached = false
    func attachMeter() {
        guard !meterAttached, let track = conversation.agentAudioTrack else { return }
        track.add(audioRenderer: meter)
        meterAttached = true
        log("meter attached to the agent's audio track")
    }
    attachMeter()

    let muteStart = now()
    do { try await conversation.setMicrophoneMuted(true) } catch { log("mute failed: \(error)") }
    log(String(format: "muted in %.0f ms; SDK muted=\(conversation.isMuted); LiveKit engine running=\(AudioManager.shared.isEngineRunning)", (now() - muteStart) * 1000))
    log("echo: " + VoiceDiagnostics.echoCancellationReport().replacingOccurrences(of: "\n", with: "; "))
    if arguments.contains("--premute") { AudioManager.shared.mixer.micVolume = 1 }

    try? await Task.sleep(nanoseconds: 1_500_000_000)
    if arguments.contains("--say") {
        log("playing a spoken sentence through the speakers while muted (as if the person spoke)")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["What is the capital of France? Tell me the capital of France."]
        try? say.run()
        say.waitUntilExit()
        log("say finished; waiting 5 s for any user transcript")
        try? await Task.sleep(nanoseconds: 5_000_000_000)
    }
    let quietBefore = now()

    sentAt = now()
    log("sending typed user message")
    do { try await conversation.sendMessage(message) } catch { log("send failed: \(error)") }
    // Wait for the reply to be spoken and finish.
    let deadline = now() + 20
    while now() < deadline {
        try? await Task.sleep(nanoseconds: 200_000_000)
        attachMeter()
        if let speaking = firstSpeakingAfterSend, conversation.agentState == .listening, now() - speaking > 1.5 { break }
    }
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    spans.finish()
    await conversation.endConversation()
    observers.removeAll()
    if useOwnMic { recorder.stop() }
    log("ended; LiveKit engine running=\(AudioManager.shared.isEngineRunning)")

    if let sentAt {
        if let text = firstReplyTextAt { log(String(format: "send → reply text: %.2f s", text - sentAt)) }
        if let audio = firstSpeakingAfterSend { log(String(format: "send → agent audio starts: %.2f s", audio - sentAt)) }
        else { log("the agent never started speaking after the typed message") }
    }
    log(meter.summary())
    if let loud = meter.firstLoudAt, let sentAt { log(String(format: "send → first audible agent audio on this Mac: %.2f s", loud - sentAt)) }
    log("user transcripts while muted: \(userTranscripts.isEmpty ? "none" : userTranscripts.joined(separator: " | "))")
    if useOwnMic {
        report(recorder, spans: spans, quietBefore: quietBefore)
        log("our recording: \(recorder.url.path)")
        log("Apple hears in our recording: \"\(await transcribe(recorder.url))\"")
    }
    return 0
}

// MARK: - Text-only conversation plus text-to-speech

@MainActor
func runTextOnly() async -> Int32 {
    log("mode: text-only conversation + ElevenLabs text-to-speech through our own engine (VP \(ownVoiceProcessing ? "on" : "off"))")
    let spans = Spans()
    let recorder = OwnRecorder(url: spikeFolder.appendingPathComponent("spike-textonly-\(Int(Date().timeIntervalSince1970)).caf"))
    do { try recorder.start(voiceProcessing: ownVoiceProcessing) } catch {
        log("own engine failed: \(error)")
        return 1
    }
    var replies: [String] = []
    let config = ConversationConfig(
        conversationOverrides: ConversationOverrides(textOnly: true),
        dynamicVariables: variables,
        onError: { error in log("SDK error: \(error)") },
        onAgentResponse: { text, _ in Task { @MainActor in replies.append(text); log("AGENT said: \(text)") } }
    )
    let conversation: Conversation
    do {
        let url = try await api.signedURL(agentID: agentID)
        conversation = try await ElevenLabs.startConversation(signedWebSocketURL: url, config: config)
    } catch {
        log("connect failed: \(error)")
        recorder.stop()
        return 1
    }
    log("connected (text only)")
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    let quietBefore = now()
    let sentAt = now()
    try? await conversation.sendMessage(message)
    while replies.isEmpty, now() - sentAt < 15 { try? await Task.sleep(nanoseconds: 50_000_000) }
    guard let reply = replies.first else {
        log("no reply")
        await conversation.endConversation()
        recorder.stop()
        return 1
    }
    let textAt = now()
    log(String(format: "send → reply text: %.2f s", textAt - sentAt))
    // Text-to-speech, the same voice the agent uses. pcm_16000 is raw 16-bit mono samples.
    let voice = AgentConfiguration().voiceID
    var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voice)?output_format=pcm_16000")!)
    request.httpMethod = "POST"
    request.setValue(settings.elevenLabsAPIKey, forHTTPHeaderField: "xi-api-key")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": reply, "model_id": "eleven_flash_v2_5"])
    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        log(String(format: "TTS: HTTP %d, %d bytes (%.1f s of audio) in %.2f s", status, data.count, Double(data.count) / 32000, now() - textAt))
        guard status == 200 else { throw SpeakableError("TTS \(status)") }
        spans.mark(speaking: true)
        recorder.play(pcm16: data)
        log(String(format: "send → audio starts: %.2f s", now() - sentAt))
        try? await Task.sleep(nanoseconds: UInt64((Double(data.count) / 32000 + 0.5) * 1_000_000_000))
        spans.mark(speaking: false)
    } catch {
        log("TTS failed: \(error)")
    }
    await conversation.endConversation()
    recorder.stop()
    report(recorder, spans: spans, quietBefore: quietBefore)
    log("our recording: \(recorder.url.path)")
    log("Apple hears in our recording: \"\(await transcribe(recorder.url))\"")
    return 0
}

let code: Int32 = mode == "textonly" ? await runTextOnly() : await runMuted()
exit(code)
