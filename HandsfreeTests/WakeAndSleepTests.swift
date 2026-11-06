//
//  WakeAndSleepTests.swift
//  HandsfreeTests
//
//  Asleep and waking on the companion, the waking and sleeping sounds, and how the
//  listening cycle is wired to the voice session and the task runner (with fakes).
//

import Foundation
import HFCore
import Testing

@Suite("Companion asleep and waking")
struct CompanionWakeTests {
    let start = Date(timeIntervalSince1970: 1_000_000)
    func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    @Test("Asleep shows its own still look and the phrase to say, and stays")
    func asleep() {
        var state = CompanionState()
        state.apply(.asleep(wakePhrase: "Hey Handsfree"), now: start)
        #expect(state.glyph == .asleep)
        #expect(state.isAsleep && !state.isResting, "asleep must not look like the listening dot")
        #expect(state.sleepHint == "Say \u{201C}Hey Handsfree\u{201D}")
        state.expire(now: at(3600))
        #expect(state.glyph == .asleep, "nothing times it out: it stays asleep until woken")
        #expect(state.sleepHint != nil)
    }

    @Test("The hint uses the configured phrase")
    func configuredPhrase() {
        var state = CompanionState()
        state.apply(.asleep(wakePhrase: "  Computer  "), now: start)
        #expect(state.sleepHint == "Say \u{201C}Computer\u{201D}")
        state.apply(.asleep(wakePhrase: ""), now: start)
        #expect(state.sleepHint == "Say \u{201C}Computer\u{201D}", "an empty phrase keeps the last one")
    }

    @Test("Going to sleep clears what the conversation left on screen")
    func sleepClears() {
        var state = CompanionState()
        state.apply(.listening, now: start)
        state.apply(.agentSpeaking("Volume's at thirty."), now: start)
        #expect(state.caption != nil)
        state.apply(.asleep(wakePhrase: "Hey Handsfree"), now: at(1))
        #expect(state.caption == nil && state.prompt == nil && state.target == nil)
        #expect(state.glyph == .asleep)
    }

    @Test("Waking shows at once, then Listening when the conversation is ready")
    func waking() {
        var state = CompanionState()
        state.apply(.asleep(wakePhrase: "Hey Handsfree"), now: start)
        state.apply(.waking, now: at(1))
        #expect(state.glyph == .waking)
        #expect(state.sleepHint == nil, "the hint goes the moment it hears the phrase")
        #expect(state.caption?.text == "Heard you")
        #expect(state.caption?.tone == .awake)
        state.apply(.listening, now: at(1.4))
        #expect(state.glyph == .listening)
        #expect(state.caption?.text == "Listening")
        state.apply(.userSaid("open Spotify"), now: at(1.5))
        #expect(state.caption?.text == "\u{201C}open Spotify\u{201D}", "the first utterance shows as heard")
        state.expire(now: at(1.5 + CompanionTiming.heardCaptionSeconds + 0.01))
        #expect(state.isResting)
    }

    @Test("A later listening (the agent finished talking) does not say Listening again")
    func listeningOnlyAfterWaking() {
        var state = CompanionState()
        state.apply(.waking, now: start)
        state.apply(.listening, now: at(0.5))
        state.expire(now: at(0.5 + CompanionTiming.awakeCaptionSeconds + 0.01))
        state.apply(.listening, now: at(5))
        #expect(state.caption == nil)
    }

    @Test("A wake that cannot connect says so, and still says Listening when it does")
    func wakeThatRetries() {
        var state = CompanionState()
        state.apply(.waking, now: start)
        state.apply(.voiceDisconnected(reason: "I can't reach the voice service."), now: at(0.5))
        #expect(state.glyph == .disconnected)
        state.apply(.listening, now: at(2))
        #expect(state.caption?.text == "Listening")
    }

