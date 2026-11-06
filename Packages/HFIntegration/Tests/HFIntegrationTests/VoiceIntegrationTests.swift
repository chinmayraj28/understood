import CoreGraphics
import Foundation
import HFCore
import HFDecisions
import HFScreenAgent
import HFTasks
@testable import HFVoice  // the SDK seam (ConversationDriving, the full initialiser) is internal
import Testing

// The real VoiceSession with only the ElevenLabs SDK faked, wired to the real
// runner, the real task tools and the real StopWatcher the way the app wires
// them: tool calls arrive from the "agent", task events are pushed back into
// the conversation, and every user sentence reaches the stop watcher first.

/// Stands in for the ElevenLabs SDK: records what the session sends, and lets
/// the test play what the agent and the user do.
@MainActor
final class FakeConversation: ConversationDriving {
    var userMessages: [String] = []
    var contexts: [String] = []
    var toolResults: [(callID: String, text: String, isError: Bool)] = []
    private var onSignal: (@MainActor @Sendable (ConversationSignal) -> Void)?

    func start(_ start: ConversationStart, onSignal: @escaping @MainActor @Sendable (ConversationSignal) -> Void) async throws {
        self.onSignal = onSignal
    }
    /// Like the real agent, reply to every pushed message (the session waits for a reply before pushing more).
    var repliesToPushes = true

    func sendUserMessage(_ text: String) async throws {
        userMessages.append(text)
        guard repliesToPushes else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000)
            self?.emit(.agentResponse("(says it)"))
        }
    }
    func sendContext(_ text: String) async throws { contexts.append(text) }
    func sendToolResult(callID: String, text: String, isError: Bool) async throws { toolResults.append((callID, text, isError)) }
    func end() async {}

    func emit(_ signal: ConversationSignal) { onSignal?(signal) }

    /// The agent calls one of our tools.
    func callTool(_ name: String, _ parameters: JSONObject, id: String) {
        let data = (try? JSONEncoder().encode(JSONValue.object(parameters))) ?? Data("{}".utf8)
        emit(.toolCall(name: name, callID: id, parameters: data))
    }

    /// The user says something, the agent passes it on with a tool, then replies (as the real agent always does).
    func userSays(_ text: String, thenAgentCalls tool: String? = nil, _ parameters: JSONObject = [:], id: String = UUID().uuidString) {
        emit(.userTranscript(text))
        if let tool { callTool(tool, parameters, id: id) }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000)
            self?.emit(.agentResponse("(answers the user)"))
        }
    }

    func pushed(containing text: String) -> Bool { userMessages.contains { $0.contains(text) } }
}

/// The app's wiring of voice, stop watcher, runner and tools.
@MainActor
final class VoiceRig {
    let conversation = FakeConversation()
    let session: VoiceSession
    var rig: Rig!
    var watcher: StopWatcher!
    let heard = Log<String>()

    init(executor: @escaping (FakeHands, VoiceSession) -> any TaskExecuting) async {
        var tuning = VoiceSession.Tuning()
        tuning.pumpInterval = 0.01
        tuning.settleAfterReply = 0.05
        tuning.userQuietAfter = 0.1
        let conversation = conversation
        session = VoiceSession(
            agentID: "agent_test", mode: .voice, bus: ActivityBus(), tuning: tuning,
            makeDriver: { conversation },
            clock: { ProcessInfo.processInfo.systemUptime },
            sleep: { seconds in try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1e9)) },
            syncAgent: nil)
        let session = session
        rig = Rig(alsoSendEventsTo: { session.push($0) }) { hands in executor(hands, session) }
        let runner = rig.runner
        watcher = StopWatcher(
            classifier: Classifiers(client: nil),
            isTaskRunning: { runner.isRunning },
            isAwaitingAnswer: { runner.isAwaitingAnswer },
            currentTaskID: { runner.status()["task_id"]?.stringValue },
            cancel: { _ = runner.cancel(taskID: nil) })
        let watcher = watcher!, heard = heard
        await session.start(tools: Array(rig.tools.values), memorySummary: "") { sentence in
            // Record what the runner looked like at the moment the watcher heard the sentence.
            heard.append("\(sentence) | awaiting=\(runner.isAwaitingAnswer)")
            watcher.heard(sentence)
        }
    }

    func stop() async { await session.stop() }

    func toolResult(_ id: String) -> String? { conversation.toolResults.first { $0.callID == id }?.text }
}

