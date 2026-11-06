//
//  ScriptAndLockTests.swift
//  HandsfreeTests
//
//  The test-only script runner's parsing and its rule for throwing a document away, and a held
//  action never being pressed on a locked Mac (6 Nov review).
//

import Foundation
import HFCore
import Testing

@Suite("Script steps")
struct ScriptStepsTests {
    @Test("Lines become steps; comments and blank lines are skipped; the verb is lower-cased")
    func parses() {
        let script = """
            # A comment line
            require-unlocked

            WAKE open TextEdit   # a comment after a step
            say Make a new document and type: hello from Handsfree
            wait-task 180
            expect-text TextEdit | hello from Handsfree
            close-without-saving TextEdit | hello from Handsfree
            """
        #expect(ScriptSteps.parse(script) == [
            ScriptStep(verb: "require-unlocked", argument: ""),
            ScriptStep(verb: "wake", argument: "open TextEdit"),
            ScriptStep(verb: "say", argument: "Make a new document and type: hello from Handsfree"),
            ScriptStep(verb: "wait-task", argument: "180"),
            ScriptStep(verb: "expect-text", argument: "TextEdit | hello from Handsfree"),
            ScriptStep(verb: "close-without-saving", argument: "TextEdit | hello from Handsfree"),
        ])
        #expect(ScriptSteps.parse("").isEmpty)
        #expect(ScriptSteps.parse("   \n# only a comment\n").isEmpty)
    }

    @Test("The shipped e2e scripts parse, and every step is one the runner knows")
    func shippedScripts() throws {
        let known: Set<String> = [
            "wake", "say", "expect-reply", "expect-tool", "expect-no-tool", "expect-reply-without", "expect-reply-with",
            "expect-no-task", "require-unlocked", "expect-front", "wait-task", "expect-text", "wait-asleep", "close-without-saving",
        ]
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/e2e")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "txt" }
        #expect(!files.isEmpty)
        for file in files {
            let steps = ScriptSteps.parse(try String(contentsOf: file, encoding: .utf8))
            #expect(!steps.isEmpty, "\(file.lastPathComponent)")
            for step in steps { #expect(known.contains(step.verb), "\(file.lastPathComponent): unknown step \(step.verb)") }
            for step in steps where step.verb == "close-without-saving" {
                #expect(ScriptSteps.appAndText(step.argument) != nil, "\(file.lastPathComponent): cleanup must name the exact text it typed")
            }
        }
    }

    @Test("App and text are split on the first bar")
    func appAndText() {
        #expect(ScriptSteps.appAndText("TextEdit | hello | there")?.app == "TextEdit")
        #expect(ScriptSteps.appAndText("TextEdit | hello | there")?.text == "hello | there")
        #expect(ScriptSteps.appAndText("TextEdit") == nil)
        #expect(ScriptSteps.appAndText("TextEdit | ") == nil)
    }

    @Test("A document is thrown away only when it is certainly the script's own")
    func discardRule() {
        // The script's own: TextEdit was not running before, and the document holds exactly what was typed.
        #expect(ScriptSteps.refusalToDiscard(appWasRunningBefore: false, documentText: "hello from Handsfree\n", typed: "hello from Handsfree") == nil)
        // TextEdit was already open: any document may be the user's.
        #expect(ScriptSteps.refusalToDiscard(appWasRunningBefore: true, documentText: "hello from Handsfree", typed: "hello from Handsfree") != nil)
        // The user's draft in front, or the script's text typed into it.
        #expect(ScriptSteps.refusalToDiscard(appWasRunningBefore: false, documentText: "Dear Sam, notes for Thursday", typed: "hello from Handsfree") != nil)
        #expect(ScriptSteps.refusalToDiscard(appWasRunningBefore: false, documentText: "Dear Sam hello from Handsfree", typed: "hello from Handsfree") != nil)
        // The document could not be read.
        #expect(ScriptSteps.refusalToDiscard(appWasRunningBefore: false, documentText: nil, typed: "hello from Handsfree") != nil)
    }
}

/// A task context whose confirmation waits for the user, during which the Mac may lock.
final class ConfirmingContext: TaskContext, @unchecked Sendable {
    let answer: Bool
    let duringWait: @Sendable () -> Void
    private(set) var confirmCalls = 0
    init(answer: Bool, duringWait: @escaping @Sendable () -> Void = {}) {
        self.answer = answer
        self.duringWait = duringWait
    }
    var taskID: String { "task" }
    var goal: String { "Message Amma" }
    var memoryHints: String { "" }
    var lastAnswer: String { "" }
    func askUser(_ question: String, options: [String]) async throws -> String { "" }
    func confirm(_ action: ScreenAction, spokenQuestion: String?) async throws -> Bool {
        confirmCalls += 1
        duringWait()
        return answer
    }
    func report(_ progress: String) {}
    func step() throws {}
}

@Suite("A held action on a locked Mac")
struct LockedConfirmationTests {
    let send = ScreenAction(kind: .click, target: nil, frontApp: "WhatsApp")

    @Test("A yes that comes back after the Mac has locked does not press")
    func lockedDuringTheWait() async {
        let lock = LockSwitch()
        let inner = ConfirmingContext(answer: true, duringWait: { lock.set(true) })
        let context = LockAwareContext(inner: inner, isLocked: { lock.isLocked })
        do {
            _ = try await context.confirm(send, spokenQuestion: "Send it to Amma?")
            Issue.record("a yes on a locked screen must not be returned as approved")
        } catch let error as SpeakableError {
            #expect(error.spokenMessage == ScreenLock.sentence)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("Already locked: the question is not even asked")
    func lockedBeforeAsking() async {
        let lock = LockSwitch()
        lock.set(true)
        let inner = ConfirmingContext(answer: true)
        let context = LockAwareContext(inner: inner, isLocked: { lock.isLocked })
        await #expect(throws: SpeakableError.self) { _ = try await context.confirm(send, spokenQuestion: nil) }
        #expect(inner.confirmCalls == 0)
    }

    @Test("Unlocked: the answer passes through unchanged, yes or no")
    func unlocked() async throws {
        let lock = LockSwitch()
        let yes = LockAwareContext(inner: ConfirmingContext(answer: true), isLocked: { lock.isLocked })
        let no = LockAwareContext(inner: ConfirmingContext(answer: false), isLocked: { lock.isLocked })
        #expect(try await yes.confirm(send, spokenQuestion: nil))
        #expect(try await !no.confirm(send, spokenQuestion: nil))
    }
}