    @Test("Falling back asleep after a failed wake keeps the reason on screen until it times out")
    func failedWakeKeepsReason() {
        var state = CompanionState()
        state.apply(.waking, now: start)
        // The real order: the session's own first failure, then the cycle's reason, then asleep.
        state.apply(.voiceDisconnected(reason: "I can't reach the voice service."), now: at(0.5))
        state.apply(.voiceDisconnected(reason: "I heard you, but I couldn't reach the voice service."), now: at(4))
        state.apply(.asleep(wakePhrase: "Hey Handsfree"), now: at(4.1))
        #expect(state.glyph == .asleep)
        #expect(state.caption?.tone == .muted)
        #expect(state.caption?.text == "I heard you, but I couldn't reach the voice service.", "the real reason, not \"trying again\"")
        #expect(state.sleepHint == nil)
        state.expire(now: at(4 + CompanionTiming.disconnectedCaptionSeconds + 0.01))
        #expect(state.sleepHint == "Say \u{201C}Hey Handsfree\u{201D}")
    }

    @Test("Waking outranks a finished task still on screen")
    func wakingOutranksResult() {
        var state = CompanionState()
        state.apply(.taskEnded(status: .done, summary: "Sent."), now: start)
        state.apply(.waking, now: at(0.1))
        #expect(state.glyph == .waking)
    }
}

@Suite("Waking and sleeping sounds")
struct SoundCueTests {
    @Test("Rising when it can hear, falling when it sleeps, nothing at launch")
    func rules() {
        var rules = SoundCueRules()
        #expect(rules.cue(for: .asleep(wakePhrase: "Hey Handsfree")) == nil, "no sound at launch")
        #expect(rules.cue(for: .waking) == nil, "the sound waits until it can really hear")
        #expect(rules.cue(for: .listening) == .listening)
        #expect(rules.cue(for: .userSaid("open Spotify")) == nil)
        #expect(rules.cue(for: .listening) == nil, "the agent finishing a reply is not a wake")
        #expect(rules.cue(for: .voiceDisconnected(reason: "dropped")) == nil, "a drop while awake is shown, not chimed")
        #expect(rules.cue(for: .listening) == nil, "reconnecting is not a wake")
        #expect(rules.cue(for: .asleep(wakePhrase: "Hey Handsfree")) == .asleep)
        #expect(rules.cue(for: .asleep(wakePhrase: "Hey Handsfree")) == nil, "only once")
    }

    @Test("A wake that connects on the retry plays only the rising sound")
    func retryThenConnects() {
        var rules = SoundCueRules()
        _ = rules.cue(for: .asleep(wakePhrase: "Hey Handsfree"))
        _ = rules.cue(for: .waking)
        #expect(rules.cue(for: .voiceDisconnected(reason: "no network")) == nil, "a first failed attempt is retried at once")
        #expect(rules.cue(for: .listening) == .listening, "and it can hear now: no 'failed' sound before it")
    }

    @Test("A wake that gives up goes back to sleep with the low sound only")
    func problemThenAsleep() {
        var rules = SoundCueRules()
        _ = rules.cue(for: .asleep(wakePhrase: "Hey Handsfree"))
        _ = rules.cue(for: .waking)
        #expect(rules.cue(for: .voiceDisconnected(reason: "no network")) == nil)
        #expect(rules.cue(for: .voiceDisconnected(reason: "I heard you, but...")) == nil)
        #expect(rules.cue(for: .asleep(wakePhrase: "Hey Handsfree")) == .problem, "the low sound, not the falling one")
        _ = rules.cue(for: .waking)
        #expect(rules.cue(for: .listening) == .listening, "the next wake works as normal")
    }

    @Test("Each sound is a short, valid WAV that starts and ends quietly", arguments: SoundCue.allCases)
    func tones(cue: SoundCue) {
        let data = CueTone.wavData(for: cue)
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
        let samples = CueTone.samples(for: cue)
        #expect(data.count == 44 + samples.count * 2)
        let seconds = Double(samples.count) / Double(CueTone.sampleRate)
        #expect(seconds > 0.15 && seconds < 0.45, "short enough not to make anyone wait: \(seconds) s")
        #expect(samples.allSatisfy { abs($0) <= 1 })
        #expect(abs(samples.first ?? 1) < 0.01 && abs(samples.last ?? 1) < 0.01, "no click at either end")
        #expect((samples.map(abs).max() ?? 0) > 0.1, "loud enough to hear")
    }

