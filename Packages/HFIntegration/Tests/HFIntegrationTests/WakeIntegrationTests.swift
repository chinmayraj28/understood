import CoreGraphics
import Foundation
import HFCore
import HFDecisions
import HFTasks
@testable import HFVoice  // the SDK seam (ConversationDriving, the full initialiser) is internal
import HFWake
import Testing

// The real listening cycle (HFWake) wired to the real voice session (over a fake ElevenLabs
// connection), the real task runner and task tools, the real stop watcher and the real safety
// gate with Jev off, the way the app wires them in Handsfree/Integration/RealParts.swift
// (WakeCycleAdapter) and CycleWiring.swift:
//
//   openConversation   = voice.open(firstUtterance:), then wait for the connection; if it never
//                        connects, close it and throw (CycleWiring.hooks.open)
//   closeConversation  = voice.close()
//   currentActivity    = a mirror the main actor refreshes from voice.activity and the runner
//                        (ActivityMirror + CycleWiring.snapshot)
//   news while closed  = voice.onNewsWhileClosed → cycle.wakeNow() (CycleWiring.wakeForNews)
//   go_to_sleep tool   = SleepTool, refusing while a task is active, onSleep → cycle.requestSleep()
//
// Only the wake listener (the microphone) and the ElevenLabs connection are faked. The cycle
// runs on a manual clock, so "25 seconds of quiet" takes no real time; everything else runs in
// real time with short timings.

// MARK: - Fakes for the outside world

/// The wake phrase, as far as the cycle is concerned: the test says when it was heard.
final class TestWakeListener: WakeListening, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (String) -> Void)?
    private var listening = false
    private(set) var starts = 0
    private(set) var stops = 0

    func start(onWake: @escaping @Sendable (String) -> Void) async throws {
        lock.withLock {
            starts += 1
            handler = onWake
            listening = true
        }
    }

    func stop() async {
        lock.withLock {
            stops += 1
            handler = nil
            listening = false
        }
    }

    var isListening: Bool { lock.withLock { listening } }
    var startCount: Int { lock.withLock { starts } }

    /// "Hey Handsfree", then `rest`.
    func hear(_ rest: String) {
        let handler = lock.withLock { self.handler }
        handler?(rest)
    }
}

/// The ElevenLabs connection: counts conversations, can refuse to connect, and plays the agent.
@MainActor
final class WakeConversation: ConversationDriving {
    var starts = 0
    var ends = 0
    /// How many coming `start`s fail, as when the voice service cannot be reached.
    var failingStarts = 0
    var userMessages: [String] = []
    var toolResults: [(callID: String, text: String, isError: Bool)] = []
    private var onSignal: (@MainActor @Sendable (ConversationSignal) -> Void)?

    func start(_ start: ConversationStart, onSignal: @escaping @MainActor @Sendable (ConversationSignal) -> Void) async throws {
        starts += 1
        if failingStarts > 0 {
            failingStarts -= 1
            throw SpeakableError("no network")
        }
        self.onSignal = onSignal
    }

    /// Like the real agent, reply to every message (the session waits for a reply before pushing more).
    func sendUserMessage(_ text: String) async throws {
        userMessages.append(text)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000)
            self?.emit(.agentResponse("(says it)"))
        }
    }
    func sendContext(_ text: String) async throws {}
    func sendToolResult(callID: String, text: String, isError: Bool) async throws { toolResults.append((callID, text, isError)) }
    func end() async { ends += 1 }

    func emit(_ signal: ConversationSignal) { onSignal?(signal) }

    func callTool(_ name: String, _ parameters: JSONObject = [:], id: String) {
        let data = (try? JSONEncoder().encode(JSONValue.object(parameters))) ?? Data("{}".utf8)
        emit(.toolCall(name: name, callID: id, parameters: data))
    }

    /// The user says something; the agent passes it on with a tool, then replies.
    func userSays(_ text: String, thenAgentCalls tool: String? = nil, _ parameters: JSONObject = [:], id: String = UUID().uuidString) {
        emit(.userTranscript(text))
        if let tool { callTool(tool, parameters, id: id) }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000)
            self?.emit(.agentResponse("(answers the user)"))
        }
    }

    func result(_ id: String) -> String? { toolResults.first { $0.callID == id }?.text }
    func pushes(containing text: String) -> Int { userMessages.filter { $0.contains(text) }.count }
}

