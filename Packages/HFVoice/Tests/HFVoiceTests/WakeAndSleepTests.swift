import Foundation
import HFCore
import Testing

@testable import HFVoice

/// The session as the listening cycle uses it: prepared once, then opened and closed on
/// every wake and sleep.
@Suite(.serialized) @MainActor struct WakeAndSleepTests {
    private func tool(_ name: String, description: String = "d") -> ToolSpec {
        ToolSpec(name: name, description: description, parameters: ["type": "object"], tier: .quick) { _ in ToolResult.ok() }
    }

    @Test func openCloseAndOpenAgainLeavesNothingBehind() async {
        let harness = Harness(mode: .text)
        let heard = Recorder<String>()
        harness.session.prepare(tools: [], memorySummary: "", onUserSentence: { heard.add($0) })
        await harness.session.open()
        await harness.settle()
        let first = harness.driver
        #expect(harness.session.isConnected)
        harness.driver.emit(.userTranscript("Volume to thirty."))
        harness.driver.emit(.voiceActivity(0.95))  // the user starts again, then the app closes
        await harness.settle()
        #expect(harness.session.isUserSpeaking)

        await harness.session.close()
        #expect(first.ended, "the SDK conversation was ended")
        #expect(!harness.session.isConnected && !harness.session.isOpen)
        #expect(!harness.session.hasConversationResources, "no driver, pump or reconnect left")
        #expect(!harness.session.isUserSpeaking, "a sentence cut off by the close holds nothing")
        // The old connection dropping now must not bring a conversation back.
        first.emit(.disconnected(reason: "dropped"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(harness.drivers.count == 1, "nothing reconnects after close")

        await harness.session.open()
        await harness.settle()
        #expect(harness.drivers.count == 2)
        #expect(harness.session.isConnected)
        #expect(harness.driver.request?.dynamicVariables["session_context"] == AgentConfiguration.dynamicVariableDefaults["session_context"],
                "a new conversation is not told the connection dropped")
        harness.driver.emit(.userTranscript("Stop."))
        await harness.settle()
        #expect(heard.all == ["Volume to thirty.", "Stop."], "the listener is called once per sentence, not once per open")
        await harness.session.close()
        #expect(!harness.session.hasConversationResources)
        #expect(harness.session.openCount == 2)
    }

    @Test func manyWakesInARowEachEndTheirConversation() async {
        let harness = Harness(mode: .text)
        harness.session.prepare(tools: [], memorySummary: "")
        for _ in 0..<5 {
            await harness.session.open()
            await harness.session.close()
        }
        #expect(harness.drivers.count == 5)
        #expect(harness.drivers.allSatisfy { $0.ended })
        #expect(!harness.session.hasConversationResources)
    }

    @Test func theAgentDefinitionIsSyncedOnceNotOnEveryOpen() async {
        let harness = Harness(mode: .text, sync: { _ in true })
        let tools = [tool("set_volume"), tool("start_task")]
        harness.session.prepare(tools: tools, memorySummary: "")
        for _ in 0..<3 {
            await harness.session.open()
            await harness.session.close()
        }
        #expect(harness.syncs.all.count == 1, "one update per launch, not one per wake")
        #expect(harness.syncs.all.first == ["set_volume", "start_task"])
        // Preparing again with the same tools changes nothing; changed tools are sent again.
        harness.session.prepare(tools: tools, memorySummary: "")
        await harness.session.open()
        await harness.session.close()
        #expect(harness.syncs.all.count == 1)
        harness.session.prepare(tools: tools + [tool("go_to_sleep")], memorySummary: "")
        await harness.session.open()
        await harness.session.close()
        await harness.settle()  // the update for the changed tools runs in the background
        #expect(harness.syncs.all.count == 2)
    }

    @Test func aFailedSyncIsTriedAgainAtTheNextWake() async {
        let attempts = Recorder<Int>()
        let harness = Harness(mode: .text, sync: { _ in attempts.add(1); return attempts.all.count > 1 })
        harness.session.prepare(tools: [tool("a")], memorySummary: "")
        await harness.session.open()
        await harness.session.close()
        await harness.session.open()
        await harness.session.close()
        await harness.session.open()
        await harness.session.close()
        await harness.settle()
        #expect(harness.syncs.all.count == 2, "failed once, then succeeded, then left alone")
    }

    @Test func theFirstWakeWaitsForAnUpdateStillOnItsWay() async {
        let order = Recorder<String>()
        let harness = Harness(mode: .text, sync: { _ in
            try? await Task.sleep(nanoseconds: 150_000_000)
            order.add("synced")
            return true
        })
        harness.session.prepare(tools: [tool("a")], memorySummary: "")
        await harness.session.open()
        order.add("connected: \(harness.session.isConnected)")
        #expect(order.all == ["synced", "connected: true"], "the agent has this run's tools before the first conversation")
        await harness.session.close()
    }

    @Test func aCredentialIsFetchedAheadForTheNextWake() async {
        let harness = Harness(mode: .text)
        harness.session.prepare(tools: [], memorySummary: "")
        await harness.settle()
        #expect(harness.prefetches.all == [true], "fetched at launch, before the first wake")
        await harness.session.open()
        await harness.session.close()
        await harness.settle()
        #expect(harness.prefetches.all == [true, true], "and again after each conversation")
    }

    @Test func theFirstUtteranceIsTheFirstUserTurnOnceConnected() async {
        let harness = Harness(mode: .text)
        let heard = Recorder<String>()
        harness.session.prepare(tools: [], memorySummary: "", onUserSentence: { heard.add($0) })
        // A task event already waiting must not go out before what the user just asked.
        harness.session.push(TaskEvent(taskID: "t1", kind: .result, status: .done, text: "Sent to Amma."))
        await harness.session.open(firstUtterance: "  open Spotify ")
        await harness.settle()
        #expect(harness.driver.userMessages.first == "open Spotify")
        #expect(heard.all == ["open Spotify"], "the stop watcher hears it too")
        #expect(harness.posted.all.contains(.userSaid("open Spotify")), "the companion shows what was heard")
        #expect(harness.driver.userMessages.count == 1, "the waiting result waits for the agent's reply")
        harness.driver.emit(.agentResponse("Opening Spotify."))
        harness.clock.advance(1)
        await harness.settle()
        #expect(harness.driver.userMessages.count == 2)
        #expect(harness.driver.userMessages.last?.contains("Sent to Amma.") == true)
        await harness.session.close()
    }

    @Test func onlyThePhraseSendsNothing() async {
        let harness = Harness(mode: .text)
        harness.session.prepare(tools: [], memorySummary: "")
        await harness.session.open(firstUtterance: "")
        await harness.settle()
        #expect(harness.driver.userMessages.isEmpty, "no greeting is asked for; the app plays a sound instead")
        await harness.session.close()
    }

    @Test func theFirstUtteranceSurvivesAFailedConnect() async {
        let harness = Harness(mode: .text)
        harness.failNextStarts = 1
        harness.session.prepare(tools: [], memorySummary: "")
        await harness.session.open(firstUtterance: "open Spotify")
        try? await Task.sleep(nanoseconds: 100_000_000)
        await harness.settle()
        #expect(harness.drivers.count == 2, "it reconnected")
        #expect(harness.drivers[0].userMessages.isEmpty)
        #expect(harness.driver.userMessages == ["open Spotify"], "said once, on the connection that worked")
        await harness.session.close()
    }

    @Test func closingDropsAnUnsentFirstUtterance() async {
        let harness = Harness(mode: .text)
        harness.failNextStarts = 1
        harness.session.prepare(tools: [], memorySummary: "")
        await harness.session.open(firstUtterance: "open Spotify")
        await harness.session.close()
        await harness.session.open()
        try? await Task.sleep(nanoseconds: 100_000_000)
        await harness.settle()
        #expect(harness.drivers.allSatisfy { $0.userMessages.isEmpty }, "an old request is not replayed into a new conversation")
        await harness.session.close()
    }

    @Test func idleSignalsFollowTheConversation() async {
        let harness = Harness(mode: .voice)
        harness.session.prepare(tools: [], memorySummary: "")
        #expect(!harness.session.activity.isOpen)
        await harness.session.open()
        await harness.settle()
        var activity = harness.session.activity
        #expect(activity.isOpen && !activity.isBusy)
        let openedAt = activity.lastActivityAt

        harness.clock.advance(5)
        harness.driver.emit(.voiceActivity(0.9))
        activity = harness.session.activity
        #expect(activity.isUserSpeaking && activity.isBusy)
        #expect(activity.lastActivityAt == harness.clock.now)

        harness.driver.emit(.userTranscript("What's the time?"))
        await harness.settle()
        harness.clock.advance(1)
        activity = harness.session.activity
        #expect(!activity.isUserSpeaking)
        #expect(activity.isAgentSpeaking, "a reply is on its way")

        harness.driver.emit(.agentActivity(.speaking))
        harness.driver.emit(.agentResponse("It's four o'clock."))
        harness.clock.advance(3)
        #expect(harness.session.activity.isAgentSpeaking, "still audible")
        harness.driver.emit(.agentActivity(.listening))
        let finishedAt = harness.clock.now
        harness.clock.advance(1)
        activity = harness.session.activity
        #expect(!activity.isBusy)
        #expect(activity.lastActivityAt == finishedAt, "idle time counts from when the agent stopped talking")
        #expect(activity.lastActivityAt > openedAt)

        await harness.session.close()
        activity = harness.session.activity
        #expect(!activity.isOpen && !activity.isBusy)
    }

    @Test func aToolRunningKeepsTheConversationBusy() async {
        let harness = Harness(mode: .text)
        let slow = ToolSpec(name: "slow", description: "d", parameters: ["type": "object"], tier: .task) { _ in
            try? await Task.sleep(nanoseconds: 300_000_000)
            return ToolResult.ok()
        }
        harness.session.prepare(tools: [slow], memorySummary: "")
        await harness.session.open()
        await harness.settle()
        harness.driver.emit(.toolCall(name: "slow", callID: "c", parameters: Data("{}".utf8)))
        harness.clock.advance(10)
        #expect(harness.session.activity.isAgentSpeaking)
        try? await Task.sleep(nanoseconds: 400_000_000)
        await harness.settle()
        harness.clock.advance(10)
        #expect(!harness.session.activity.isBusy)
        await harness.session.close()
    }

    @Test func aWaitingPushPreventsIdleUntilTheAgentHasSaidIt() async {
        let harness = Harness(mode: .voice)
        harness.session.prepare(tools: [], memorySummary: "")
        await harness.session.open()
        await harness.settle()
        harness.driver.emit(.agentActivity(.speaking))
        harness.session.push(TaskEvent(taskID: "t1", kind: .confirmation, status: .needsInput, text: "Send 'late' to Amma?"))
        await harness.settle()
        harness.driver.emit(.agentActivity(.listening))
        // The agent just stopped; the push is about to go out but has not yet.
        #expect(harness.session.queuedEventCount == 1)
        #expect(harness.session.activity.hasUnspokenNews && harness.session.activity.isBusy)
        harness.clock.advance(1)
        await harness.settle()
        #expect(harness.driver.userMessages.count == 1, "sent")
        #expect(harness.session.activity.hasUnspokenNews, "sent, but not yet said")
        harness.driver.emit(.agentActivity(.speaking))
        harness.driver.emit(.agentResponse("Send 'late' to Amma?"))
        harness.driver.emit(.agentActivity(.listening))
        harness.clock.advance(1)
        #expect(!harness.session.activity.hasUnspokenNews)
        await harness.session.close()
    }

    @Test func newsArrivingWhileClosedAsksTheAppToWake() async {
        let harness = Harness(mode: .text)
        let wakes = Recorder<Int>()
        harness.session.onNewsWhileClosed = { wakes.add(1) }
        harness.session.prepare(tools: [], memorySummary: "")
        harness.session.push(TaskEvent(taskID: "t1", kind: .progress, status: .running, text: "Opening WhatsApp"))
        await harness.settle()
        #expect(wakes.all.isEmpty, "progress is not worth waking for")
        harness.session.push(TaskEvent(taskID: "t1", kind: .result, status: .done, text: "Sent to Amma."))
        await harness.settle()
        #expect(wakes.all.count == 1)
        #expect(harness.session.activity.hasUnspokenNews, "kept until it is said")
        await harness.session.open()
        await harness.settle()
        #expect(harness.driver.userMessages.first?.contains("Sent to Amma.") == true, "said in the conversation it woke for")
        #expect(harness.driver.request?.dynamicVariables["session_context"]?.contains("Sent to Amma.") == true)
        await harness.session.close()
    }

    @Test func aDroppedConnectionWhileOpenStillReconnects() async {
        let harness = Harness(mode: .text)
        harness.session.prepare(tools: [], memorySummary: "")
        await harness.session.open()
        await harness.settle()
        harness.driver.emit(.userTranscript("Send Mum a message."))
        harness.driver.emit(.disconnected(reason: "The voice connection dropped."))
        try? await Task.sleep(nanoseconds: 100_000_000)
        await harness.settle()
        #expect(harness.drivers.count == 2)
        #expect(harness.session.isConnected && harness.session.isOpen)
        #expect(harness.driver.request?.dynamicVariables["session_context"]?.contains("dropped and came back") == true,
                "a reconnect, unlike a new wake, says what was happening")
        await harness.session.close()
    }

