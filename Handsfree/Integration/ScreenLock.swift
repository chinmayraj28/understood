//
//  ScreenLock.swift
//  Handsfree
//
//  One rule for a locked Mac. While the lock screen is up nothing can be seen,
//  clicked or typed, and only a person can unlock it (nobody here ever enters
//  the user's password). On 6 Nov a locked screen produced "Spotlight didn't
//  open" from a quick tool and "I can't find the main display" from a task:
//  both true, both useless to someone who cannot see why. Now every quick tool,
//  every task start and every step of a running task first checks the lock,
//  read only, and while it is locked does nothing and says the same sentence.
//  App-side, by wrapping the tools and the task executor. New for Handsfree.
//

import CoreGraphics
import Foundation
import HFCore

enum ScreenLock {
    /// The one sentence, everywhere.
    static let sentence = "The Mac is locked, so I can't use it until someone unlocks it."

    /// For the agent, beside the sentence: there is nothing it can do about it.
    static let agentNote = "Say this once. Do not offer to unlock the Mac, do not ask for a password, and do not try another way: only a person at the Mac can unlock it."

    /// True while the Mac shows its lock screen. Read only, from the window server's session.
    static func isLockedNow() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    static var lockedResult: JSONObject {
        ToolResult.failure(sentence, ["locked": true, "note": .string(agentNote)])
    }

    /// Every quick tool (they act with the hands, or read a screen that cannot be seen) and
    /// `start_task`: while locked, nothing runs and the sentence comes back.
    static func guarding(_ tools: [ToolSpec], isLocked: @escaping @Sendable () -> Bool) -> [ToolSpec] {
        tools.map { tool in
            guard tool.tier == .quick || tool.name == "start_task" else { return tool }
            return ToolSpec(name: tool.name, description: tool.description, parameters: tool.parameters,
                            tier: tool.tier, timeoutSeconds: tool.timeoutSeconds) { parameters in
                if isLocked() { return lockedResult }
                return await tool.handler(parameters)
            }
        }
    }
}

/// The screen agent, with the lock rule: a task never starts on a locked screen, and a running
/// task stops at its next step if the screen locks, failing with the same sentence instead of
/// timing out or reporting a missing display.
struct LockAwareExecutor: TaskExecuting {
    let inner: any TaskExecuting
    let isLocked: @Sendable () -> Bool

    func run(goal: String, context: TaskContext) async throws -> String {
        if isLocked() { throw SpeakableError(ScreenLock.sentence) }
        do {
            return try await inner.run(goal: goal, context: LockAwareContext(inner: context, isLocked: isLocked))
        } catch {
            // Whatever went wrong (a screenshot of the lock screen, a refused key), the reason is the lock.
            if !(error is CancellationError), isLocked() { throw SpeakableError(ScreenLock.sentence) }
            throw error
        }
    }
}

/// The task's context, unchanged except that each step first checks the lock.
final class LockAwareContext: TaskContext, @unchecked Sendable {
    private let inner: TaskContext
    private let isLocked: @Sendable () -> Bool

    init(inner: TaskContext, isLocked: @escaping @Sendable () -> Bool) {
        self.inner = inner
        self.isLocked = isLocked
    }

    var taskID: String { inner.taskID }
    var goal: String { inner.goal }
    var memoryHints: String { inner.memoryHints }
    var lastAnswer: String { inner.lastAnswer }
    func askUser(_ question: String, options: [String]) async throws -> String { try await inner.askUser(question, options: options) }
    func confirm(_ action: ScreenAction, spokenQuestion: String?) async throws -> Bool { try await inner.confirm(action, spokenQuestion: spokenQuestion) }
    func report(_ progress: String) { inner.report(progress) }

    func step() throws {
        if isLocked() { throw SpeakableError(ScreenLock.sentence) }
        try inner.step()
    }
}