/// The listening cycle's clock: moves only when the test moves it.
final class CycleClock: @unchecked Sendable {
    private struct Waiter {
        let id: Int
        let deadline: Double
        let continuation: CheckedContinuation<Void, Error>
    }
    private let lock = NSLock()
    private var time: Double = 10_000
    private var waiters: [Waiter] = []
    private var nextID = 0
    private var cancelledEarly: Set<Int> = []

    var now: Double { lock.withLock { time } }

    func sleep(_ seconds: Double) async throws {
        try Task.checkCancellation()
        let id = lock.withLock { () -> Int in
            nextID += 1
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let cancelled = lock.withLock { () -> Bool in
                    if cancelledEarly.remove(id) != nil { return true }
                    waiters.append(Waiter(id: id, deadline: time + seconds, continuation: continuation))
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiter = lock.withLock { () -> Waiter? in
                if let index = waiters.firstIndex(where: { $0.id == id }) { return waiters.remove(at: index) }
                cancelledEarly.insert(id)
                return nil
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves the cycle's time forward in half-second steps, letting the woken loops run.
    func advance(by seconds: Double) async {
        let target = now + seconds
        while now < target - 1e-9 {
            let due = lock.withLock { () -> [Waiter] in
                time = min(time + 0.5, target)
                let due = waiters.filter { $0.deadline <= time + 1e-9 }
                waiters.removeAll { $0.deadline <= time + 1e-9 }
                return due
            }
            for waiter in due { waiter.continuation.resume() }
            if !due.isEmpty {
                for _ in 0..<4 {
                    await Task.yield()
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
            }
        }
    }
}

/// What is going on, readable from the cycle's thread. The app's ActivityMirror refreshes every
/// 0.2 s on the main actor; this one every 5 ms, from the same rule as CycleWiring.snapshot.
final class TestActivityMirror: @unchecked Sendable {
    private let lock = NSLock()
    private var latest = HFWake.ConversationActivity.idle
    var current: HFWake.ConversationActivity { lock.withLock { latest } }
    func store(_ activity: HFWake.ConversationActivity) { lock.withLock { latest = activity } }
}

/// A task whose length the test controls.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    func release() { lock.withLock { open = true } }
    var isOpen: Bool { lock.withLock { open } }
}

// MARK: - The rig

@MainActor
final class WakeRig {
    let activity = ActivityLog()
    let conversation = WakeConversation()
    let listener = TestWakeListener()
    let clock = CycleClock()
    let mirror = TestActivityMirror()
    let session: VoiceSession
    let rig: Rig
    let watcher: StopWatcher
    private(set) var cycle: ListeningCycle!
    private var refreshing: Task<Void, Never>?
    let problems = Log<String>()
    nonisolated static let idleSeconds = 25.0
    nonisolated static let couldNotConnect = "I heard you, but I couldn't reach the voice service. Say the wake phrase to try again."

    init(mode: WakeMode = .phrase, executor: @escaping (FakeHands) -> any TaskExecuting) async {
        var tuning = VoiceSession.Tuning()
        tuning.pumpInterval = 0.01
        tuning.settleAfterReply = 0.05
        tuning.userQuietAfter = 0.1
        tuning.reconnectDelays = [0.05]
        let conversation = conversation
        session = VoiceSession(
            agentID: "agent_test", mode: .voice, bus: activity.bus, tuning: tuning,
            makeDriver: { conversation },
            clock: { ProcessInfo.processInfo.systemUptime },
            sleep: { seconds in try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1e9)) },
            syncAgent: nil)
        let session = session
        rig = Rig(activity: activity, gate: SafetyGate(classifier: Classifiers(client: nil)),
                  alsoSendEventsTo: { session.push($0) }, executor: executor)
        let runner = rig.runner
        watcher = StopWatcher(
            classifier: Classifiers(client: nil),
            isTaskRunning: { runner.isRunning },
            isAwaitingAnswer: { runner.isAwaitingAnswer },
            currentTaskID: { runner.status()["task_id"]?.stringValue },
            cancel: { _ = runner.cancel(taskID: nil) })

        // The cycle, with the app's hooks.
        let clock = clock, mirror = mirror, problems = problems
        let cycle = ListeningCycle(
            mode: mode, wakePhrase: "Hey Handsfree", sleepAfterIdleSeconds: Self.idleSeconds,
            listener: listener,
            openConversation: { firstUtterance in
                await session.open(firstUtterance: firstUtterance)
                if await session.isConnected { return }
                // The app gives the session's own retry 4 s; here the retry comes after 0.05 s.
                if await session.waitUntilConnected(timeout: 0.3) { return }
                await session.close()
                throw SpeakableError(WakeRig.couldNotConnect)
            },
            closeConversation: { await session.close() },
            currentActivity: { mirror.current },
            now: { clock.now },
            sleep: { seconds in try await clock.sleep(seconds) },
            bus: activity.bus,
            onProblem: { problems.append($0.spokenMessage) })
        self.cycle = cycle

        // The go_to_sleep tool, refusing while a task is active (PartAssembly + SleepTool).
        let sleepTool = SleepTool.make(
            isTaskActive: { runner.isRunning || runner.isAwaitingAnswer },
            onSleep: { Task { _ = await cycle.requestSleep() } })
        let watcher = watcher
        session.prepare(tools: Array(rig.tools.values) + [sleepTool], memorySummary: "") { sentence in
            watcher.heard(sentence)
        }
        // News pushed while no conversation is open wakes the cycle (CycleWiring.wakeForNews).
        session.onNewsWhileClosed = { Task { await cycle.wakeNow() } }

        // The mirror of "is anything going on" (ActivityMirror), from the same rule as CycleWiring.snapshot.
        refreshing = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let now = self.session.activity
                self.mirror.store(HFWake.ConversationActivity(
                    someoneSpeaking: now.isUserSpeaking || now.isAgentSpeaking || now.hasUnspokenNews,
                    taskRunning: runner.isRunning,
                    awaitingAnswer: runner.isAwaitingAnswer))
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
    }

    func start() async { await cycle.start() }

    func finish() async {
        refreshing?.cancel()
        await cycle.stop()
        await session.close()
    }

    func state() async -> ListeningCycle.State { await cycle.state }

    func waitFor(_ state: ListeningCycle.State, timeout: Double = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await cycle.state == state { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return await cycle.state == state
    }

    /// Lets the agent's replies and the pushes settle in real time.
    func settle(_ seconds: Double = 0.15) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    }

    /// Asleep, then "Hey Handsfree, <rest>", then awake with the conversation connected.
    func wake(saying rest: String) async -> Bool {
        listener.hear(rest)
        guard await waitFor(.awake) else { return false }
        return await waitUntil { self.session.isConnected }
    }

    /// The cycle's own events, in order, with repeats collapsed.
    var cycleEvents: [String] {
        var names: [String] = []
        for event in activity.events {
            let name: String?
            switch event {
            case .asleep: name = "asleep"
            case .waking: name = "waking"
            case .listening: name = "listening"
            case .voiceDisconnected: name = "voiceDisconnected"
            default: name = nil
            }
            if let name, names.last != name { names.append(name) }
        }
        return names
    }

    func disconnections(_ reason: String) -> Int {
        activity.events.filter { $0 == .voiceDisconnected(reason: reason) }.count
    }
}

/// A task that runs until the test releases it.
func heldTask(_ gate: Gate, result: String = "Finished the long job.") -> ScriptedFlow.Script {
    { context in
        context.report("Working on it")
        while !gate.isOpen {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return result
    }
}

// MARK: - The tests

@Suite(.serialized) @MainActor struct WakeIntegrationTests {

    @Test("Asleep, the phrase opens one conversation with the rest of the sentence, and it sleeps again after the idle time")
    func wholeLoop() async throws {
        let wake = await WakeRig { _ in ScriptedFlow({ _ in "Nothing." }) }
        defer { Task { await wake.finish() } }
        await wake.start()
        #expect(await wake.state() == .asleep)
        #expect(wake.listener.isListening)
        #expect(wake.conversation.starts == 0 && !wake.session.isOpen, "no conversation while asleep")

        #expect(await wake.wake(saying: "open Spotify"))
        #expect(wake.conversation.starts == 1)
        #expect(await waitUntil { wake.conversation.userMessages.first == "open Spotify" },
                "first turn: \(wake.conversation.userMessages)")
        #expect(!wake.listener.isListening, "the conversation has the microphone")
        await wake.settle()

        // Nothing going on: still open just before the idle time, closed just after.
        await wake.clock.advance(by: WakeRig.idleSeconds - 3)
        #expect(await wake.state() == .awake)
        await wake.clock.advance(by: 6)
        #expect(await wake.waitFor(.asleep))
        #expect(await waitUntil { !wake.session.isOpen && wake.conversation.ends >= 1 })
        #expect(wake.listener.startCount == 2 && wake.listener.isListening, "listening again")
        #expect(wake.conversation.starts == 1, "exactly one conversation")
        #expect(await waitUntil { wake.cycleEvents == ["asleep", "waking", "listening", "asleep"] },
                "bus: \(wake.cycleEvents)")
    }

    @Test("A running task keeps the conversation open far past the idle time")
    func taskKeepsItAwake() async throws {
        let gate = Gate()
        let wake = await WakeRig { _ in ScriptedFlow(heldTask(gate)) }
        defer { Task { await wake.finish() } }
        await wake.start()
        #expect(await wake.wake(saying: "tidy my desktop"))
        wake.conversation.callTool("start_task", ["goal": "Tidy my desktop"], id: "t1")
        #expect(await waitUntil { wake.rig.runner.isRunning })
        await wake.settle()
        // Only the task keeps it awake: nobody is speaking and nothing is waiting to be said.
        #expect(await waitUntil { wake.mirror.current == ConversationActivity(taskRunning: true) },
                "activity: \(wake.mirror.current)")

        await wake.clock.advance(by: WakeRig.idleSeconds * 5)
        #expect(await wake.state() == .awake)
        #expect(wake.session.isOpen && wake.conversation.ends == 0)

        // Once the task ends and its result has been said, the idle time runs as usual.
        gate.release()
        #expect(await waitUntil(timeout: 3) { wake.conversation.pushes(containing: "Finished the long job.") == 1 })
        await wake.settle()
        await wake.clock.advance(by: WakeRig.idleSeconds + 2)
        #expect(await wake.waitFor(.asleep))
    }

