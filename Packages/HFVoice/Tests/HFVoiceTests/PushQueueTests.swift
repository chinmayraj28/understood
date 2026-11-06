import HFCore
import Testing

@testable import HFVoice

private func event(_ kind: TaskEventKind, _ text: String, task: String = "t1", status: TaskStatus = .running, options: [String] = []) -> TaskEvent {
    TaskEvent(taskID: task, kind: kind, status: status, text: text, options: options)
}

@Suite struct PushQueueTests {
    @Test func waitsForAQuietMomentThenSpeaks() {
        var queue = PushQueue()
        queue.add(event(.question, "Shah or Patel?", status: .needsInput), at: 0)
        #expect(queue.takeReady(at: 1, quiet: false, connected: true).isEmpty)
        #expect(queue.takeReady(at: 2, quiet: true, connected: true).map(\.text) == ["Shah or Patel?"])
        #expect(queue.isEmpty)
    }

    @Test func nothingIsTakenWhileDisconnected() {
        var queue = PushQueue()
        queue.add(event(.result, "Sent.", status: .done), at: 0)
        #expect(queue.takeReady(at: 30, quiet: true, connected: false).isEmpty)
        #expect(queue.count == 1)
    }

    @Test func onlyTheLatestProgressIsKept() {
        var queue = PushQueue()
        queue.add(event(.progress, "Opening WhatsApp"), at: 0)
        queue.add(event(.progress, "Typing the message"), at: 1)
        #expect(queue.takeReady(at: 2, quiet: true, connected: true).map(\.text) == ["Typing the message"])
    }

    @Test func aQuestionDropsWaitingProgressAndBlocksNewProgress() {
        var queue = PushQueue()
        queue.add(event(.progress, "Opening Calendar"), at: 0)
        queue.add(event(.question, "Shah or Patel?", status: .needsInput), at: 1)
        queue.add(event(.progress, "Still looking"), at: 2)
        #expect(queue.takeReady(at: 3, quiet: true, connected: true).map(\.text) == ["Shah or Patel?"])
    }

    @Test func aConfirmationIsNeverLostOrReorderedBehindItsResult() {
        var queue = PushQueue()
        queue.add(event(.confirmation, "Send it to Amma?", status: .needsInput), at: 0)
        queue.add(event(.result, "Stopped before sending.", status: .cancelled), at: 1)
        let ready = queue.takeReady(at: 2, quiet: true, connected: true)
        #expect(ready.map(\.kind) == [.confirmation, .result])
        let message = PushQueue.message(for: ready)
        #expect(message.range(of: "Send it to Amma?")!.lowerBound < message.range(of: "Stopped before sending.")!.lowerBound)
    }

    @Test func anImportantItemIsSpokenAfterTheMaximumWaitEvenIfNotQuiet() {
        var queue = PushQueue()
        queue.add(event(.confirmation, "Send it?", status: .needsInput), at: 0)
        #expect(queue.takeReady(at: 9.9, quiet: false, connected: true).isEmpty)
        #expect(queue.takeReady(at: 10, quiet: false, connected: true).count == 1)
    }

    @Test func oldProgressExpiresInsteadOfBeingSpokenLate() {
        var queue = PushQueue()
        queue.add(event(.progress, "Opening Chrome"), at: 0)
        #expect(queue.takeReady(at: 30, quiet: false, connected: true).isEmpty)
        #expect(queue.isEmpty)
    }

    @Test func aFailedSendGoesBackToTheFrontInOrder() {
        var queue = PushQueue()
        queue.add(event(.question, "Later question", task: "t2", status: .needsInput), at: 5)
        queue.putBack([event(.confirmation, "Send it?", status: .needsInput), event(.result, "Done.", status: .done)], at: 6)
        let ready = queue.takeReady(at: 6, quiet: true, connected: true)
        #expect(ready.map(\.text) == ["Send it?", "Done.", "Later question"])
    }

    @Test func spokenLinesAreMarkedAndSayWhatToDo() {
        let question = TaskEventSpeech.spokenLine(for: event(.question, "Shah or Patel?", status: .needsInput, options: ["Priya Shah", "Priya Patel"]))
        #expect(question.hasPrefix("[APP] Task t1 asks: Shah or Patel?"))
        #expect(question.contains("Options: Priya Shah, Priya Patel."))
        #expect(question.contains("answer_task"))
        let confirmation = TaskEventSpeech.spokenLine(for: event(.confirmation, "Send 'late' to Amma?", status: .needsInput))
        #expect(confirmation.contains("clear yes") && confirmation.contains("word for word"))
        #expect(TaskEventSpeech.spokenLine(for: event(.result, "Sent.", status: .done)).contains("finished: Sent."))
        #expect(TaskEventSpeech.spokenLine(for: event(.result, "Stopped.", status: .cancelled)).contains("stopped: Stopped."))
        #expect(TaskEventSpeech.spokenLine(for: event(.result, "No signal.", status: .failed)).contains("failed: No signal."))
    }
}
