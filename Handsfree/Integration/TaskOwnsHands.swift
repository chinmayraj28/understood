import Foundation
import HFCore

/// While a task is running or waiting for an answer, the task owns the pointer and the keyboard.
///
/// Quick tools that would use them are refused with one sentence telling the agent what to do
/// instead. Why: in the 6 Nov evaluation the backup model (Haiku 5.5) once "relayed" a task's
/// confirmation by calling type_text, which types into whatever has focus, for example the
/// WhatsApp message box of a task paused over Send. The prompt says not to; this makes it a rule.
///
/// Allowed during a task:
/// - Tools that only read: where_am_i, read_text, take_screenshot.
/// - set_volume, set_brightness and media_control. They press the keyboard's top-row hardware keys,
///   which macOS posts as system-defined events to the system itself, not to the focused app or
///   field, and they hold no modifier, so they cannot type into the task's field or change its
///   keystrokes. "Turn it down a bit" while a long task runs is a reasonable thing to ask.
/// - Every tool that is not a quick tool: memory, task_status, answer_task, cancel_task, go_to_sleep.
///
/// Any other quick tool, including one added later, is refused while a task is active.
enum TaskOwnsHands {
    static let sentence = "A task is in progress. Say the question aloud, or use answer_task or cancel_task."

    /// Quick tools that still work during a task (see above).
    static let allowedDuringTask: Set<String> = [
        "where_am_i", "read_text", "take_screenshot", "set_volume", "set_brightness", "media_control",
    ]

    static var refusedResult: JSONObject {
        ToolResult.failure(sentence, ["task_in_progress": true])
    }

    static func isRefusedDuringTask(_ tool: ToolSpec) -> Bool {
        tool.tier == .quick && !allowedDuringTask.contains(tool.name)
    }

    /// Wraps the quick tools that use the hands so they refuse while `isTaskActive()` is true.
    /// Checked at the moment of the call.
    static func guarding(_ tools: [ToolSpec], isTaskActive: @escaping @Sendable () -> Bool) -> [ToolSpec] {
        tools.map { tool in
            guard isRefusedDuringTask(tool) else { return tool }
            return ToolSpec(name: tool.name, description: tool.description, parameters: tool.parameters,
                            tier: tool.tier, timeoutSeconds: tool.timeoutSeconds) { parameters in
                if isTaskActive() { return refusedResult }
                return await tool.handler(parameters)
            }
        }
    }
}