    @Test("A risky click waiting for the user's yes is never put to sleep, and the yes then lands it")
    func neverSleepsOverAConfirmation() async throws {
        let wake = await WakeRig { hands in InviteFlowExecutor(hands: hands) }
        defer { Task { await wake.finish() } }
        await wake.start()
        #expect(await wake.wake(saying: ""))
        wake.conversation.callTool("start_task", ["goal": .string(TaskFlowTests.goal)], id: "c1")
        _ = try #require(await wake.rig.recorder.waitFor(.question, timeout: 3))
        wake.conversation.userSays("Shah", thenAgentCalls: "answer_task", ["answer": "Priya Shah"], id: "c2")
        let confirmation = try #require(await wake.rig.recorder.waitFor(.confirmation, timeout: 3))
        #expect(confirmation.text.contains("Send the invite to Priya Shah"))
        #expect(await waitUntil(timeout: 3) { wake.conversation.pushes(containing: "Send the invite to Priya Shah") == 1 })
        await wake.settle()

        // What keeps it awake is the waiting confirmation, not talk: nobody is speaking and nothing
        // is waiting to be said. (The runner also counts as running while it waits for an answer.)
        #expect(await waitUntil { wake.mirror.current == ConversationActivity(taskRunning: true, awaitingAnswer: true) },
                "activity: \(wake.mirror.current) session: \(wake.session.activity)")
        // The user takes their time: the idle time passes eight times over.
        await wake.clock.advance(by: WakeRig.idleSeconds * 8)
        #expect(await wake.state() == .awake)
        #expect(wake.session.isOpen && wake.conversation.ends == 0)
        #expect(wake.rig.runner.isAwaitingAnswer, "the confirmation is still pending")
        #expect(!wake.rig.hands.actions.items.contains("click 900,120"), "nothing was clicked without a yes")

