import Foundation
import HFCore
import Testing

@testable import HFVoice

/// A failed or slow check of the agent never refuses a wake that would have worked (review of 6 Nov):
/// only a confirmed mismatch that a repair could not fix does.
@Suite(.serialized) @MainActor struct AgentCheckFailureTests {
    /// An agent whose read-backs and updates can be made to fail, be slow, or say anything.
    final class ScriptedAgent: @unchecked Sendable {
        private let lock = NSLock()
        var verifyResult: (@Sendable ([ToolSpec]) -> AgentCheck)
        var pushResult: (@Sendable ([ToolSpec]) -> AgentCheck)
        var verifyDelay: TimeInterval = 0
        var pushDelay: TimeInterval = 0
        private(set) var pushes = 0
        private(set) var verifies = 0
        init() {
            verifyResult = { AgentCheck.matching($0) }
            pushResult = { AgentCheck.matching($0) }
        }
        var keeper: AgentKeeper {
            AgentKeeper(
                push: { tools in
                    let (delay, result) = self.lock.withLock { self.pushes += 1; return (self.pushDelay, self.pushResult) }
                    if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                    return result(tools)
                },
                verify: { tools in
                    let (delay, result) = self.lock.withLock { self.verifies += 1; return (self.verifyDelay, self.verifyResult) }
                    if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                    return result(tools)
                })
        }
        var pushCount: Int { lock.withLock { pushes } }
    }

    static let unreachable: @Sendable ([ToolSpec]) -> AgentCheck = { _ in .couldNotCheck(detail: "HTTP 503", at: Date()) }
    static let wrong: @Sendable ([ToolSpec]) -> AgentCheck = { _ in
        AgentCheck(inSync: false, toolNamesOnAgent: ["demo_set_volume"], missing: ["set_volume"], unexpected: ["demo_set_volume"],
                   checkedAt: Date(), problem: AgentCheck.notSetUpSentence, detail: nil)
    }

    private let tools = ["set_volume", "start_task"].map { name in
        ToolSpec(name: name, description: "d", parameters: ["type": "object"], tier: .quick) { _ in ToolResult.ok() }
    }

    private func harness(_ agent: ScriptedAgent, tune: (inout VoiceSession.Tuning) -> Void = { _ in }) -> Harness {
        let harness = Harness(mode: .text)
        var tuning = VoiceSession.Tuning()
        tuning.pumpInterval = 0.01
        tune(&tuning)
        harness.session = VoiceSession(
            agentID: "agent_1", mode: .text, bus: harness.bus, tuning: tuning,
            makeDriver: { [unowned harness] in let driver = FakeDriver(); harness.drivers.append(driver); return driver },
            clock: { [clock = harness.clock] in clock.now }, sleep: { _ in try? await Task.sleep(nanoseconds: 1_000_000) },
            syncAgent: nil, agentKeeper: agent.keeper)
        return harness
    }

    @Test func aFailedReadBackAtAWakeCarriesOnAndResendsNothing() async {
        let agent = ScriptedAgent()
        let harness = harness(agent)
        harness.session.prepare(tools: tools, memorySummary: "")
        await harness.session.open()  // the launch update: in step
        await harness.settle()
        await harness.session.close()
        let pushesBefore = agent.pushCount
        agent.verifyResult = Self.unreachable
        await harness.session.open(firstUtterance: "open Spotify")
        await harness.settle()
        #expect(harness.session.isConnected && harness.drivers.count == 2, "the working conversation is kept")
        #expect(harness.driver.userMessages == ["open Spotify"], "the user is heard")
        #expect(!harness.driver.ended)
        #expect(agent.pushCount == pushesBefore, "a failed read says nothing about the agent: nothing is re-sent")
        #expect(harness.session.agentCheck?.couldNotCheck == true, "shown as could-not-check (amber)")
        #expect(harness.session.confirmedCheck?.inSync == true, "the last good check still decides")
        #expect(harness.session.openRefusal == nil)
        await harness.session.close()
    }

    @Test func aSlowReadBackHoldsTheWakeForAtMostItsPatience() async {
        let agent = ScriptedAgent()
        let harness = harness(agent) { $0.wakeCheckPatience = 0.2 }
        harness.session.prepare(tools: tools, memorySummary: "")
        await harness.session.open()
        await harness.settle()
        await harness.session.close()
        agent.verifyDelay = 3
        let started = Date()
        await harness.session.open(firstUtterance: "hello")
        #expect(Date().timeIntervalSince(started) < 1, "the wake did not wait for the slow read-back")
        await harness.settle()
        #expect(harness.driver.userMessages == ["hello"])
        await harness.session.close()
    }