    @Test("Waking rises and sleeping falls, and sleeping is quieter")
    func shapes() {
        let wake = CueTone.notes(for: .listening), sleep = CueTone.notes(for: .asleep)
        #expect(wake.first!.frequency < wake.last!.frequency)
        #expect(sleep.first!.frequency > sleep.last!.frequency)
        #expect(sleep.map(\.loudness).max()! < wake.map(\.loudness).max()!)
    }
}

// MARK: - Cycle wiring with fakes

@MainActor
final class FakeVoice: VoiceConnecting {
    var opened: [(firstUtterance: String, memorySummary: String?)] = []
    var closes = 0
    var prepared: [String] = []
    var activity = VoiceActivity.closed
    /// Whether opening connects, at once or after the session's own retry.
    var connects = true
    var connectsOnRetry = false
    var onNewsWhileClosed: (@MainActor () -> Void)?

    func prepareConversations(tools: [ToolSpec], memorySummary: String, onUserSentence: @escaping @Sendable (String) -> Void) {
        prepared.append(memorySummary)
    }
    func openConversation(firstUtterance: String, memorySummary: String?) async {
        opened.append((firstUtterance, memorySummary))
        activity.isOpen = true
    }
    func closeConversation() async {
        closes += 1
        activity = .closed
    }
    var isConversationConnected: Bool { activity.isOpen && connects }
    var agentStatus: AgentStatus?
    var openRefusal: String?
    func waitUntilConnected(timeout: TimeInterval) async -> Bool { activity.isOpen && (connects || connectsOnRetry) }
    nonisolated func push(_ event: TaskEvent) {}
    var conversationActivity: VoiceActivity { activity }
    func stop() async { await closeConversation() }
}

final class FakeRunner: TaskRunnerPart, @unchecked Sendable {
    var isRunning = false
    var isAwaitingAnswer = false
    var tools: [ToolSpec] { [] }
    func cancel() {}
    var currentTaskID: String? { nil }
    func shutdown() {}
}

final class FakeMemory: MemoryProviding, @unchecked Sendable {
    func hints(forGoal goal: String) async -> String { "" }
    func summaryForPrompt(maxCharacters: Int) async -> String { "- Mum is Amma on WhatsApp" }
    func learn(fromQuestion question: String, options: [String], answer: String, goal: String) async {}
    func taskEnded(goal: String, status: TaskStatus, summary: String, steps: [String], seconds: Double) async {}
}

