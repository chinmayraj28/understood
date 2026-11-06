import AVFoundation
import Darwin
import Foundation
import HFCore
import HFWake

// hf-wake: try the wake phrase without the app.
//
//   swift run hf-wake status                      what this Mac supports and which permissions are granted
//   swift run hf-wake permissions --request       ask for the microphone (the system shows a prompt)
//   swift run hf-wake match [options]             type transcripts on standard input, see what wakes
//   swift run hf-wake listen [options]            listen on the microphone and print each wake
//   swift run hf-wake handover [options]          listen, hand the microphone to a voice-processing
//                                                 engine (as the conversation does), then listen again
//   swift run hf-wake replay [options]            the real recogniser on speech written to a file with
//                                                 `say -o`: no microphone, no permission, no sound
//
// Options for replay:
//   --say "TEXT" [--times N]   one sentence, expected to wake
//   --lines FILE               one sentence per line: "+ text" should wake, "- text" should not
//   --file PATH                an existing sound file, expected to wake
//   --voice NAME  --rate WORDS_PER_MINUTE   for `say`; try several voices and slow speech
//   --lead-silence S           seconds of silence before each sentence (default 1)
//   --bare-wait S  --mid-wait S  --longest-wait S   override WakeTiming
//
// Options for match, listen and handover:
//   --phrase "Hey Handsfree"   --alt "Okay Computer" (repeatable)   --strictness strict|balanced|lenient
//   --recognizer automatic|speechAnalyzer|onDeviceRecognizer   --locale en_GB (default: the Mac's)
// Options for listen:
//   --wakes N        stop after N wakes
//   --seconds S      stop after S seconds
//   --say "TEXT"     play TEXT through the speakers with `say`, to test without a person speaking;
//                    each play is timed from the end of the audio to the wake
//   --times N        how many times to play it (default 1)
//   --show-own-phrase  print what the recogniser wrote, but only while our own --say is playing
//   --request        ask for the microphone if it has never been asked
//
// Privacy: nothing heard is printed except the rest of the sentence after a wake (which the
// conversation would receive anyway) and, with --show-own-phrase, transcripts during our own test
// phrase. What people in the room say is never printed or stored.

setvbuf(stdout, nil, _IOLBF, 0)

struct Options {
    var command = "help"
    var phrase = Settings.load().wakePhrase
    var alternatives: [String] = []
    var strictness = WakeStrictness.balanced
    var wakes: Int?
    var seconds: Double?
    var say: String?
    var times = 1
    var showOwnPhrase = false
    var request = false
    var recognizer = WakeRecognizer.automatic
    var voice: String?
    var rate: Int?
    var lines: String?
    var file: String?
    var timing = WakeTiming()
    var leadSilence = 1.0
    var locale = Locale.current

    init(_ arguments: [String]) {
        var iterator = arguments.makeIterator()
        if let first = iterator.next() { command = first }
        while let argument = iterator.next() {
            switch argument {
            case "--phrase": phrase = iterator.next() ?? phrase
            case "--alt": if let value = iterator.next() { alternatives.append(value) }
            case "--strictness": strictness = WakeStrictness(rawValue: iterator.next() ?? "") ?? strictness
            case "--wakes": wakes = Int(iterator.next() ?? "")
            case "--seconds": seconds = Double(iterator.next() ?? "")
            case "--say": say = iterator.next()
            case "--times": times = Int(iterator.next() ?? "") ?? 1
            case "--show-own-phrase": showOwnPhrase = true
            case "--request": request = true
            case "--recognizer": recognizer = WakeRecognizer(rawValue: iterator.next() ?? "") ?? recognizer
            case "--voice": voice = iterator.next()
            case "--rate": rate = Int(iterator.next() ?? "")
            case "--lines": lines = iterator.next()
            case "--file": file = iterator.next()
            case "--lead-silence": leadSilence = Double(iterator.next() ?? "") ?? leadSilence
            case "--locale": locale = iterator.next().map { Locale(identifier: $0) } ?? locale
            case "--bare-wait": timing.quietAfterBarePhrase = Double(iterator.next() ?? "") ?? timing.quietAfterBarePhrase
            case "--mid-wait": timing.quietMidSentence = Double(iterator.next() ?? "") ?? timing.quietMidSentence
            case "--longest-wait": timing.longestWait = Double(iterator.next() ?? "") ?? timing.longestWait
            default: print("ignoring unknown option \(argument)")
            }
        }
    }

    var configuration: WakeListener.Configuration {
        WakeListener.Configuration(
            phrase: phrase, alternatives: alternatives, strictness: strictness, timing: timing,
            locale: locale, recognizer: recognizer, requestPermissions: request)
    }
}

