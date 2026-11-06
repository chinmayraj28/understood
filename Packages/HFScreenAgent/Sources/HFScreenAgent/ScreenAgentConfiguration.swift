import Foundation
import HFCore

/// The settings one screen agent runs with. The defaults are the measured
/// recommendation in docs/SCREEN_AGENT.md.
public struct ScreenAgentConfiguration: Sendable {
    /// The Claude model that looks at the screen and picks actions.
    public var model: String
    /// `output_config.effort`: how much the model thinks per turn. Lower is faster.
    public var effort: String
    /// Long edge of every screenshot sent to the model, in pixels. 1280 gives
    /// 1280x800 on a 16:10 Mac: small enough to be quick and cheap, large enough
    /// to read normal text (the model can zoom for small text).
    public var screenshotLongEdge: Int
    /// The most output tokens one turn may use.
    public var maxTokensPerTurn: Int
    /// Screenshots kept in the conversation. Older ones are replaced by a short
    /// note in one batch, so the prompt cache is not broken on every turn.
    public var maxScreenshotsKept: Int
    /// Pause after an action before the screenshot that shows its result, so an
    /// animation (Spotlight opening, a menu dropping) has finished. A stale
    /// screenshot costs a whole extra model turn.
    public var settleSeconds: Double
    /// The longest a new action waits while the user is speaking. Bounded so a stuck
    /// signal, or a television in the room, cannot freeze a task.
    public var maxHoldSeconds: Double
    /// The system prompt (docs/prompts/screen_agent.md, bundled with the package).
    public var systemPrompt: String

    public init(
        model: String,
        effort: String = "low",
        screenshotLongEdge: Int = 1280,
        maxTokensPerTurn: Int = 4096,
        maxScreenshotsKept: Int = 30,
        settleSeconds: Double = 0.2,
        maxHoldSeconds: Double = 4,
        systemPrompt: String = ScreenAgentConfiguration.bundledSystemPrompt()
    ) {
        self.model = model
        self.effort = effort
        self.screenshotLongEdge = screenshotLongEdge
        self.maxTokensPerTurn = maxTokensPerTurn
        self.maxScreenshotsKept = maxScreenshotsKept
        self.settleSeconds = settleSeconds
        self.maxHoldSeconds = maxHoldSeconds
        self.systemPrompt = systemPrompt
    }

    /// Uses `Settings.taskModel`.
    public init(settings: Settings) { self.init(model: settings.taskModel) }

    /// The prompt in docs/prompts/screen_agent.md, copied into this package as a resource.
    public static func bundledSystemPrompt() -> String {
        guard let url = Bundle.module.url(forResource: "screen_agent", withExtension: "md"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "You operate a Mac for a person who cannot use their hands. Finish with task_finished." }
        return text
    }

    /// The `thinking` setting for each model family, from Anthropic's model notes:
    /// - Sonnet 5.5 rejects `disabled`; `between_tools` is its thinking-off mode.
    /// - Haiku 5.5 accepts `disabled` (at effort high or below).
    /// - Opus 5.5 and Fable cannot turn thinking off, so adaptive with low effort.
    var thinking: JSONValue {
        let name = model.lowercased()
        if name.contains("sonnet-5-5") { return ["type": "between_tools"] }
        if name.contains("haiku") { return ["type": "disabled"] }
        return ["type": "adaptive"]
    }

    /// Every tool the model gets: the computer toolset plus our three.
    var tools: [JSONValue] {
        var configs: JSONObject = [:]
        for member in ToolCallParser.disabledMembers { configs[member] = ["enabled": false] }
        return [
            ["type": "computer_toolset_20260801", "configs": .object(configs)],
            [
                "name": "ask_user",
                "description":
                    "Ask the person a short question out loud and wait for their spoken answer. Use it only when the goal is ambiguous in a way the screen cannot settle (two contacts with the same name, which account, which date). Give two to four short options when you can. Never use it to ask permission for an action.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "question": ["type": "string", "description": "One short question, e.g. \"Priya Shah or Priya Patel?\""],
                        "options": ["type": "array", "items": ["type": "string"], "description": "Two to four short answers."],
                    ],
                    "required": ["question"],
                ],
            ],
            [
                "name": "report_progress",
                "description":
                    "Tell the person in a few plain words what stage you are starting, e.g. \"Opening WhatsApp\". Call it in the same turn as that stage's actions.",
                "input_schema": [
                    "type": "object",
                    "properties": ["message": ["type": "string", "description": "Two to six words."]],
                    "required": ["message"],
                ],
            ],
            [
                "name": "prepare_send",
                "description":
                    "Call this in the same turn as, and just before, the action that sends a message (clicking Send or pressing Return in a message box). recipient is the name shown in the header of the chat that is open in the latest screenshot, exactly as written there; expected_name is the name you expect to see there for the person the goal means (after any notes, e.g. Mum is saved as \"Amma\"). If they differ, the send is refused: you are in the wrong chat.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "recipient": ["type": "string", "description": "The name in the open chat's header, e.g. \"Amma\"."],
                        "expected_name": ["type": "string", "description": "Who the goal means, as their chat should be named."],
                    ],
                    "required": ["recipient", "expected_name"],
                ],
            ],
            [
                "name": "task_finished",
                "description":
                    "End the task. success is true only if you saw on screen that the goal is done. summary is one short spoken sentence, under 25 words.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "success": ["type": "boolean"],
                        "summary": ["type": "string"],
                    ],
                    "required": ["success", "summary"],
                ],
            ],
        ]
    }
}