@Suite("Listening cycle wiring") @MainActor
struct CycleWiringTests {
    @Test("Anything going on keeps it awake: a task, either side speaking, or news not yet said")
    func isBusy() {
        let quiet = VoiceActivity(isOpen: true, isUserSpeaking: false, isAgentSpeaking: false, hasUnspokenNews: false, lastActivityAt: 0)
        func busy(_ running: Bool, _ awaiting: Bool, _ conversation: VoiceActivity) -> Bool {
            CycleWiring.snapshot(taskRunning: running, awaitingAnswer: awaiting, conversation: conversation).isBusy
        }
        #expect(!busy(false, false, quiet))
        #expect(busy(true, false, quiet), "a task keeps it awake, so stop can always be heard")
        #expect(CycleWiring.snapshot(taskRunning: false, awaitingAnswer: true, conversation: quiet).awaitingAnswer)
        var speaking = quiet; speaking.isUserSpeaking = true
        #expect(CycleWiring.snapshot(taskRunning: false, awaitingAnswer: false, conversation: speaking).someoneSpeaking)
        var agent = quiet; agent.isAgentSpeaking = true
        #expect(busy(false, false, agent))
        var news = quiet; news.hasUnspokenNews = true
        #expect(CycleWiring.snapshot(taskRunning: false, awaitingAnswer: false, conversation: news).someoneSpeaking,
                "a waiting result counts as speech still to come, so a goodbye waits for it")
    }

    @Test("The hooks open with the first utterance and fresh memory, and read the runner and the voice")
    func hooks() async throws {
        let voice = FakeVoice(), runner = FakeRunner()
        let hooks = CycleWiring.hooks(voice: voice, runner: runner, memory: FakeMemory())
        try await hooks.open("open Spotify")
        #expect(voice.opened.count == 1)
        #expect(voice.opened.first?.firstUtterance == "open Spotify")
        #expect(voice.opened.first?.memorySummary == "- Mum is Amma on WhatsApp")
        #expect(!hooks.snapshot().isBusy)
        runner.isRunning = true
        #expect(hooks.snapshot().taskRunning)
        runner.isRunning = false
        voice.activity.isAgentSpeaking = true
        #expect(hooks.snapshot().someoneSpeaking)
        voice.activity.lastActivityAt = 42
        #expect(hooks.lastActivityAt() == 42)
        await hooks.close()
        #expect(voice.closes == 1)
        #expect(!hooks.snapshot().isBusy, "closed means nothing is going on in the conversation")
    }

    @Test("A wake that connects on the session's own retry is kept")
    func connectsOnRetry() async throws {
        let voice = FakeVoice()
        voice.connects = false
        voice.connectsOnRetry = true
        try await CycleWiring.hooks(voice: voice, runner: FakeRunner(), memory: FakeMemory()).open("")
        #expect(voice.closes == 0)
    }

    @Test("A wake that cannot connect closes the session and says why, so nothing reconnects while asleep")
    func cannotConnect() async {
        let voice = FakeVoice()
        voice.connects = false
        let hooks = CycleWiring.hooks(voice: voice, runner: FakeRunner(), memory: FakeMemory())
        do {
            try await hooks.open("open Spotify")
            Issue.record("expected the open to fail")
        } catch let error as SpeakableError {
            #expect(error == CycleWiring.couldNotConnect)
            #expect(error.spokenMessage.contains("Say the wake phrase to try again"))
        } catch {
            Issue.record("expected a SpeakableError, got \(error)")
        }
        #expect(voice.closes == 1)
        #expect(!voice.activity.isOpen)
    }

    @Test("Wake mode always keeps one conversation open, retrying, and never sleeps")
    func alwaysOpen() async {
        let voice = FakeVoice()
        voice.connects = false  // the session keeps retrying by itself; the cycle must not close it
        let cycle = AlwaysOpenCycle(hooks: CycleWiring.hooks(voice: voice, runner: FakeRunner(), memory: FakeMemory()))
        await cycle.start()
        await cycle.start()
        #expect(voice.opened.count == 1)
        #expect(voice.opened.first?.firstUtterance == "")
        #expect(await cycle.requestSleep() == .notAvailable, "nothing to sleep in wake mode always")
        cycle.wakeWithoutPhrase()
        #expect(voice.closes == 0)
        await cycle.stop()
        #expect(voice.closes == 1)
    }

    @Test("The mirror gives any thread the latest snapshot")
    func mirror() async {
        let mirror = ActivityMirror()
        var current = CycleSnapshot.idle
        mirror.startRefreshing(every: 0.01) { current }
        #expect(mirror.current == .idle)
        current.taskRunning = true
        try? await Task.sleep(nanoseconds: 80_000_000)
        let fromAnotherThread = await Task.detached { mirror.current }.value
        #expect(fromAnotherThread.taskRunning)
        mirror.stopRefreshing()
    }

    @Test("The sleep tool gets the cycle's real answer, and a task blocks it")
    func sleepRelay() async {
        let relay = SleepRequestRelay()
        #expect(await relay.request() == .notAvailable, "before the cycle exists it cannot sleep, and nothing crashes")
        let cycle = FakeCycle()
        relay.setHandler { await cycle.requestSleep() }
        #expect(await relay.request() == .goingToSleep)
        cycle.answer = .busy
        #expect(await relay.request() == .busy, "the agent is told it stays awake, so it never says Okay wrongly")
        #expect(cycle.sleeps == 2)
        let runner = FakeRunner()
        #expect(!CycleWiring.isTaskActive(runner))
        runner.isAwaitingAnswer = true
        #expect(CycleWiring.isTaskActive(runner))
    }
}