    @Test func onTheFirstLaunchAFailingCheckStillOpensAndToolsWaitBriefly() async {
        let agent = ScriptedAgent()
        agent.pushResult = Self.unreachable
        agent.verifyResult = Self.unreachable
        let ran = Recorder<String>()
        let tool = ToolSpec(name: "set_volume", description: "d", parameters: ["type": "object"], tier: .quick) { _ in
            ran.add("set_volume"); return ToolResult.ok()
        }
        let harness = harness(agent) { $0.wakeCheckPatience = 0.3 }
        harness.session.prepare(tools: [tool], memorySummary: "")
        await harness.session.open(firstUtterance: "volume to thirty")
        await harness.settle()
        #expect(harness.session.isConnected, "no confirmed mismatch, so the conversation opens")
        #expect(harness.session.openRefusal == nil)
        harness.driver.emit(.toolCall(name: "set_volume", callID: "c1", parameters: Data(#"{"percent":30}"#.utf8)))
        await harness.settle()
        // The first check never succeeds here, so the tool waits out the patience, then runs.
        try? await Task.sleep(nanoseconds: 400_000_000)
        await harness.settle()
        #expect(ran.all == ["set_volume"])
        await harness.session.close()
    }

    @Test func withNoGoodCheckYetAToolCallWaitsForTheReadBack() async {
        let agent = ScriptedAgent()
        agent.pushResult = Self.unreachable  // the launch update fails: nothing confirmed yet
        agent.verifyDelay = 0.3  // the wake's read-back is on its way, and will say in step
        let ran = Recorder<String>()
        let tool = ToolSpec(name: "set_volume", description: "d", parameters: ["type": "object"], tier: .quick) { _ in
            ran.add("set_volume"); return ToolResult.ok()
        }
        let harness = harness(agent) { $0.wakeCheckPatience = 2 }
        harness.session.prepare(tools: [tool], memorySummary: "")
        let opening = Task { await harness.session.open() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(harness.session.isConnected)
        harness.driver.emit(.toolCall(name: "set_volume", callID: "c1", parameters: Data(#"{"percent":30}"#.utf8)))
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(ran.all.isEmpty, "held until the first check answers")
        await opening.value
        try? await Task.sleep(nanoseconds: 300_000_000)
        await harness.settle()
        #expect(ran.all == ["set_volume"], "the read-back said in step, so it runs")
        await harness.session.close()
    }

    @Test func aConfirmedMismatchThatTheRepairCannotFixIsRefusedInPlainWords() async {
        let agent = ScriptedAgent()
        agent.pushResult = Self.wrong
        agent.verifyResult = Self.wrong
        let harness = harness(agent)
        harness.session.prepare(tools: tools, memorySummary: "")
        await harness.session.open()
        await harness.settle()
        #expect(harness.drivers.isEmpty)
        #expect(harness.session.openRefusal == "Handsfree's voice isn't set up correctly yet. It is trying again.")
        #expect(!(harness.session.openRefusal ?? "").contains("tool") && !(harness.session.openRefusal ?? "").contains("agent"))
    }

    @Test func aConfirmedMismatchThatTheRepairFixesOpens() async {
        let agent = ScriptedAgent()
        agent.pushResult = Self.wrong  // the launch update is refused
        let harness = harness(agent)
        harness.session.prepare(tools: tools, memorySummary: "")
        try? await Task.sleep(nanoseconds: 50_000_000)
        agent.pushResult = { AgentCheck.matching($0) }  // the repair at the wake works
        await harness.session.open(firstUtterance: "hi")
        await harness.settle()
        #expect(harness.session.isConnected && harness.driver.userMessages == ["hi"])
    }

    @Test func aSlowUpdateThatFailsLateDoesNotOverwriteANewerGoodCheck() async {
        let agent = ScriptedAgent()
        agent.pushDelay = 0.5
        agent.pushResult = Self.wrong  // the launch update, slow, will come back refused
        let harness = harness(agent) { $0.firstSyncPatience = 0.05 }
        harness.session.prepare(tools: tools, memorySummary: "")
        await harness.session.open(firstUtterance: "hi")  // the wake's read-back: in step
        await harness.settle()
        #expect(harness.session.confirmedCheck?.inSync == true)
        try? await Task.sleep(nanoseconds: 700_000_000)
        await harness.settle()
        #expect(harness.session.confirmedCheck?.inSync == true, "the older, failed update is ignored")
        #expect(harness.session.isConnected && !harness.driver.ended)
        await harness.session.close()
    }
}

/// The syncer's reading of ElevenLabs' answers.
@Suite struct AgentSyncerErrorTests {
    private let tools = [ToolSpec(name: "set_volume", description: "d", parameters: ["type": "object"], tier: .quick) { _ in ToolResult.ok() }]

    private func syncer(_ respond: @escaping @Sendable (URLRequest) -> (Int, String)) -> AgentSyncer {
        AgentSyncer(apiKey: "k", agentID: "agent_test", role: .test(productionAgentID: "agent_prod"), http: FakeHTTP(respond))
    }

    @Test func serverErrorsAndRateLimitsAreCouldNotCheck() async {
        for status in [500, 502, 503, 429] {
            let check = await syncer { _ in (status, "busy") }.verify(tools: tools)
            #expect(check.couldNotCheck && !check.inSync, "\(status)")
            #expect(check.problem == "I can't reach the voice service right now. Say Hey Handsfree to try again.")
        }
        let update = await syncer { _ in (503, "down") }.push(tools: tools)
        #expect(update.couldNotCheck, "an update that could not be sent is not a mismatch")
    }

    @Test func aBodyThatWillNotDecodeIsCouldNotCheck() async {
        #expect(await syncer { _ in (200, "<html>") }.verify(tools: tools).couldNotCheck)
    }

    @Test func aRefusedUpdateIsAConfirmedProblem() async {
        let check = await syncer { request in request.httpMethod == "PATCH" ? (400, "bad tool") : (200, "{}") }.push(tools: tools)
        #expect(check.isConfirmedMismatch)
        #expect(check.problem == "Handsfree's voice isn't set up correctly yet. It is trying again.")
    }

    @Test func aReadThatTakesTooLongGivesUp() async {
        let started = Date()
        do {
            _ = try await AgentSyncer.withDeadline(0.1) { try await Task.sleep(nanoseconds: 2_000_000_000); return 1 }
            Issue.record("should have timed out")
        } catch {
            #expect(AgentSyncer.isTransient(error))
        }
        #expect(Date().timeIntervalSince(started) < 1)
    }
}