    @Test func theOldStartAndStopStillWork() async throws {
        let harness = Harness(mode: .text, sync: { _ in true })
        let heard = Recorder<String>()
        await harness.session.start(tools: [tool("a")], memorySummary: "m", onUserSentence: { heard.add($0) })
        await harness.settle()
        #expect(harness.session.isConnected)
        await harness.session.stop()
        await harness.session.start(tools: [tool("a")], memorySummary: "m", onUserSentence: { heard.add($0) })
        await harness.settle()
        try await harness.session.sendText("hello")
        await harness.settle()
        #expect(heard.all == ["hello"], "starting twice does not add the listener twice")
        #expect(harness.syncs.all.count == 1)
        await harness.session.stop()
    }
}

/// The fixes from the review of 6 Nov.
@Suite(.serialized) @MainActor struct WakeAndSleepReviewFixTests {
    private func tool(_ name: String) -> ToolSpec {
        ToolSpec(name: name, description: "d", parameters: ["type": "object"], tier: .quick) { _ in ToolResult.ok() }
    }

    @Test func theFirstWakeWaitsForTheUpdateOnlySoLong() async {
        let harness = Harness(mode: .text, sync: { _ in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            return true
        }, tune: { $0.firstSyncPatience = 0.1 })
        harness.session.prepare(tools: [tool("a")], memorySummary: "")
        let started = Date()
        await harness.session.open()
        #expect(Date().timeIntervalSince(started) < 1, "a slow update must not keep the user waiting in silence")
        #expect(harness.session.isConnected)
        await harness.session.close()
        let again = Date()
        await harness.session.open()
        #expect(Date().timeIntervalSince(again) < 0.5, "later wakes never wait for an update")
        #expect(harness.syncs.all.count == 1, "the update still on its way is not started twice")
        await harness.session.close()
    }