@Suite("Listening status for diagnosis")
struct ListeningStatusTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    @Test("Speech that is not the phrase is counted, never stored")
    func counts() {
        var status = ListeningStatus()
        status.listenerRunning = true
        status.record(.started(recognizer: "SpeechAnalyzer"), at: start)
        #expect(status.heardLine(now: start).contains("no other speech heard yet"), "all zero: it cannot hear, or nobody spoke")
        status.record(.speechWithoutPhrase, at: start)
        status.record(.speechWithoutPhrase, at: start.addingTimeInterval(5))
        status.record(.phraseHeard, at: start.addingTimeInterval(6))
        status.record(.woke, at: start.addingTimeInterval(6))
        let line = status.heardLine(now: start.addingTimeInterval(10))
        #expect(line.contains("heard speech 2 times that was not \u{201C}Hey Handsfree\u{201D}, last 5 s ago"))
        #expect(line.contains("woke once, last 4 s ago"))
        #expect(line.contains("never kept"))
        #expect(status.listenerLine.contains("listening on this Mac") && status.listenerLine.contains("SpeechAnalyzer"))
        let file = status.statusDictionary(now: start.addingTimeInterval(10))
        let listener = file["wake_listener"] as? [String: Any]
        #expect(listener?["speech_without_phrase_count"] as? Int == 2)
        #expect(listener?["wake_count"] as? Int == 1)
        #expect(listener?["running"] as? Bool == true)
    }

    @Test("Each state says plainly what is happening")
    func lines() {
        var status = ListeningStatus()
        status.waitingFor = "the Speech Recognition permission"
        #expect(status.listenerLine == "Wake listener: not started. Waiting for the Speech Recognition permission.")
        status.waitingFor = nil
        status.record(.cannotListen(reason: "Speech Recognition is off for Handsfree."), at: start)
        #expect(status.listenerLine.contains("not running. Speech Recognition is off"))
        status.record(.started(recognizer: "SFSpeechRecognizer"), at: start)
        #expect(status.listenerProblem == nil, "a restart that works clears the problem")
        status.conversationOpen = true
        #expect(status.listenerLine.contains("paused while the conversation has the microphone"))
        #expect(status.conversationLine.contains("opening"))
        status.conversationConnected = true
        #expect(status.conversationLine.hasPrefix("Conversation: open, and the voice service can hear. Goes back to sleep after 25 seconds of quiet"))
        #expect(status.conversationLine.contains("never while a task is running"))
        status.conversationOpen = false; status.conversationConnected = false
        #expect(status.conversationLine.contains("Nothing said reaches the voice service"))
        status.alwaysOpen = true
        #expect(status.listenerLine.contains("WAKE_MODE=always"))
    }

    @Test("While asleep, speech that is not the phrase briefly changes the hint")
    func companionHint() {
        var state = CompanionState()
        state.heardSpeechWithoutPhrase(now: start)
        #expect(!state.sleepHintHeardOtherSpeech, "only while asleep")
        state.apply(.asleep(wakePhrase: "Hey Handsfree"), now: start)
        state.heardSpeechWithoutPhrase(now: start)
        #expect(state.sleepHintHeardOtherSpeech)
        #expect(state.sleepHint != nil)
        state.expire(now: start.addingTimeInterval(CompanionTiming.heardOtherSpeechSeconds + 0.01))
        #expect(!state.sleepHintHeardOtherSpeech)
    }
}