        wake.conversation.userSays("yes", thenAgentCalls: "answer_task", ["answer": "yes"], id: "c3")
        let result = try #require(await wake.rig.recorder.waitFor(.result, timeout: 3))
        #expect(result.status == .done)
        #expect(wake.rig.hands.actions.items.contains("click 900,120"), "the yes landed the click")
    }

    @Test("\"That's all\" is refused while a task runs or waits, and accepted when nothing is going on")
    func thatsAll() async throws {
        let gate = Gate()
        let wake = await WakeRig { hands in
            ScriptedFlow(heldTask(gate), then: { context in
                _ = try await context.askUser("Which folder?", options: [])
                return "Done."
            })
        }
        defer { Task { await wake.finish() } }
        await wake.start()
        #expect(await wake.wake(saying: ""))

        // While a task runs.
        wake.conversation.callTool("start_task", ["goal": "Tidy my desktop"], id: "t1")
        #expect(await waitUntil { wake.rig.runner.isRunning })
        wake.conversation.userSays("that's all, thanks", thenAgentCalls: SleepTool.name, id: "s1")
        #expect(await waitUntil { wake.conversation.result("s1") != nil })
        #expect(wake.conversation.result("s1")?.contains("A task is still going") == true, "\(wake.conversation.result("s1") ?? "")")
        await wake.clock.advance(by: 20)
        #expect(await wake.state() == .awake)
        gate.release()
        #expect(await waitUntil(timeout: 3) { !wake.rig.runner.isRunning })

        // While a task waits for an answer.
        wake.conversation.callTool("start_task", ["goal": "Sort my files"], id: "t2")
        #expect(await waitUntil(timeout: 3) { wake.rig.runner.isAwaitingAnswer })
        wake.conversation.userSays("that's all", thenAgentCalls: SleepTool.name, id: "s2")
        #expect(await waitUntil { wake.conversation.result("s2") != nil })
        #expect(wake.conversation.result("s2")?.contains("A task is still going") == true)
        await wake.clock.advance(by: 20)
        #expect(await wake.state() == .awake && wake.conversation.ends == 0)
        _ = wake.rig.runner.cancel(taskID: nil)
        #expect(await waitUntil(timeout: 3) { !wake.rig.runner.isRunning && !wake.rig.runner.isAwaitingAnswer })
        await wake.settle(0.3)

        // Nothing going on: it sleeps without waiting for the idle time.
        wake.conversation.userSays("that's all, thanks", thenAgentCalls: SleepTool.name, id: "s3")
        #expect(await waitUntil { wake.conversation.result("s3") != nil })
        #expect(wake.conversation.result("s3")?.contains("\"ok\":true") == true, "\(wake.conversation.result("s3") ?? "")")
        await wake.settle()
        await wake.clock.advance(by: 3)
        #expect(await wake.waitFor(.asleep))
        #expect(await waitUntil { !wake.session.isOpen })
        #expect(wake.listener.isListening)
    }

    @Test("A task's news pushed while asleep wakes the cycle, and is said exactly once after connecting")
    func newsWhileAsleep() async throws {
        let wake = await WakeRig { _ in ScriptedFlow({ _ in "Your download finished." }) }
        defer { Task { await wake.finish() } }
        await wake.start()
        #expect(await wake.state() == .asleep)
        // The task's result arrives with no conversation open (the race the app's reviewer found).
        #expect(wake.rig.runner.start(goal: "Download the report").isOK)
        #expect(await wake.waitFor(.awake))
        #expect(await waitUntil(timeout: 3) { wake.conversation.pushes(containing: "Your download finished.") == 1 },
                "pushed: \(wake.conversation.userMessages)")
        await wake.settle(0.3)
        #expect(wake.conversation.pushes(containing: "Your download finished.") == 1, "said once, not twice")
        #expect(wake.conversation.starts == 1, "one conversation")
        #expect(wake.conversation.userMessages.first?.contains("Your download finished.") == true,
                "no first utterance was invented: \(wake.conversation.userMessages)")
    }

    @Test("A spoken stop during a long action cancels the task, and the cycle then sleeps normally")
    func stopStillWorks() async throws {
        let wake = await WakeRig { hands in InviteFlowExecutor(hands: hands, gliding: 5) }
        defer { Task { await wake.finish() } }
        await wake.start()
        #expect(await wake.wake(saying: ""))
        wake.conversation.callTool("start_task", ["goal": .string(TaskFlowTests.goal)], id: "c1")
        _ = try #require(await wake.rig.recorder.waitFor(.question, timeout: 3))
        wake.conversation.userSays("Shah", thenAgentCalls: "answer_task", ["answer": "Priya Shah"], id: "c2")
        _ = try #require(await wake.rig.recorder.waitFor(.confirmation, timeout: 3))
        wake.conversation.userSays("yes", thenAgentCalls: "answer_task", ["answer": "yes"], id: "c3")
        #expect(await waitUntil {
            wake.rig.activity.events.contains { if case .pointerMoving(_, let duration) = $0 { duration == 5 } else { false } }
        })

        let begin = ContinuousClock.now
        wake.conversation.userSays("stop")
        #expect(await waitUntil(timeout: 1) { wake.rig.recorder.events.last?.status == .cancelled })
        #expect(secondsSince(begin) < 1)
        #expect(!wake.rig.hands.actions.items.contains("click 900,120"))
        #expect(await waitUntil(timeout: 3) { wake.conversation.pushes(containing: "stopped:") == 1 })
        await wake.settle(0.3)

        await wake.clock.advance(by: WakeRig.idleSeconds + 2)
        #expect(await wake.waitFor(.asleep))
        #expect(await waitUntil { !wake.session.isOpen })
    }

    @Test("A failed open goes back to listening, is shown once, leaves nothing reconnecting, and the next phrase works")
    func failedOpen() async throws {
        let wake = await WakeRig { _ in ScriptedFlow({ _ in "Nothing." }) }
        defer { Task { await wake.finish() } }
        await wake.start()
        wake.conversation.failingStarts = 1_000  // the voice service cannot be reached
        wake.listener.hear("open Mail")
        #expect(await waitUntil(timeout: 3) { wake.listener.startCount == 2 })
        #expect(await wake.waitFor(.asleep))
        #expect(wake.listener.isListening)
        #expect(wake.disconnections(WakeRig.couldNotConnect) == 1, "the cycle shows the failure once")
        #expect(wake.problems.items == [WakeRig.couldNotConnect])
        #expect(!wake.session.isOpen && !wake.session.hasConversationResources, "nothing keeps reconnecting while asleep")
        let attempts = wake.conversation.starts
        await wake.settle(0.3)
        #expect(wake.conversation.starts == attempts, "no further connection attempts while asleep")
        #expect(await waitUntil { wake.cycleEvents.last == "asleep" }, "bus: \(wake.cycleEvents)")

        wake.conversation.failingStarts = 0
        #expect(await wake.wake(saying: "open Mail"))
        #expect(await waitUntil { wake.conversation.userMessages.contains("open Mail") })
    }

    @Test("KNOWN ISSUE: one failed wake shows one disconnection, not one per reconnect attempt")
    func oneFailedWakeOneDisconnection() async throws {
        // HFVoice's VoiceSession posts .voiceDisconnected("I can't reach the voice service.") on every
        // failed connection attempt (connectionLost), and the cycle then posts its own sentence. So
        // one failed wake puts several disconnections on the bus, with two different sentences: in the
        // app (reconnect gaps 1, 2, 4 s; 4 s patience) about three, each a caption change and,
        // while waking, the low double note. Not HFWake's to change: see the report.
        let wake = await WakeRig { _ in ScriptedFlow({ _ in "Nothing." }) }
        defer { Task { await wake.finish() } }
        await wake.start()
        wake.conversation.failingStarts = 1_000
        wake.listener.hear("open Mail")
        #expect(await waitUntil(timeout: 3) { wake.listener.startCount == 2 })
        let shown = wake.activity.events.filter { if case .voiceDisconnected = $0 { true } else { false } }
        withKnownIssue("VoiceSession posts .voiceDisconnected per failed attempt, as well as the cycle's one") {
            #expect(shown.count == 1, "disconnections shown: \(shown)")
        }
    }

    @Test("Always mode: no listener, one conversation opened and kept open")
    func alwaysMode() async throws {
        let wake = await WakeRig(mode: .always) { _ in ScriptedFlow({ _ in "Nothing." }) }
        defer { Task { await wake.finish() } }
        await wake.start()
        #expect(await wake.waitFor(.awake))
        #expect(await waitUntil { wake.session.isConnected })
        await wake.clock.advance(by: WakeRig.idleSeconds * 6)
        #expect(await wake.state() == .awake)
        #expect(wake.listener.startCount == 0, "no wake listener in always mode")
        #expect(wake.conversation.starts == 1 && wake.conversation.ends == 0)
        #expect(await wake.cycle.requestSleep() == .alwaysOn)
        #expect(!wake.activity.events.contains(.asleep(wakePhrase: "Hey Handsfree")))
    }
}
