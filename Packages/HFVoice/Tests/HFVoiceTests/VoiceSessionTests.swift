import Foundation
import HFCore
import Testing

@testable import HFVoice

/// Stands in for the ElevenLabs SDK.
@MainActor
final class FakeDriver: ConversationDriving {
    var request: ConversationStart?
    var userMessages: [String] = []
    var contexts: [String] = []
    var toolResults: [(callID: String, text: String, isError: Bool)] = []
    var ended = false
    var failStart = false
    var failSends = false
    private var onSignal: (@MainActor @Sendable (ConversationSignal) -> Void)?

    func start(_ start: ConversationStart, onSignal: @escaping @MainActor @Sendable (ConversationSignal) -> Void) async throws {
        request = start
        if failStart { throw SpeakableError("no network") }
        self.onSignal = onSignal
    }
    func emit(_ signal: ConversationSignal) { onSignal?(signal) }
    func sendUserMessage(_ text: String) async throws {
        if failSends { throw SpeakableError("socket closed") }
        userMessages.append(text)
    }
    func sendContext(_ text: String) async throws { contexts.append(text) }
    func sendToolResult(callID: String, text: String, isError: Bool) async throws { toolResults.append((callID, text, isError)) }
    func end() async { ended = true }
}

/// A clock the test moves by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval = 1000
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current += seconds; lock.unlock() }
}

/// A session wired to fakes. `sleep` returns almost at once but records what was asked.
@MainActor
final class Harness {
    let clock = TestClock()
    let bus = ActivityBus()
    let posted = Recorder<ActivityEvent>()
    let sleeps = Recorder<TimeInterval>()
    var drivers: [FakeDriver] = []
    var failNextStarts = 0
    var session: VoiceSession!
    /// Every tool list sent to the agent's definition.
    let syncs = Recorder<[String]>()
    let prefetches = Recorder<Bool>()
    private var busTask: Task<Void, Never>?

    /// - Parameter sync: what updating the agent does; nil means the session has no sync at all.
    init(mode: VoiceSession.Mode = .voice, agentID: String = "agent_1",
         sync: (@Sendable ([ToolSpec]) async -> Bool)? = nil,
         tune: (inout VoiceSession.Tuning) -> Void = { _ in }) {
        var tuning = VoiceSession.Tuning()
        tuning.pumpInterval = 0.01
        tune(&tuning)
        let clock = clock, sleeps = sleeps, syncs = syncs, prefetches = prefetches
        let recordingSync: (@Sendable ([ToolSpec]) async -> Bool)? = sync.map { sync in
            { tools in syncs.add(tools.map(\.name)); return await sync(tools) }
        }
        session = VoiceSession(
            agentID: agentID, mode: mode, bus: bus, tuning: tuning,
            makeDriver: { [unowned self] in
                let driver = FakeDriver()
                if self.failNextStarts > 0 { self.failNextStarts -= 1; driver.failStart = true }
                self.drivers.append(driver)
                return driver
            },
            clock: { clock.now },
            sleep: { seconds in sleeps.add(seconds); try? await Task.sleep(nanoseconds: 1_000_000) },
            syncAgent: recordingSync,
            prepareNextConnection: { start in prefetches.add(start.textOnly) })
        let stream = bus.events()
        let posted = posted
        busTask = Task { for await event in stream { posted.add(event) } }
    }

    var driver: FakeDriver { drivers.last! }

    /// Lets queued main-actor work and the background listener queue run.
    func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 30_000_000)
    }

    func start(tools: [ToolSpec] = [], memory: String = "- alias mum: Amma (in whatsapp)") async {
        await session.start(tools: tools, memorySummary: memory)
        await settle()
    }
}

private let question = TaskEvent(taskID: "t1", kind: .question, status: .needsInput, text: "Priya Shah or Priya Patel?", options: ["Priya Shah", "Priya Patel"])

@Suite(.serialized) @MainActor struct VoiceSessionTests {
    @Test func startSendsMemoryAndModeAndPostsListening() async {
        let harness = Harness(mode: .text)
        await harness.start()
        #expect(harness.session.isConnected)
        let request = harness.driver.request
        #expect(request?.agentID == "agent_1")
        #expect(request?.textOnly == true)
        #expect(request?.dynamicVariables["user_memory"] == "- alias mum: Amma (in whatsapp)")
        #expect(request?.dynamicVariables["session_context"] == AgentConfiguration.dynamicVariableDefaults["session_context"])
        #expect(harness.posted.all.contains(.listening))
    }