@Suite("Listening status while the listener starts")
struct ListeningStartTests {
    @Test("Asleep but not yet listening says it is starting, and why that can take a while")
    func starting() {
        var status = ListeningStatus()
        status.cycleState = "asleep"
        #expect(status.listenerLine.contains("starting") && status.listenerLine.contains("speech model"))
        status.listenerRunning = true
        status.record(.started(recognizer: "SpeechAnalyzer (en_IN)"), at: Date())
        #expect(status.listenerLine == "Wake listener: listening on this Mac for \u{201C}Hey Handsfree\u{201D}, using SpeechAnalyzer (en_IN).")
    }
}

@MainActor
final class FakeCycle: ListeningCycling {
    var wakes = 0
    var sleeps = 0
    func start() async {}
    func stop() async {}
    var answer = SleepAnswer.goingToSleep
    func requestSleep() async -> SleepAnswer { sleeps += 1; return answer }
    func wakeWithoutPhrase() { wakes += 1 }
    func currentState() async -> String { "asleep" }
    var isListenerRunning: Bool { true }
}

@Suite("Task news while asleep") @MainActor
struct NewsWakesTests {
    @Test("News the user must hear, arriving while asleep, wakes the cycle")
    func newsWakes() {
        let voice = FakeVoice()
        var cycle: FakeCycle? = FakeCycle()
        CycleWiring.wakeForNews(voice: voice, cycle: cycle!)
        voice.onNewsWhileClosed?()
        #expect(cycle?.wakes == 1)
        cycle = nil
        voice.onNewsWhileClosed?()  // the cycle is gone (quitting): nothing happens, nothing crashes
    }
}

@Suite("Wake language shown for diagnosis")
struct WakeLanguageTests {
    @Test("The language in use is named, with where it came from")
    func language() {
        #expect(AppWakeLanguage.locale(for: "en-GB").identifier == "en_GB")
        #expect(AppWakeLanguage.describe(setting: "en_GB").contains("en_GB (set by WAKE_LANGUAGE)"))
        #expect(AppWakeLanguage.describe(setting: "").contains("the Mac's own language; set WAKE_LANGUAGE to change it"))
        var status = ListeningStatus()
        status.language = AppWakeLanguage.describe(setting: "en_GB")
        status.alternatives = ["Okay computer"]
        status.strictness = "lenient"
        #expect(status.languageLine.hasPrefix("Listening in English (United Kingdom), en_GB"))
        #expect(status.languageLine.contains("Also wakes on \u{201C}Okay computer\u{201D}."))
        #expect(status.languageLine.contains("Matching: lenient."))
        #expect(status.statusDictionary(now: Date())["wake_language"] as? String == status.language)
        status.alwaysOpen = true
        #expect(status.languageLine.isEmpty)
    }
}

@Suite("One copy only")
struct SingleInstanceTests {
    let base = Date(timeIntervalSince1970: 1_000_000)
    func copy(_ pid: Int32, _ seconds: Double?) -> RunningCopy {
        RunningCopy(processID: pid, launchDate: seconds.map { base.addingTimeInterval($0) })
    }

    @Test("Alone, it runs; macOS lists the app itself too")
    func alone() {
        let me = copy(500, 10)
        #expect(SingleInstance.decide(me: me, others: []) == .run)
        #expect(SingleInstance.decide(me: me, others: [me]) == .run)
    }

    @Test("A copy started later hands over to the one already running, whatever its path or build")
    func later() {
        let running = copy(300, 0)  // e.g. /Applications/Handsfree.app
        let second = copy(700, 9)  // e.g. a `open -n` of build/Handsfree.app with --demo
        #expect(SingleInstance.decide(me: second, others: [running, second]) == .handOver(to: 300))
        #expect(SingleInstance.decide(me: running, others: [running, second]) == .run, "the first copy keeps running")
    }

    @Test("Three copies: only the first stays")
    func three() {
        let copies = [copy(300, 0), copy(400, 1), copy(450, 2)]
        let decisions = copies.map { SingleInstance.decide(me: $0, others: copies) }
        #expect(decisions == [.run, .handOver(to: 300), .handOver(to: 300)])
    }

