import Foundation
import HFCore

/// The tool the agent calls when the user ends the conversation themselves
/// ("that's all, thanks", "go to sleep").
///
/// The app goes back to sleep on its own after a short silence, so this is only for
/// the user who wants it to stop listening now. It never ends a conversation while a
/// task is running or waiting for the user's answer: that check is in code here, not
/// only in the description, because a task left waiting with no conversation open
/// could never be answered. The tool waits for the app's real answer, so the agent
/// never says "Okay" when the app is in fact staying awake.
public enum SleepTool {
    public static let name = "go_to_sleep"

    /// What the app did with the request.
    public enum Answer: Sendable, Equatable {
        /// The conversation closes once the agent has finished its short reply.
        case goingToSleep
        /// A task is running or waiting for an answer: it goes to sleep as soon as the task ends.
        case afterTask
        /// A task is running or waiting for an answer, so it stays awake.
        case busy
        /// It cannot sleep now (it is not awake, or it is set to stay open).
        case notAvailable
    }

    /// - Parameters:
    ///   - isTaskActive: true while a task is running or waiting for the user's answer.
    ///   - requestSleep: asks the app to close the conversation once the agent has finished its
    ///     short reply, and returns what the app will do. Never called while a task is active.
    public static func make(
        isTaskActive: @escaping @Sendable () -> Bool,
        requestSleep: @escaping @Sendable () async -> Answer
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
            var answer = await requestSleep()
            // Never sleeps over a running task or a question waiting for the user's yes, whatever the app says.
            if answer == .goingToSleep, isTaskActive() { answer = .afterTask }
            switch answer {
            case .goingToSleep:
                return ToolResult.ok(["note": "Going to sleep once you finish. Say at most one short word, or nothing."])
            case .afterTask:
                return ToolResult.ok(["note": "A task is still going. It will stop listening as soon as the task ends; say so in a few words."])
            case .busy:
                return ToolResult.failure("A task is still going, so I'll keep listening.")
            case .notAvailable:
                return ToolResult.failure("I'll keep listening for now.")
            }
        }
    }
}