    @Test func withoutAnAgentIdItSaysSoAndDoesNotConnect() async {
        let harness = Harness(agentID: "")
        await harness.start()
        #expect(harness.drivers.isEmpty)
        #expect(harness.posted.all.contains { if case .voiceDisconnected = $0 { return true } else { return false } })
    }

    @Test func toolCallsAreRoutedAndAnsweredWithJSONText() async {
        let harness = Harness()
        let tool = ToolSpec(name: "set_volume", description: "d", parameters: ["type": "object"], tier: .quick) { parameters in
            ToolResult.ok(["volume": parameters["percent"] ?? .null])
        }
        await harness.start(tools: [tool])
        harness.driver.emit(.toolCall(name: "set_volume", callID: "call_1", parameters: Data(#"{"percent":30}"#.utf8)))
        await harness.settle()
        #expect(harness.driver.toolResults.count == 1)
        #expect(harness.driver.toolResults.first?.callID == "call_1")
        #expect(harness.driver.toolResults.first?.text == #"{"ok":true,"volume":30}"#)
        #expect(harness.driver.toolResults.first?.isError == false)
    }

    @Test func aSlowToolDoesNotHoldUpTheConversation() async {
        let harness = Harness()
        let heard = Recorder<String>()
        harness.session.addTranscriptListener { heard.add($0) }
        let slow = ToolSpec(name: "slow", description: "d", parameters: ["type": "object"], tier: .task) { _ in
            try? await Task.sleep(nanoseconds: 500_000_000)
            return ToolResult.ok()
        }
        await harness.start(tools: [slow])
        harness.driver.emit(.toolCall(name: "slow", callID: "c", parameters: Data("{}".utf8)))
        harness.driver.emit(.userTranscript("Stop."))
        await harness.settle()
        #expect(heard.all == ["Stop."], "the transcript arrived while the tool was still running")
        #expect(harness.driver.toolResults.isEmpty)
        try? await Task.sleep(nanoseconds: 600_000_000)
        #expect(harness.driver.toolResults.count == 1)
    }

    @Test func listenersHearEverySentenceInOrderAndCannotBlockTheSession() async {
        let harness = Harness()
        let heard = Recorder<String>()
        harness.session.addTranscriptListener { _ in Thread.sleep(forTimeInterval: 0.3) }  // a slow listener
        harness.session.addTranscriptListener { heard.add($0) }
        await harness.start()
        let before = Date()
        harness.driver.emit(.userTranscript("Volume to thirty."))
        harness.driver.emit(.userTranscript("Stop."))
        #expect(Date().timeIntervalSince(before) < 0.05, "handling a transcript returns at once")
        try? await Task.sleep(nanoseconds: 800_000_000)
        #expect(heard.all == ["Volume to thirty.", "Stop."])
        #expect(harness.posted.all.contains(.userSaid("Stop.")))
    }

    @Test func sendTextSendsAndTellsTheListeners() async throws {
        let harness = Harness(mode: .text)
        let heard = Recorder<String>()
        harness.session.addTranscriptListener { heard.add($0) }
        await harness.start()
        try await harness.session.sendText("Volume to thirty.")
        await harness.settle()
        #expect(harness.driver.userMessages == ["Volume to thirty."])
        #expect(heard.all == ["Volume to thirty."])
    }

    @Test func aPushWaitsWhileTheAgentIsSpeaking() async {
        let harness = Harness()
        await harness.start()
        harness.driver.emit(.agentActivity(.speaking))
        harness.session.push(question)
        await harness.settle()
        #expect(harness.driver.userMessages.isEmpty, "a push would cut the agent off")
        harness.driver.emit(.agentActivity(.listening))
        harness.clock.advance(1)
        await harness.settle()
        #expect(harness.driver.userMessages.count == 1)
        #expect(harness.driver.userMessages.first?.hasPrefix("[APP] Task t1 asks: Priya Shah or Priya Patel?") == true)
    }

    @Test func aPushWaitsForTheAgentsReplyAndForTheUserToBeQuiet() async {
        let harness = Harness(mode: .text)
        await harness.start()
        harness.driver.emit(.userTranscript("Book a meeting with Priya."))
        harness.session.push(question)
        await harness.settle()
        #expect(harness.driver.userMessages.isEmpty, "a reply is on its way")
        harness.driver.emit(.agentResponse("On it."))
        harness.driver.emit(.voiceActivity(0.9))
        await harness.settle()
        #expect(harness.driver.userMessages.isEmpty, "the user is speaking")
        harness.clock.advance(1)
        await harness.settle()
        #expect(harness.driver.userMessages.count == 1)
    }

    @Test func eventsWaitingTogetherGoOutAsOneMessageInOrder() async {
        let harness = Harness()
        await harness.start()
        harness.driver.emit(.agentActivity(.speaking))
        harness.session.push(TaskEvent(taskID: "t1", kind: .progress, status: .running, text: "Opening WhatsApp"))
        harness.session.push(TaskEvent(taskID: "t1", kind: .confirmation, status: .needsInput, text: "Send 'late' to Amma?"))
        harness.session.push(TaskEvent(taskID: "t1", kind: .result, status: .cancelled, text: "Stopped before sending."))
        await harness.settle()
        harness.driver.emit(.agentActivity(.listening))
        harness.clock.advance(1)
        await harness.settle()
        #expect(harness.driver.userMessages.count == 1)
        let message = harness.driver.userMessages.first ?? ""
        #expect(!message.contains("Opening WhatsApp"), "progress is dropped behind more important news")
        #expect(message.contains("Send 'late' to Amma?") && message.contains("Stopped before sending."))
        #expect(harness.driver.contexts.contains { $0.contains("Opening WhatsApp") }, "progress still reaches the context silently")
    }

    @Test func aConfirmationThatFailsToSendIsKeptAndSentAfterReconnecting() async {
        let harness = Harness()
        await harness.start()
        harness.driver.failSends = true
        harness.session.push(TaskEvent(taskID: "t1", kind: .confirmation, status: .needsInput, text: "Send 'late' to Amma?"))
        await harness.settle()
        #expect(harness.session.queuedEventCount == 1)
        harness.driver.emit(.disconnected(reason: "The voice connection dropped."))
        try? await Task.sleep(nanoseconds: 100_000_000)
        await harness.settle()
        #expect(harness.drivers.count == 2)
        #expect(harness.driver.request?.dynamicVariables["session_context"]?.contains("Send 'late' to Amma?") == true)
        #expect(harness.driver.userMessages.first?.contains("Send 'late' to Amma?") == true)
        #expect(harness.session.queuedEventCount == 0)
    }

    @Test func reconnectsWithGrowingGapsAndCarriesTheConversationOver() async {
        let harness = Harness()
        await harness.start()
        harness.driver.emit(.userTranscript("Send Mum a message."))
        harness.driver.emit(.agentResponse("On it."))
        harness.failNextStarts = 2
        harness.driver.emit(.disconnected(reason: "The voice connection dropped."))
        try? await Task.sleep(nanoseconds: 200_000_000)
        await harness.settle()
        #expect(harness.drivers.count == 4, "two failed attempts, then a good one")
        #expect(harness.session.isConnected)
        #expect(Array(harness.sleeps.all.filter { $0 >= 1 }.prefix(3)) == [1, 2, 4])
        let context = harness.driver.request?.dynamicVariables["session_context"] ?? ""
        #expect(context.contains("User: Send Mum a message.") && context.contains("Agent: On it."))
        #expect(harness.posted.all.contains(.voiceDisconnected(reason: "The voice connection dropped.")))
    }

    @Test func signalsFromAnOldConnectionAreIgnored() async {
        let harness = Harness()
        let heard = Recorder<String>()
        harness.session.addTranscriptListener { heard.add($0) }
        await harness.start()
        let old = harness.driver
        old.emit(.disconnected(reason: "dropped"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        await harness.settle()
        old.emit(.userTranscript("ghost"))
        await harness.settle()
        #expect(heard.all.isEmpty)
    }

    @Test func stopEndsTheConversationAndDoesNotReconnect() async {
        let harness = Harness()
        await harness.start()
        let driver = harness.driver
        await harness.session.stop()
        #expect(driver.ended)
        #expect(!harness.session.isConnected)
        driver.emit(.disconnected(reason: "dropped"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(harness.drivers.count == 1)
    }

    @Test func theListenerHearsTheTranscriptBeforeTheSameTurnsToolRuns() async {
        let harness = Harness()
        let order = Recorder<String>()
        // A listener that takes a moment, as the stop watcher reading the runner's state might.
        harness.session.addTranscriptListener { text in
            Thread.sleep(forTimeInterval: 0.08)
            order.add("listener: \(text)")
        }
        let answerTask = ToolSpec(name: "answer_task", description: "d", parameters: ["type": "object"], tier: .task) { parameters in
            order.add("answer_task: \(parameters["answer"]?.stringValue ?? "")")
            return ToolResult.ok()
        }
        await harness.start(tools: [answerTask])
        harness.driver.emit(.userTranscript("Yes, send it."))
        harness.driver.emit(.toolCall(name: "answer_task", callID: "c1", parameters: Data(#"{"answer":"Yes, send it."}"#.utf8)))
        try? await Task.sleep(nanoseconds: 300_000_000)
        await harness.settle()
        #expect(order.all == ["listener: Yes, send it.", "answer_task: Yes, send it."])
        #expect(harness.driver.toolResults.count == 1)
    }

    @Test func isUserSpeakingFromFirstVoiceUntilTheTranscriptIsDelivered() async {
        let harness = Harness()
        let heard = Recorder<String>()
        harness.session.addTranscriptListener { heard.add($0) }
        await harness.start()
        #expect(!harness.session.isUserSpeaking)
        harness.driver.emit(.voiceActivity(0.11))
        #expect(!harness.session.isUserSpeaking, "the agent's own voice level does not count")
        harness.driver.emit(.voiceActivity(0.97))
        #expect(harness.session.isUserSpeaking, "true at once, from any thread")
        let session: VoiceSession = harness.session
        let fromAnotherThread = await Task.detached { session.isUserSpeaking }.value
        #expect(fromAnotherThread)
        harness.clock.advance(1.5)  // speech over, transcript not here yet
        #expect(harness.session.isUserSpeaking)
        harness.driver.emit(.userTranscript("Stop."))
        await harness.settle()
        #expect(heard.all == ["Stop."])
        #expect(!harness.session.isUserSpeaking)
    }

    @Test func progressIsContextOnlyWhileQuestionsAndResultsAreSaid() async {
        let harness = Harness(mode: .text)
        await harness.start()
        harness.session.push(TaskEvent(taskID: "t1", kind: .progress, status: .running, text: "Opening WhatsApp"))
        await harness.settle()
        harness.clock.advance(1)
        await harness.settle()
        #expect(harness.driver.userMessages.isEmpty, "progress never asks the agent to speak (it said \"Nothing to add yet.\" every time)")
        #expect(harness.driver.contexts == ["Task t1 progress (running): Opening WhatsApp"], "it reaches the agent silently")
        #expect(harness.session.queuedEventCount == 0)
        #expect(!harness.session.activity.hasUnspokenNews, "progress is not news the conversation must stay open for")

        harness.session.push(TaskEvent(taskID: "t1", kind: .question, status: .needsInput, text: "Amma or Amma Work?"))
        await harness.settle()
        #expect(harness.driver.userMessages.count == 1, "a question is said at once")
        harness.driver.emit(.agentResponse("Amma or Amma Work?"))
        harness.clock.advance(1)
        harness.session.push(TaskEvent(taskID: "t1", kind: .result, status: .done, text: "Sent to Amma."))
        await harness.settle()
        #expect(harness.driver.userMessages.count == 2, "and so is the final result")
        #expect(harness.driver.userMessages.last?.contains("Sent to Amma.") == true)
    }

    @Test func anAnswerRelayedSilentlyHoldsAConfirmationForAtMostTheReplyTimeout() async {
        let harness = Harness(mode: .text)
        let answerTask = ToolSpec(name: "answer_task", description: "d", parameters: ["type": "object"], tier: .task) { _ in ToolResult.ok() }
        await harness.start(tools: [answerTask])
        // The user answers; the agent passes it on with answer_task and says nothing.
        harness.driver.emit(.userTranscript("Shah."))
        harness.driver.emit(.toolRequested)
        harness.driver.emit(.toolCall(name: "answer_task", callID: "c1", parameters: Data(#"{"answer":"Shah."}"#.utf8)))
        harness.driver.emit(.toolAnswered)
        await harness.settle()
        harness.session.push(TaskEvent(taskID: "t1", kind: .confirmation, status: .needsInput, text: "Invite Priya Shah?"))
        harness.clock.advance(3)
        await harness.settle()
        #expect(harness.driver.userMessages.isEmpty, "a reply may still be coming")
        harness.clock.advance(1.1)
        await harness.settle()
        #expect(harness.driver.userMessages.count == 1, "no reply came, so the confirmation goes out")
    }

    @Test func voiceStatesReachTheActivityBus() async {
        let harness = Harness()
        await harness.start()
        harness.driver.emit(.voiceActivity(0.7))
        harness.driver.emit(.agentResponse("Volume's at thirty."))
        await harness.settle()
        #expect(harness.posted.all.contains(.userSpeaking(level: 0.7)))
        #expect(harness.posted.all.contains(.agentSpeaking("Volume's at thirty.")))
    }
}