    @Test("Two started in the same instant, or with no launch date: exactly one stays")
    func tie() {
        let a = copy(800, 5), b = copy(801, 5)
        #expect(SingleInstance.decide(me: a, others: [a, b]) == .run)
        #expect(SingleInstance.decide(me: b, others: [a, b]) == .handOver(to: 800))
        let c = copy(900, nil), d = copy(901, nil)
        #expect(SingleInstance.decide(me: c, others: [c, d]) == .run)
        #expect(SingleInstance.decide(me: d, others: [c, d]) == .handOver(to: 900))
    }

    @Test("Only drawing images to files is exempt; the demo is not")
    func exemptions() {
        #expect(SingleInstance.applies(to: LaunchOptions.parse([])))
        #expect(SingleInstance.applies(to: LaunchOptions.parse(["--demo", "--show-panel"])))
        #expect(SingleInstance.applies(to: LaunchOptions.parse(["--quit-after", "6"])))
        #expect(!SingleInstance.applies(to: LaunchOptions.parse(["--render-states", "/tmp/x"])))
    }
}

@Suite("Voice agent in step, for diagnosis")
struct AgentStatusLineTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("The panel says whether the agent has the app's tools, and when it was checked")
    func lines() {
        var status = ListeningStatus()
        #expect(status.agentLine(now: now) == "Voice agent: not checked yet.")
        status.agent = AgentStatus(inSync: true, toolCount: 24, expectedToolCount: 24, checkedAt: now.addingTimeInterval(-12),
                                   problem: nil, missing: [], unexpected: [])
        #expect(status.agentLine(now: now) == "Voice agent: in step with the app (24 tools), checked 12 s ago.")
        status.agent = AgentStatus(inSync: false, toolCount: 1, expectedToolCount: 24, checkedAt: now,
                                   problem: "ElevenLabs did not accept the agent's tools, so I can't start a conversation yet.",
                                   missing: ["start_task"], unexpected: ["demo_set_volume"])
        let line = status.agentLine(now: now)
        #expect(line.hasPrefix("Voice agent: NOT in step with the app, so no conversation opens."))
        #expect(line.contains("Not the app's: demo_set_volume."))
        let file = status.statusDictionary(now: now)["agent"] as? [String: Any]
        #expect(file?["in_sync"] as? Bool == false)
        #expect(file?["tool_count"] as? Int == 1)
        #expect(file?["expected_tool_count"] as? Int == 24)
    }

    @Test("A wake refused because the agent is out of step throws that sentence at once")
    @MainActor func refusal() async {
        let voice = FakeVoice()
        voice.openRefusal = "ElevenLabs did not accept the agent's tools, so I can't start a conversation yet."
        let hooks = CycleWiring.hooks(voice: voice, runner: FakeRunner(), memory: FakeMemory())
        do {
            try await hooks.open("open YouTube")
            Issue.record("expected a refusal")
        } catch let error as SpeakableError {
            #expect(error.spokenMessage == voice.openRefusal)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}

@Suite("Signing off in the user's own words")
struct SleepPhraseTests {
    @Test("These end the conversation", arguments: [
        "stop listening", "Stop listening.", "Please stop listening", "You can stop listening now", "stop listening, thanks",
        "go to sleep", "Go back to sleep.", "Okay, go to sleep", "That's all, thanks", "that's it", "Thanks, that's all for now",
        "That will be all", "Thank you, goodbye", "Bye!", "Goodnight", "OK thanks, we're done", "No, that's all",
        "Hey Handsfree, go to sleep",
    ])
    func signsOff(sentence: String) {
        #expect(SleepPhrases.isSignOff(sentence), "\(sentence)")
    }

    @Test("These do what they do today", arguments: [
        "stop", "Stop.", "Stop the music", "stop scrolling", "wait", "cancel that", "be quiet",
        "Send Amma a message saying that's all for today", "Is that all you can do?", "Open YouTube",
        "Tell me what's on my calendar, then that's all", "good", "thanks", "okay", "",
        "I said stop listening to the music",
    ])
    func doesNotSignOff(sentence: String) {
        #expect(!SleepPhrases.isSignOff(sentence), "\(sentence)")
    }
}
