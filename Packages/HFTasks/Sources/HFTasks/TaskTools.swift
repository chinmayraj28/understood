import Foundation
import HFCore

/// The four Tier 3 voice tools. Each handler only talks to the runner, which
/// answers at once, so these tools never keep the conversation waiting.
public enum TaskTools {

    public static let startDescription = """
        Start a background task on the user's Mac for anything the quick tools cannot do: multi-step work on \
        the screen, such as creating a calendar event with a Meet link and inviting someone, writing and \
        sending a message in an app, or finding and filling in a form. The user will see the pointer move and \
        the keys land while it works. Do not use it for things a quick tool can do (volume, media keys, \
        scrolling, opening an app). The goal must be one complete, self-contained instruction that includes \
        every detail the user gave: who, what, when, which app or site, and the exact words of any message. \
        The task cannot see this conversation, so never write 'as discussed' or 'what I said'. The tool \
        returns at once with a task_id and status 'running': that only means the task has started. Never tell \
        the user a task is finished, sent or done until a result for it arrives. While it runs you will be told \
        its progress, and it may ask a question or ask for confirmation; say each one to the user and pass \
        their reply to answer_task. Only one task runs at a time: if the status is 'busy', tell the user what \
        is still running and ask whether to cancel it.
        """

    public static let answerDescription = """
        Pass the user's reply to the question or confirmation the running task just asked, such as 'Priya \
        Shah or Priya Patel?' or 'Send the invite to Priya Shah?'. Use it only when a task is waiting for an \
        answer. For a question you may expand a short reply to the option it clearly means ('Shah' becomes \
        'Priya Shah'). For a confirmation, pass the user's own words exactly as they said them: never answer \
        yes on the user's behalf, and never turn a hesitant or changed reply ('wait, change the time') into a \
        yes. After answering, the task carries on; it is not finished until a result arrives.
        """

    public static let cancelDescription = """
        Stop the running background task at once. Use it when the user says stop, cancel, never mind or wait \
        while a task is running, or agrees to cancel a task to start a new one. It returns a short summary of \
        what had been done; tell the user it has stopped and what was done. Do not use it to stop music or \
        close an app.
        """

    public static let statusDescription = """
        Check the current or most recent background task: whether it is running, waiting for an answer (with \
        the question), or finished (with its summary). Use it when the user asks how a task is going, or when \
        you are not sure whether a task is waiting for an answer. Do not call it over and over while a task \
        runs; progress is reported to you as it happens.
        """

    static let taskIDSchema: JSONValue = ["type": "string", "description": "The task_id, if known. Optional."]

    /// start_task, answer_task, cancel_task and task_status, bound to a live runner.
    public static func make(runner: any TaskRunning) -> [ToolSpec] {
        [
            ToolSpec(
                name: "start_task",
                description: startDescription,
                parameters: [
                    "type": "object",
                    "properties": [
                        "goal": [
                            "type": "string",
                            "description": "A complete, self-contained instruction with every detail the user gave.",
                        ]
                    ],
                    "required": ["goal"],
                ],
                tier: .task,
                handler: { parameters in
                    guard let goal = nonBlankString(parameters["goal"]) else {
                        return ToolResult.failure("I need a goal to start a task.")
                    }
                    return runner.start(goal: goal)
                }),
            ToolSpec(
                name: "answer_task",
                description: answerDescription,
                parameters: [
                    "type": "object",
                    "properties": [
                        "answer": ["type": "string", "description": "The user's reply."],
                        "task_id": taskIDSchema,
                    ],
                    "required": ["answer"],
                ],
                tier: .task,
                handler: { parameters in
                    guard let answer = nonBlankString(parameters["answer"]) else {
                        return ToolResult.failure("I need the user's answer to pass on.")
                    }
                    return runner.answer(answer, taskID: nonBlankString(parameters["task_id"]))
                }),
            ToolSpec(
                name: "cancel_task",
                description: cancelDescription,
                parameters: ["type": "object", "properties": ["task_id": taskIDSchema]],
                tier: .task,
                handler: { parameters in runner.cancel(taskID: nonBlankString(parameters["task_id"])) }),
            ToolSpec(
                name: "task_status",
                description: statusDescription,
                parameters: ["type": "object", "properties": [:]],
                tier: .task,
                handler: { _ in runner.status() }),
        ]
    }

    /// A string parameter that is present and not just spaces, or nil.
    static func nonBlankString(_ value: JSONValue?) -> String? {
        guard let text = value?.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
    }
}
