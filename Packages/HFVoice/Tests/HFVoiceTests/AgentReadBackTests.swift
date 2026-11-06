import Foundation
import HFCore
import Testing

@testable import HFVoice

/// The read-back check: an agent is in step only with the app's client tools, skip_turn,
/// and the model and reasoning setting the app sends.
@Suite struct AgentReadBackTests {
    private let tools = ["set_volume", "start_task"].map { name in
        ToolSpec(name: name, description: "d", parameters: ["type": "object"], tier: .quick) { _ in ToolResult.ok() }
    }

    /// An agent as ElevenLabs returns it, with skip_turn stored the way the server stores it.
    private func agentJSON(client: [String] = ["set_volume", "start_task"], skipTurn: Bool = true,
                           inlineSkipTurn: Bool = false,
                           llm: String = "claude-sonnet-5-5", reasoning: String? = "low") -> String {
        var inline = client.map { #"{"type":"client","name":"\#($0)"}"# }
        if inlineSkipTurn { inline.append(#"{"type":"system","name":"skip_turn","params":{"system_tool_type":"skip_turn"}}"#) }
        let builtIn = skipTurn && !inlineSkipTurn
            ? #"{"skip_turn":{"name":"skip_turn","params":{"system_tool_type":"skip_turn","wait_timeout_secs":-1}},"end_call":null}"#
            : #"{"end_call":null}"#
        let reasoningJSON = reasoning.map { "\"\($0)\"" } ?? "null"
        return #"{"conversation_config":{"agent":{"prompt":{"llm":"\#(llm)","reasoning_effort":\#(reasoningJSON),"tools":[\#(inline.joined(separator: ","))],"built_in_tools":\#(builtIn)}}}}"#
    }

    private func check(_ body: String) async -> AgentCheck {
        let http = FakeHTTP { _ in (200, body) }
        let syncer = AgentSyncer(apiKey: "k", agentID: "agent_test", role: .test(productionAgentID: "agent_prod"), http: http)
        return await syncer.verify(tools: tools)
    }

    @Test func toolsSkipTurnModelAndReasoningAllMatching() async {
        let result = await check(agentJSON())
        #expect(result.inSync)
        #expect(result.toolNamesOnAgent == ["set_volume", "start_task"], "skip_turn is not counted as a client tool")
        #expect(result.systemTools == ["skip_turn"], "a null built-in entry is not a tool")
        #expect(result.model == "claude-sonnet-5-5" && result.reasoningEffort == "low")
    }

    @Test func skipTurnListedInlineAlsoCounts() async {
        #expect(await check(agentJSON(skipTurn: false, inlineSkipTurn: true)).inSync)
    }

    @Test func withoutSkipTurnTheAgentIsOutOfStep() async {
        let result = await check(agentJSON(skipTurn: false))
        #expect(!result.inSync)
        #expect(result.missing == ["skip_turn"])
        #expect(result.detail?.contains("skip_turn") == true)
    }

    @Test func anotherModelOrReasoningSettingIsOutOfStep() async {
        let haiku = await check(agentJSON(llm: "claude-haiku-5-5"))
        #expect(!haiku.inSync && haiku.detail?.contains("model") == true)
        let noReasoning = await check(agentJSON(reasoning: "none"))
        #expect(!noReasoning.inSync && noReasoning.detail?.contains("reasoning") == true)
        let unset = await check(agentJSON(reasoning: nil))
        #expect(!unset.inSync)
    }

    @Test func aMissingClientToolIsStillCaught() async {
        let result = await check(agentJSON(client: ["set_volume"]))
        #expect(!result.inSync && result.missing == ["start_task"])
    }
}