    @Test func afterAFailedUpdateWakesDoNotWaitForTheRetry() async {
        let attempts = Recorder<Int>()
        let harness = Harness(mode: .text, sync: { _ in
            attempts.add(1)
            if attempts.all.count == 1 { return false }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return true
        })
        harness.session.prepare(tools: [tool("a")], memorySummary: "")
        await harness.session.open()
        await harness.session.close()
        let started = Date()
        await harness.session.open()
        #expect(Date().timeIntervalSince(started) < 0.5)
        await harness.settle()
        #expect(attempts.all.count == 2, "the update is retried in the background")
        await harness.session.close()
    }

    @Test func closingAndOpeningAgainDuringTheUpdateConnectsOnce() async {
        let harness = Harness(mode: .text, sync: { _ in
            try? await Task.sleep(nanoseconds: 300_000_000)
            return true
        })
        harness.session.prepare(tools: [tool("a")], memorySummary: "")
        let session: VoiceSession = harness.session
        let first = Task { @MainActor in await session.open(firstUtterance: "first") }
        await harness.settle()
        await session.close()
        await session.open(firstUtterance: "second")
        await first.value
        await harness.settle()
        #expect(harness.drivers.count == 1, "only the newer wake connects")
        #expect(harness.driver.userMessages == ["second"], "the old request is not said in the new conversation")
        await session.close()
    }

