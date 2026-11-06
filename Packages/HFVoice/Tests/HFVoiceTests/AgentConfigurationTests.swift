import Foundation
import HFCore
import Testing

@testable import HFVoice

private func spec(_ name: String, timeout: Int = 20) -> ToolSpec {
    ToolSpec(name: name, description: "Does \(name).",
             parameters: ["type": "object", "properties": ["percent": ["type": "integer", "description": "0 to 100"]], "required": ["percent"]],
             tier: .quick, timeoutSeconds: timeout) { _ in ToolResult.ok() }
}

@Suite struct AgentConfigurationTests {
    let definition = AgentConfiguration(prompt: "Prompt {{session_context}} {{user_memory}}").definition(tools: [spec("set_volume"), spec("slow", timeout: 300), spec("instant", timeout: 0)])

    @Test func turnSettingsAreForSlowSpeech() {
        let turn = definition["conversation_config"]?["turn"]
        #expect(turn?["turn_eagerness"]?.stringValue == "patient")
        #expect(turn?["turn_timeout"]?.doubleValue == -1)
        #expect(turn?["silence_end_call_timeout"]?.doubleValue == -1)
        #expect(definition["conversation_config"]?["conversation"]?["max_duration_seconds"]?.intValue == 7200)
    }

    @Test func modelVoiceAndPrompt() {
        let agent = definition["conversation_config"]?["agent"]
        #expect(agent?["prompt"]?["llm"]?.stringValue == "claude-sonnet-5-5")
        #expect(agent?["prompt"]?["reasoning_effort"]?.stringValue == "low")
        #expect(agent?["prompt"]?["backup_llm_config"]?["order"]?.arrayValue == ["claude-haiku-5-5", "claude-haiku-4-5"])
        #expect(agent?["prompt"]?["temperature"]?.doubleValue == 0)
        #expect(agent?["first_message"]?.stringValue == "")
        #expect(definition["conversation_config"]?["tts"]?["expressive_mode"]?.boolValue == false)
        let placeholders = agent?["dynamic_variables"]?["dynamic_variable_placeholders"]
        #expect(placeholders?["user_memory"]?.stringValue == "Nothing yet.")
        #expect(placeholders?["session_context"]?.stringValue != nil)
        #expect(definition["name"]?.stringValue == "Hands-Free Laptop Agent")
    }

    @Test func eachToolSpecBecomesAClientTool() {
        let tools = definition["conversation_config"]?["agent"]?["prompt"]?["tools"]?.arrayValue ?? []
        #expect(tools.count == 4, "three client tools and skip_turn")
        let volume = tools[0]
        #expect(volume["type"]?.stringValue == "client")
        #expect(volume["name"]?.stringValue == "set_volume")
        #expect(volume["description"]?.stringValue == "Does set_volume.")
        #expect(volume["expects_response"]?.boolValue == true)
        #expect(volume["pre_tool_speech"]?.stringValue == "off")
        #expect(volume["interruption_mode"]?.stringValue == "allow")
        #expect(volume["execution_mode"]?.stringValue == "immediate")
        #expect(volume["response_timeout_secs"]?.intValue == 20)
        #expect(volume["parameters"]?["required"]?.arrayValue == ["percent"])
        // The server accepts 1 to 120 seconds.
        #expect(tools[1]["response_timeout_secs"]?.intValue == 120)
        #expect(tools[2]["response_timeout_secs"]?.intValue == 1)
    }

    @Test func skipTurnIsInTheSameToolList() {
        let tools = definition["conversation_config"]?["agent"]?["prompt"]?["tools"]?.arrayValue ?? []
        let skip = tools.last
        #expect(skip?["type"]?.stringValue == "system")
        #expect(skip?["name"]?.stringValue == "skip_turn")
        #expect(skip?["params"]?["system_tool_type"]?.stringValue == "skip_turn")
        #expect(skip?["pre_tool_speech"]?.stringValue == "off")
        #expect(tools.filter { $0["name"]?.stringValue == "skip_turn" }.count == 1)
        #expect(definition["conversation_config"]?["agent"]?["prompt"]?["built_in_tools"] == nil, "a separate built_in_tools entry is dropped by the server")
    }

    @Test func leavingToolsOutKeepsTheAgentsTools() {
        let withoutTools = AgentConfiguration(prompt: "p").definition(tools: nil)
        #expect(withoutTools["conversation_config"]?["agent"]?["prompt"]?["tools"] == nil)
    }

    @Test func clientsMayOnlyOverrideTextModeAndGreeting() {
        let overrides = definition["platform_settings"]?["overrides"]?["conversation_config_override"]
        #expect(overrides?["conversation"]?["text_only"]?.boolValue == true)
        #expect(overrides?["agent"]?["first_message"]?.boolValue == true)
        #expect(overrides?["agent"]?["prompt"] == nil)
    }

    @Test func encodesAsJSON() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let text = String(decoding: try encoder.encode(definition), as: UTF8.self)
        #expect(text.contains(#""turn_timeout":-1"#))
        #expect(text.contains(#""max_duration_seconds":7200"#))
    }

    @Test func bundledPromptMatchesTheMasterCopyInDocs() throws {
        // The master is docs/prompts/voice_agent.md. If this fails, copy it again:
        // cp docs/prompts/voice_agent.md Packages/HFVoice/Sources/HFVoice/Resources/voice_agent.md
        let docs = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/prompts/voice_agent.md")
        let master = try String(contentsOf: docs, encoding: .utf8)
        let bundled = AgentConfiguration.bundledPrompt()
        #expect(!bundled.isEmpty)
        #expect(bundled == master)
        #expect(bundled.contains("{{user_memory}}") && bundled.contains("{{session_context}}"))
    }
}
