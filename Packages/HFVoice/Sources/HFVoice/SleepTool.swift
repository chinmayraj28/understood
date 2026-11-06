import Foundation
import HFCore

/// The tool the agent calls when the user ends the conversation themselves
/// ("that's all, thanks", "go to sleep").
///
/// The app goes back to sleep on its own after a short silence, so this is only for
/// the user who wants it to stop listening now. It never ends a conversation while a
/// task is running or waiting for the user's answer: that check is in code here, not
/// only in the description, because a task left waiting with no conversation open
/// could never be answered.
public enum SleepTool {
    public static let name = "go_to_sleep"

    /// - Parameters:
    ///   - isTaskActive: true while a task is running or waiting for the user's answer.
    ///   - onSleep: asks the app to close the conversation once the agent has finished its
    ///     short reply. Called at most once per call, and never while a task is active.
    public static func make(
        isTaskActive: @escaping @Sendable () -> Bool,
        onSleep: @escaping @Sendable () -> Void
    ) -> ToolSpec {
        ToolSpec(
            name: name,
            description: """
                Stop listening and go back to sleep until the user says the wake phrase again. \
                Use it only when the user clearly ends the conversation: "that's all, thanks", "that's it", \
                "go to sleep", "stop listening", "goodbye". \
                Never use it while a task is running or waiting for the user's answer, never because the user \
                is silent (the app sleeps on its own after a short silence), and never for "stop" or "cancel", \
                which stop a task. After it succeeds, say at most one short word such as "Okay.", or nothing.
                """,
            parameters: ["type": "object", "properties": [:]],
            tier: .meta,
            timeoutSeconds: 5
        ) { _ in
            if isTaskActive() {
                return ToolResult.failure("A task is still going, so I'll keep listening.")
            }
            onSleep()
            return ToolResult.ok(["note": "Going to sleep once you finish. Say at most one short word, or nothing."])
        }
    }
}