    @Test func aFailedConnectEndsItsDriver() async {
        let harness = Harness(mode: .text)
        harness.failNextStarts = 1
        harness.session.prepare(tools: [], memorySummary: "")
        await harness.session.open()
        #expect(harness.drivers.first?.ended == true, "a half-started room or microphone is let go")
        await harness.session.close()
    }

    @Test func aDroppedConnectionEndsTheOldDriver() async {
        let harness = Harness(mode: .text)
        harness.session.prepare(tools: [], memorySummary: "")
        await harness.session.open()
        let old = harness.driver
        old.emit(.disconnected(reason: "dropped"))
        await harness.settle()
        #expect(old.ended)
        await harness.session.close()
    }

    @Test func aStuckSpeakingStateCannotKeepItAwakeForEver() async {
        let harness = Harness(mode: .voice)
        harness.session.prepare(tools: [], memorySummary: "")
        await harness.session.open()
        await harness.settle()
        harness.driver.emit(.agentActivity(.speaking))
        harness.clock.advance(30)
        #expect(harness.session.activity.isAgentSpeaking)
        harness.clock.advance(31)
        #expect(!harness.session.activity.isAgentSpeaking, "no word from the SDK for a minute: treated as stuck")
        await harness.session.close()
    }

    @Test func roomNoiseIsNotPostedAsSpeech() async {
        let harness = Harness(mode: .voice)
        harness.session.prepare(tools: [], memorySummary: "")
        await harness.session.open()
        await harness.settle()
        harness.driver.emit(.voiceActivity(0.3))
        await harness.settle()
        #expect(!harness.posted.all.contains { if case .userSpeaking = $0 { return true } else { return false } },
                "the listening cycle counts every .userSpeaking as activity")
        harness.driver.emit(.voiceActivity(0.8))
        await harness.settle()
        #expect(harness.posted.all.contains(.userSpeaking(level: 0.8)))
        await harness.session.close()
    }

    @Test func oldTaskNewsIsNotMentionedInANewConversation() async {
        let harness = Harness(mode: .text)
        harness.session.prepare(tools: [], memorySummary: "")
        await harness.session.open()
        harness.session.push(TaskEvent(taskID: "t1", kind: .result, status: .done, text: "Sent to Amma."))
        await harness.settle()
        await harness.session.close()
        await harness.session.open()
        #expect(harness.driver.request?.dynamicVariables["session_context"]?.contains("Sent to Amma.") == true, "recent news is mentioned")
        await harness.session.close()
        harness.clock.advance(1801)
        await harness.session.open()
        #expect(harness.driver.request?.dynamicVariables["session_context"] == AgentConfiguration.dynamicVariableDefaults["session_context"],
                "news from half an hour ago is not")
        await harness.session.close()
    }

    @Test func alwaysOpenModeTellsTheAgentThereIsNoWakePhrase() async {
        let harness = Harness(mode: .text)
        harness.session.keepsConversationOpen = true
        harness.session.prepare(tools: [], memorySummary: "")
        await harness.session.open()
        let context = harness.driver.request?.dynamicVariables["session_context"] ?? ""
        #expect(context.contains("no wake phrase and no go_to_sleep"))
        #expect(context.contains(AgentConfiguration.dynamicVariableDefaults["session_context"]!))
        await harness.session.close()
    }

    @Test func aFirstUtteranceKeptForAReconnectIsNotHeardTwice() async {
        let harness = Harness(mode: .text)
        let heard = Recorder<String>()
        harness.session.prepare(tools: [], memorySummary: "", onUserSentence: { heard.add($0) })
        // Connects, but both sends fail and the connection then drops: the sentence waits for the reconnect.
        let session: VoiceSession = harness.session
        let opening = Task { @MainActor in await session.open(firstUtterance: "open Spotify") }
        await harness.settle()
        harness.drivers.first?.failSends = true
        await opening.value
        await harness.settle()
        if harness.driver.userMessages.isEmpty {
            harness.driver.emit(.disconnected(reason: "dropped"))
            try? await Task.sleep(nanoseconds: 100_000_000)
            await harness.settle()
        }
        #expect(heard.all == ["open Spotify"], "the stop watcher hears it once, however many times it is sent")
        await harness.session.close()
    }

    @Test func theFirstUtteranceIsHeardByTheListenersBeforeItIsSent() async {
        let harness = Harness(mode: .text)
        let order = Recorder<String>()
        harness.session.prepare(tools: [], memorySummary: "", onUserSentence: { order.add("listener: \($0)") })
        await harness.session.open(firstUtterance: "stop")
        await harness.settle()
        #expect(order.all == ["listener: stop"], "told once")
        #expect(harness.driver.userMessages == ["stop"])
        await harness.session.close()
    }
}