let options = Options(Array(CommandLine.arguments.dropFirst()))

func uptime() -> Double { ProcessInfo.processInfo.systemUptime }
func format(_ seconds: Double) -> String { String(format: "%.2fs", seconds) }

/// CPU seconds used by this process so far (user + system).
func processCPUSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

/// Plays text through the speakers and returns when the audio has finished.
func speak(_ text: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    // A moderate volume: loud enough for the microphone, not for the room.
    process.arguments = ["[[volm 0.45]] " + text]
    try? process.run()
    process.waitUntilExit()
}

func printStatus() {
    print("microphone permission:          \(WakePermissions.microphone.rawValue)")
    print("speech recognition permission:  \(WakePermissions.speechRecognition.rawValue)"
        + (WakePermissions.needsSpeechRecognition ? " (needed on this Mac)" : " (not needed: SpeechAnalyzer is used)"))
    print("Mac language:                   \(Locale.current.identifier)")
    print("wake phrase:                    \(options.phrase)")
}

/// Wakes delivered by the listener, waited for with a time limit.
final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [String] = []
    private var waiter: (id: Int, continuation: CheckedContinuation<String?, Never>)?
    private var nextID = 0

    func push(_ rest: String) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.continuation.resume(returning: rest)
        } else {
            queued.append(rest)
            lock.unlock()
        }
    }

    func next(timeout seconds: Double) async -> String? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if !queued.isEmpty {
                let rest = queued.removeFirst()
                lock.unlock()
                continuation.resume(returning: rest)
                return
            }
            nextID += 1
            let id = nextID
            waiter = (id, continuation)
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
                lock.lock()
                guard let waiter, waiter.id == id else { lock.unlock(); return }
                self.waiter = nil
                lock.unlock()
                waiter.continuation.resume(returning: nil)
            }
        }
    }

    func clear() { lock.withLock { queued = [] } }
}

func describe(_ error: Error) -> String { (error as? SpeakableError)?.spokenMessage ?? "\(error)" }

func listen() async {
    let listener = WakeListener(configuration: options.configuration)
    let inbox = Inbox()
    let lastWake = LockedValue<(at: Double, afterLastWords: Double)?>(nil)
    listener.onDiagnostic = { diagnostic in
        switch diagnostic {
        case .started(let recognizer): print("listening with \(recognizer)")
        case .phraseHeard(let heardAs): print("  heard the phrase as \"\(heardAs)\"; waiting for the rest of the sentence")
        case .woke(_, _, let afterWords): lastWake.value = (uptime(), afterWords)
        case .restarting(let reason): print("  restarting: \(reason)")
        case .restartFailed(let error, let retry): print("  couldn't restart (\(error.spokenMessage)); retrying in \(format(retry))")
        case .transcript(let text, let isFinal): print("    recogniser\(isFinal ? " (final)" : ""): \(text)")
        }
    }

    func startListening() async -> Bool {
        do {
            try await listener.start { rest in inbox.push(rest) }
            return true
        } catch {
            print("can't listen: \(describe(error))")
            return false
        }
    }

    let startedAt = uptime()
    let cpuAtStart = processCPUSeconds()
    var wakeCount = 0
    var delays: [Double] = []
    var missed = 0
    guard await startListening() else { return }

    if let text = options.say {
        for _ in 0..<options.times {
            try? await Task.sleep(nanoseconds: 1_500_000_000)  // quiet before the phrase
            inbox.clear()
            listener.revealTranscripts = options.showOwnPhrase
            print("playing \"\(text)\"")
            speak(text)
            let endOfAudio = uptime()
            let rest = await inbox.next(timeout: 6)
            listener.revealTranscripts = false
            if let rest, let wake = lastWake.value {
                print("WAKE \(format(wake.at - endOfAudio)) after the audio ended"
                    + " (\(format(wake.afterLastWords)) after the last new words were transcribed); rest: \"\(rest)\"")
                delays.append(wake.at - endOfAudio)
                wakeCount += 1
            } else {
                print("MISSED: no wake within 6s of the audio ending")
                missed += 1
            }
            // What the cycle does: stop (the conversation takes the microphone), then listen again.
            await listener.stop()
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard await startListening() else { return }
        }
    } else {
        while true {
            let elapsed = uptime() - startedAt
            if let seconds = options.seconds, elapsed >= seconds { break }
            if let wakes = options.wakes, wakeCount >= wakes { break }
            let remaining = options.seconds.map { $0 - elapsed } ?? 3600 * 24
            guard let rest = await inbox.next(timeout: remaining) else { break }
            wakeCount += 1
            print("WAKE at +\(format(uptime() - startedAt)); rest: \"\(rest)\"")
            await listener.stop()
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard await startListening() else { return }
        }
    }
    await listener.stop()
    let wall = uptime() - startedAt
    let cpu = processCPUSeconds() - cpuAtStart
    print("---")
    print("wakes: \(wakeCount) in \(format(wall))")
    if options.say != nil {
        let sorted = delays.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        print("played \(options.times), woke \(delays.count), missed \(missed); delay after the audio ended: "
            + (sorted.isEmpty ? "n/a" : "min \(format(sorted.first!)), median \(format(median)), max \(format(sorted.last!))"))
    }
    print(String(format: "CPU of this process: %.1f%% of one core on average (%.2f CPU seconds)", cpu / wall * 100, cpu))
}