@Suite(.serialized) @MainActor struct VoiceIntegrationTests {

    static let goal = TaskFlowTests.goal

    @Test("Tool calls from the agent drive the runner, and its question is pushed back to be said")
    func toolCallsAndQuestionPush() async throws {
        let voice = await VoiceRig { hands, _ in InviteFlowExecutor(hands: hands) }
        defer { Task { await voice.stop() } }
        #expect(voice.session.isConnected)

        voice.conversation.callTool("start_task", ["goal": .string(Self.goal)], id: "call-1")
        #expect(await waitUntil { voice.toolResult("call-1") != nil })
        let reply = try #require(voice.toolResult("call-1"))
        #expect(reply.contains("\"status\":\"running\"") && reply.contains("\"task_id\":\"t1\""), "tool result: \(reply)")

        #expect(await waitUntil(timeout: 3) { voice.conversation.pushed(containing: "asks: Priya Shah or Priya Patel?") },
                "pushed: \(voice.conversation.userMessages)")
        #expect(voice.conversation.pushed(containing: "Options: Priya Shah, Priya Patel."))
    }

    @Test("A confirmation waits until the agent stops speaking, then is pushed")
    func confirmationWaitsForQuiet() async throws {
        let voice = await VoiceRig { hands, _ in InviteFlowExecutor(hands: hands) }
        defer { Task { await voice.stop() } }
        voice.conversation.callTool("start_task", ["goal": .string(Self.goal)], id: "c1")
        #expect(await waitUntil(timeout: 3) { voice.conversation.pushed(containing: "asks: Priya Shah") })

        // The agent is still talking when the user answers and the task reaches Send.
        voice.conversation.emit(.agentActivity(.speaking))
        voice.conversation.userSays("Shah", thenAgentCalls: "answer_task", ["answer": "Priya Shah"], id: "c2")
        voice.conversation.emit(.agentResponse("Got it, Priya Shah."))
        #expect(await voice.rig.recorder.waitFor(.confirmation) != nil)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(!voice.conversation.pushed(containing: "needs a clear yes"), "pushed over the agent: \(voice.conversation.userMessages)")

        voice.conversation.emit(.agentActivity(.listening))
        #expect(await waitUntil(timeout: 3) {
            voice.conversation.pushed(containing: "needs a clear yes before it goes ahead: Send the invite to Priya Shah for tomorrow at 3pm?")
        }, "pushed: \(voice.conversation.userMessages)")
    }

    @Test("A bare \"no\" reaches the stop watcher before answer_task, so it is a decline, not a cancel")
    func noReachesWatcherFirst() async throws {
        let voice = await VoiceRig { hands, _ in InviteFlowExecutor(hands: hands) }
        defer { Task { await voice.stop() } }
        voice.conversation.callTool("start_task", ["goal": .string(Self.goal)], id: "c1")
        _ = try #require(await voice.rig.recorder.waitFor(.question))
        voice.conversation.userSays("Shah", thenAgentCalls: "answer_task", ["answer": "Priya Shah"], id: "c2")
        _ = try #require(await voice.rig.recorder.waitFor(.confirmation))

        // The same turn: the sentence, and the agent's tool call passing it on.
        voice.conversation.userSays("no", thenAgentCalls: "answer_task", ["answer": "no"], id: "c3")
        #expect(await waitUntil { voice.toolResult("c3") != nil })
        _ = await voice.watcher.waitUntilIdle(timeoutSeconds: 2)
        #expect(voice.heard.items.contains("no | awaiting=true"), "the watcher must hear it while the question is open: \(voice.heard.items)")
        let result = try #require(await voice.rig.recorder.waitFor(.result))
        #expect(result.status == .done && result.text == "I didn't send the invite.")
        #expect(!voice.rig.hands.actions.items.contains("click 900,120"))
        #expect(await waitUntil(timeout: 3) { voice.conversation.pushed(containing: "finished: I didn't send the invite.") })
    }

    @Test("\"Stop\" said during a long glide cancels through the voice session and freezes the hands")
    func spokenStop() async throws {
        let voice = await VoiceRig { hands, _ in InviteFlowExecutor(hands: hands, gliding: 5) }
        defer { Task { await voice.stop() } }
        voice.conversation.callTool("start_task", ["goal": .string(Self.goal)], id: "c1")
        _ = try #require(await voice.rig.recorder.waitFor(.question))
        voice.conversation.userSays("Shah", thenAgentCalls: "answer_task", ["answer": "Priya Shah"], id: "c2")
        _ = try #require(await voice.rig.recorder.waitFor(.confirmation))
        voice.conversation.userSays("yes", thenAgentCalls: "answer_task", ["answer": "yes"], id: "c3")
        #expect(await waitUntil {
            voice.rig.activity.events.contains { if case .pointerMoving(_, let duration) = $0 { duration == 5 } else { false } }
        })
        let begin = ContinuousClock.now
        voice.conversation.userSays("stop")
        #expect(await waitUntil(timeout: 1) { voice.rig.recorder.events.last?.status == .cancelled })
        #expect(secondsSince(begin) < 1)
        #expect(await waitUntil(timeout: 1) { voice.rig.hands.actions.items.last == "resume" })
        #expect(!voice.rig.hands.actions.items.contains("click 900,120"))
        #expect(await waitUntil(timeout: 3) { voice.conversation.pushed(containing: "stopped:") })
    }

    @Test("While the user is speaking, the screen agent holds before its next action")
    func holdWhileSpeaking() async throws {
        let model = ScriptedModel(thinkingSeconds: 0.15, turns: ScriptedModel.inviteFlow())
        let voice = await VoiceRig { hands, session in
            ScreenAgent(
                hands: hands, eyes: FakeEyes(), labels: FakeCalendarLabels(), client: model,
                configuration: ScreenAgentConfiguration(model: "claude-sonnet-5-5", settleSeconds: 0),
                holdWhile: { session.isUserSpeaking })
        }
        defer { Task { await voice.stop() } }
        voice.conversation.callTool("start_task", ["goal": .string(Self.goal)], id: "c1")
        _ = try #require(await voice.rig.recorder.waitFor(.question, timeout: 5))
        voice.conversation.userSays("Shah", thenAgentCalls: "answer_task", ["answer": "Priya Shah"], id: "c2")

        // The user keeps talking while the model decides its next step (a click on the guests field).
        voice.conversation.emit(.voiceActivity(0.9))
        #expect(voice.session.isUserSpeaking)
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(model.requestCount >= 2, "the model was asked for the next step")
        #expect(!voice.rig.hands.actions.items.contains { $0.hasPrefix("click") }, "no action may start while the user speaks")

        // Their sentence arrives; after the short tail the agent carries on.
        voice.conversation.userSays("and make it a video call")
        #expect(await waitUntil(timeout: 3) { voice.rig.hands.actions.items.contains("click 400,300") })
        #expect(!voice.heard.items.isEmpty)
        let confirmation = try #require(await voice.rig.recorder.waitFor(.confirmation, timeout: 5))
        #expect(confirmation.text.hasPrefix("Send \"Priya Shah\""))
        voice.conversation.userSays("yes", thenAgentCalls: "answer_task", ["answer": "yes"], id: "c3")
        #expect(await voice.rig.recorder.waitFor(.result, timeout: 5)?.status == .done)
    }
}