@Suite struct ConnectionCredentialsTests {
    /// Counts token requests and hands out a new token each time.
    final class CountingHTTP: HTTPSending, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.lock(); count += 1; let number = count; lock.unlock()
            try? await Task.sleep(nanoseconds: 50_000_000)
            let body = Data(#"{"token":"t\#(number)","signed_url":"wss://example/\#(number)"}"#.utf8)
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func aPrefetchedCredentialIsUsedOnceAndNeverTwice() async throws {
        let http = CountingHTTP()
        let credentials = ConnectionCredentials(api: ElevenLabsAPI(apiKey: "k", http: http))
        await credentials.prefetch(agentID: "a", textOnly: false)
        #expect(http.requests == 1)
        let first = try await credentials.take(agentID: "a", textOnly: false)
        #expect(first == "t1")
        #expect(http.requests == 1, "the wake used the prefetched token, no fetch while connecting")
        let second = try await credentials.take(agentID: "a", textOnly: false)
        #expect(second != first, "a token is never used for two conversations")
    }

    @Test func takingDuringAPrefetchUsesItAndDoesNotKeepIt() async throws {
        let http = CountingHTTP()
        let credentials = ConnectionCredentials(api: ElevenLabsAPI(apiKey: "k", http: http))
        let prefetch = Task { await credentials.prefetch(agentID: "a", textOnly: true) }
        try? await Task.sleep(nanoseconds: 10_000_000)
        let taken = try await credentials.take(agentID: "a", textOnly: true)
        await prefetch.value
        #expect(http.requests == 1, "the fetch on its way was taken over, not repeated")
        let next = try await credentials.take(agentID: "a", textOnly: true)
        #expect(next != taken, "the taken one was not also stored for the next wake")
    }
}

@Suite struct SleepToolTests {
    @Test func itSleepsOnlyWhenNoTaskIsActiveAndSaysWhatReallyHappened() async {
        let asks = Recorder<Int>()
        let taskActive = Recorder<Bool>()
        let answer = Recorder<SleepTool.Answer>()
        taskActive.add(true)
        let tool = SleepTool.make(isTaskActive: { taskActive.all.last ?? false }, requestSleep: {
            asks.add(1)
            return answer.all.last ?? .goingToSleep
        })
        #expect(tool.name == "go_to_sleep")
        let refused = await tool.handler([:])
        #expect(refused["ok"]?.boolValue == false)
        #expect(asks.all.isEmpty, "never asked while a task is running or waiting for an answer")
        taskActive.add(false)
        let accepted = await tool.handler([:])
        #expect(accepted["ok"]?.boolValue == true)
        answer.add(.busy)
        let busy = await tool.handler([:])
        #expect(busy["ok"]?.boolValue == false, "the app stays awake, so the agent must not say Okay")
        answer.add(.notAvailable)
        let notAvailable = await tool.handler([:])
        #expect(notAvailable["ok"]?.boolValue == false)
        #expect(asks.all.count == 3)
    }