/// Start, stop, let a voice-processing engine take the microphone (as the ElevenLabs SDK does),
/// stop it, then start again and check the phrase is still heard.
func handover() async {
    let listener = WakeListener(configuration: options.configuration)
    let inbox = Inbox()
    do {
        try await listener.start { rest in inbox.push(rest) }
        print("1. listening: \(listener.isListening)")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let stopStarted = uptime()
        await listener.stop()
        print("2. stopped in \(format(uptime() - stopStarted)); listening: \(listener.isListening)")

        let engine = AVAudioEngine()
        try engine.inputNode.setVoiceProcessingEnabled(true)
        let buffers = LockedValue(0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: engine.inputNode.outputFormat(forBus: 0)) { _, _ in
            buffers.value += 1
        }
        engine.prepare()
        try engine.start()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try engine.inputNode.setVoiceProcessingEnabled(false)
        print("3. a voice-processing engine had the microphone for 2s and received \(buffers.value) buffers")

        try await listener.start { rest in inbox.push(rest) }
        print("4. listening again: \(listener.isListening)")
        if let text = options.say {
            try await Task.sleep(nanoseconds: 1_500_000_000)
            print("playing \"\(text)\"")
            speak(text)
            let end = uptime()
            let rest = await inbox.next(timeout: 6)
            print(rest.map { "5. WAKE \(format(uptime() - end)) after the audio ended; rest: \"\($0)\"" } ?? "5. MISSED")
        }
        await listener.stop()
    } catch {
        print("handover failed: \(describe(error))")
        await listener.stop()
    }
}

final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Lower case, letters and digits only, for comparing what was expected with what was heard.
func simplified(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }

/// Writes speech to a sound file with `say -o`. Nothing is played.
func synthesize(_ text: String, to url: URL) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    var arguments = ["-o", url.path]
    if let voice = options.voice { arguments += ["-v", voice] }
    if let rate = options.rate { arguments += ["-r", String(rate)] }
    process.arguments = arguments + [text]
    do { try process.run() } catch { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

func replay() async {
    var items: [(text: String, expectWake: Bool)] = []
    if let path = options.lines, let contents = try? String(contentsOfFile: path, encoding: .utf8) {
        for raw in contents.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("+ ") { items.append((String(line.dropFirst(2)), true)) }
            if line.hasPrefix("- ") { items.append((String(line.dropFirst(2)), false)) }
        }
    } else if let text = options.say {
        items = Array(repeating: (text, true), count: max(1, options.times))
    } else if let file = options.file {
        items = [(file, true)]
    }
    guard !items.isEmpty else {
        print("nothing to replay: give --say, --lines or --file")
        return
    }
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HF_WAKE_TMP"] ?? NSTemporaryDirectory())
        .appendingPathComponent("hf-wake-replay", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    print("voice: \(options.voice ?? "system default"), rate: \(options.rate.map(String.init) ?? "default") words per minute")

    let startedAt = uptime()
    let cpuAtStart = processCPUSeconds()
    var audioSeconds = 0.0
    var delays: [Double] = []
    var (rightWakes, missed, falseWakes, rightSilences) = (0, 0, 0, 0)
    var wrongRest: [String] = []

    for (index, item) in items.enumerated() {
        let url: URL
        if options.file != nil && options.lines == nil && options.say == nil {
            url = URL(fileURLWithPath: item.text)
        } else {
            url = directory.appendingPathComponent("line-\(index).aiff")
            guard synthesize(item.text, to: url) else { print("couldn't synthesize line \(index)"); continue }
        }
        let duration = (try? AVAudioFile(forReading: url)).map { Double($0.length) / $0.processingFormat.sampleRate } ?? 3
        audioSeconds += duration
        let audioEnded = LockedValue<Double?>(nil)
        let wokeAt = LockedValue<Double?>(nil)
        let transcripts = LockedValue<[String]>([])
        let listener = WakeListener(
            configuration: options.configuration, replaying: url, leadingSilence: options.leadSilence, trailingSilence: 4,
            onAudioEnded: { audioEnded.value = $0 })
        listener.revealTranscripts = true  // our own synthesized audio
        let verbose = ProcessInfo.processInfo.environment["HF_WAKE_VERBOSE"] == "1"
        listener.onDiagnostic = { diagnostic in
            if verbose { print("    [\(format(uptime() - startedAt))] \(diagnostic)") }
            switch diagnostic {
            case .woke: wokeAt.value = uptime()
            case .transcript(let text, let isFinal): if isFinal { transcripts.value.append(text) }
            case .restartFailed(let error, _): print("  restart failed: \(error.spokenMessage)")
            default: break
            }
        }
        let inbox = Inbox()
        do {
            try await listener.start { rest in inbox.push(rest) }
        } catch {
            print("can't listen: \(describe(error))")
            return
        }
        let rest = await inbox.next(timeout: options.leadSilence + duration + 4.5)
        await listener.stop()
        let heard = transcripts.value.joined(separator: " | ")
        let label = item.expectWake ? "should wake" : "should not"
        if let rest {
            let delay = (wokeAt.value ?? 0) - (audioEnded.value ?? wokeAt.value ?? 0)
            if item.expectWake {
                rightWakes += 1
                delays.append(delay)
            } else {
                falseWakes += 1
            }
            print("\(item.expectWake ? "ok  " : "FALSE") [\(label)] woke \(format(delay)) after the audio ended; rest \"\(rest)\"  <- heard: \(heard)")
            let expected = WakePhraseMatcher(phrase: options.phrase, alternatives: options.alternatives)
                .match(item.text)?.restOfSentence ?? ""
            if item.expectWake, simplified(expected) != simplified(rest) {
                wrongRest.append("\"\(item.text)\" gave \"\(rest)\"")
            }
        } else {
            if item.expectWake { missed += 1 } else { rightSilences += 1 }
            print("\(item.expectWake ? "MISS" : "ok  ") [\(label)] no wake  <- heard: \(heard.isEmpty ? "(nothing final)" : heard)")
        }
    }
    let wall = uptime() - startedAt
    let cpu = processCPUSeconds() - cpuAtStart
    let sorted = delays.sorted()
    print("---")
    print("should wake: \(rightWakes + missed), woke \(rightWakes), missed \(missed)")
    print("should not wake: \(falseWakes + rightSilences), false wakes \(falseWakes)")
    if !sorted.isEmpty {
        let mean = sorted.reduce(0, +) / Double(sorted.count)
        print("delay from end of audio to wake: min \(format(sorted.first!)), median \(format(sorted[sorted.count / 2])), mean \(format(mean)), max \(format(sorted.last!))")
    }
    if !wrongRest.isEmpty { print("rest of sentence differed: \(wrongRest.joined(separator: "; "))") }
    print(String(format: "%.0fs of speech in %.0fs; CPU of this process: %.1f%% of one core (%.2f CPU seconds)", audioSeconds, wall, cpu / wall * 100, cpu))
}

func match() {
    let matcher = WakePhraseMatcher(phrase: options.phrase, alternatives: options.alternatives, strictness: options.strictness)
    print("matching \(matcher.phrases.map { "\"\($0)\"" }.joined(separator: ", ")) at \(options.strictness.rawValue); type a transcript per line")
    while let line = readLine() {
        if let found = matcher.match(line) {
            print("WAKE  heard as \"\(found.heardAs)\"; rest: \"\(found.restOfSentence)\"")
        } else {
            print("no wake")
        }
    }
}

switch options.command {
case "status":
    printStatus()
case "permissions":
    printStatus()
    if options.request {
        print("asking for the microphone; a system prompt may appear for the app that owns this terminal")
        let granted = await WakePermissions.requestMicrophone()
        print("microphone: \(granted ? "granted" : "not granted")")
        if WakePermissions.needsSpeechRecognition {
            print("speech recognition: \(await WakePermissions.requestSpeechRecognition().rawValue)")
        }
    }
case "match":
    match()
case "listen":
    await listen()
case "handover":
    await handover()
case "replay":
    await replay()
default:
    print("usage: hf-wake status | permissions [--request] | match | listen | handover   (see the top of main.swift)")
}