    @Test func itsDescriptionSaysWhenNotToUseIt() {
        let description = SleepTool.make(isTaskActive: { false }, requestSleep: { .goingToSleep }).description
        #expect(description.contains("that's all"))
        #expect(description.contains("Never use it while a task is running"))
        #expect(description.contains("never because the user is silent"))
        #expect(description.contains("\"stop\""))
    }
}

@Suite(.serialized) @MainActor struct FailedWakeAnnouncementTests {
    private func disconnections(_ posted: [ActivityEvent]) -> Int {
        posted.filter { if case .voiceDisconnected = $0 { return true } else { return false } }.count
    }

    @Test func withTheListeningCycleAFailedOpenIsNotAnnouncedPerAttempt() async {
        let harness = Harness(mode: .text)
        harness.session.announcesFailedOpens = false
        harness.failNextStarts = 3
        harness.session.prepare(tools: [], memorySummary: "")
        await harness.session.open()
        try? await Task.sleep(nanoseconds: 150_000_000)
        await harness.settle()
        #expect(harness.drivers.count >= 3, "it kept retrying")
        #expect(disconnections(harness.posted.all) == 0, "the cycle announces a failed wake once, not the session per attempt")
        // Once connected, a real drop is still announced.
        #expect(harness.session.isConnected)
        harness.driver.emit(.disconnected(reason: "The voice connection dropped."))
        await harness.settle()
        #expect(disconnections(harness.posted.all) == 1)
        await harness.session.close()
    }

    @Test func withoutTheCycleFailedOpensAreStillAnnounced() async {
        let harness = Harness(mode: .text)
        harness.failNextStarts = 1
        harness.session.prepare(tools: [], memorySummary: "")
        await harness.session.open()
        await harness.settle()
        #expect(disconnections(harness.posted.all) == 1, "wake mode always: nobody else would say it")
        await harness.session.close()
    }
}
