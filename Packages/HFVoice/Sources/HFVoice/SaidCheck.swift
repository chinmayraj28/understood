import Foundation
import HFCore

/// Whether the user really heard what the app asked the agent to say. Pure, so it is easy to test.
///
/// A task's question, confirmation or result is pushed to the agent as a message to say aloud.
/// The agent can still say nothing (skip_turn), say something empty, or say something else
/// ("On it."). None of those counts as said:
///
/// - The first time, the item is sent again once, worded so it must be said now.
/// - If the second attempt is not said either, the item is kept as **unsaid**: it counts as news
///   the user has not heard, so the conversation does not close on it, and it is recorded
///   (counts only, never the words). It is not sent a third time.
///
/// It also guards consent. An answer is passed to a waiting task only if that task's question
/// was heard in this conversation. "Yes" said before the question was heard is never a yes to it.
///
/// A reply counts as saying a question or confirmation when it carries at least half of the
/// question's meaningful words ("Send 'late' to Amma?" is said by "Shall I send 'late' to Amma?",
/// not by "On it."). A result is said by any reply with words in it.
struct SaidCheck {
    /// What a push turned out to be.
    enum Outcome: Equatable {
        /// Nothing was waiting to be said.
        case nothingPending
        /// Everything in the push was said.
        case said
        /// Not said: send these again, once, with the stronger wording.
        case sendAgain([TaskEvent])
        /// Not said twice: these are now unsaid, and are not sent again.
        case gaveUp([TaskEvent])
    }

    /// The push waiting for the agent's reply.
    struct Attempt: Equatable {
        var events: [TaskEvent]
        var number: Int
        var sentAt: TimeInterval
    }

    private(set) var attempt: Attempt?
    /// Items sent twice and still not said, with when they were given up on.
    private(set) var unsaid: [(event: TaskEvent, at: TimeInterval)] = []
    /// Items to be sent with the stronger wording when they next go out.
    private var secondTries: [TaskEvent] = []
    /// The latest question or confirmation for each task that has not finished.
    private(set) var openQuestions: [String: TaskEvent] = [:]
    /// Questions heard in this conversation, by task id and text, with the turn number they were
    /// first said in (the session numbers every sentence either side says, in order).
    private var heard: [String: Int] = [:]

    // Counts for the status file. Never the words.
    private(set) var sentAgainCount = 0
    private(set) var gaveUpCount = 0
    private(set) var answersHeldBack = 0

    static func mustBeSaid(_ event: TaskEvent) -> Bool { event.kind != .progress }

    // MARK: Events from the task

    /// Every event pushed by a task, as it arrives.
    mutating func noted(_ event: TaskEvent) {
        switch event.kind {
        case .question, .confirmation:
            openQuestions[event.taskID] = event
        case .result:
            openQuestions[event.taskID] = nil
            // A question the task no longer waits for need not be said any more.
            unsaid.removeAll { $0.event.taskID == event.taskID && $0.event.kind != .result }
        case .progress:
            break
        }
    }

    /// The answer was passed on: that question is no longer waiting.
    mutating func answered(taskID: String?) {
        if let taskID, openQuestions[taskID] != nil {
            openQuestions[taskID] = nil
        } else if openQuestions.count == 1 {
            openQuestions.removeAll()
        }
        unsaid.removeAll { $0.event.kind == .question || $0.event.kind == .confirmation }
    }

    // MARK: Sending and replies

    /// True if `events` includes an item being sent for the second time (use the stronger wording).
    func isSecondTry(_ events: [TaskEvent]) -> Bool { events.contains { secondTries.contains($0) } }

    /// A push went out. Only items that must be said are tracked.
    mutating func sent(_ events: [TaskEvent], at now: TimeInterval) {
        let tracked = events.filter(Self.mustBeSaid)
        guard !tracked.isEmpty else { return }
        let number = isSecondTry(tracked) ? 2 : 1
        secondTries.removeAll { tracked.contains($0) }
        unsaid.removeAll { item in tracked.contains(item.event) }
        attempt = Attempt(events: tracked, number: number, sentAt: now)
    }

    /// The push failed to send, or the connection dropped before the reply: nothing is waiting for a
    /// reply any more. Returns the events that were waiting, to be queued again.
    @discardableResult
    mutating func notSent() -> [TaskEvent] {
        defer { attempt = nil }
        return attempt?.events ?? []
    }

    /// The agent said `text`. Marks any open question it carries as heard, then judges the push.
    mutating func replied(_ text: String, at now: TimeInterval, turn: Int = 0) -> Outcome {
        for question in openQuestions.values where Self.carries(text, question.text) {
            if heard[Self.key(question)] == nil { heard[Self.key(question)] = turn }
        }
        guard let attempt else { return .nothingPending }
        let hasWords = text.contains { $0.isLetter || $0.isNumber }
        let missed = attempt.events.filter { event in
            switch event.kind {
            case .question, .confirmation: return heard[Self.key(event)] == nil
            default: return !hasWords
            }
        }
        return judge(missed, at: now)
    }

    /// The agent skipped its turn.
    mutating func silent(at now: TimeInterval) -> Outcome {
        guard let attempt else { return .nothingPending }
        return judge(attempt.events, at: now)
    }

    /// No reply came within `replyTimeout`, counted from the push or from the last thing either side
    /// said or did (`lastActivity`), whichever is later. The caller only asks while the agent is not
    /// speaking or working and the user is not talking, so a long reply or the user talking over it
    /// never counts as "no reply".
    mutating func checkTimeout(at now: TimeInterval, replyTimeout: TimeInterval, lastActivity: TimeInterval = -.infinity) -> Outcome {
        guard let attempt, now - max(attempt.sentAt, lastActivity) >= replyTimeout else { return .nothingPending }
        return judge(attempt.events, at: now)
    }

    private mutating func judge(_ missed: [TaskEvent], at now: TimeInterval) -> Outcome {
        guard let attempt else { return .nothingPending }
        self.attempt = nil
        guard !missed.isEmpty else { return .said }
        if attempt.number == 1 {
            secondTries.append(contentsOf: missed)
            sentAgainCount += 1
            return .sendAgain(missed)
        }
        unsaid.append(contentsOf: missed.map { ($0, now) })
        gaveUpCount += 1
        return .gaveUp(missed)
    }

    // MARK: Consent

    /// The question an answer for `taskID` would go to, if the user has not heard it in this
    /// conversation. Nil when the answer may be passed on (or no question is known here, in which
    /// case the task runner decides).
    mutating func unheardQuestion(forAnswerTo taskID: String?) -> TaskEvent? {
        guard let question = openQuestion(forAnswerTo: taskID), heard[Self.key(question)] == nil else { return nil }
        answersHeldBack += 1
        return question
    }

    /// The question or confirmation an answer for `taskID` goes to, if known here.
    func openQuestion(forAnswerTo taskID: String?) -> TaskEvent? {
        if let taskID, let open = openQuestions[taskID] { return open }
        return openQuestions.values.first
    }

    /// The turn in which `event` was first said in this conversation, if it was.
    func heardInTurn(_ event: TaskEvent) -> Int? { heard[Self.key(event)] }

    /// An answer to a confirmation was held back because the user had not answered it yet.
    mutating func noteAnswerHeldBack() { answersHeldBack += 1 }

    /// A new conversation: nothing has been heard in it yet. Returns what to queue again: a push
    /// still waiting for its reply, and anything left unsaid, since a new conversation is a new
    /// chance for the user to hear it (with the ordinary wording first).
    /// Anything older than `shelfLife` is dropped instead.
    mutating func newConversation(at now: TimeInterval, shelfLife: TimeInterval) -> [TaskEvent] {
        heard.removeAll()
        var again = attempt.map { now - $0.sentAt < shelfLife ? $0.events : [] } ?? []
        attempt = nil
        for item in unsaid where now - item.at < shelfLife && !again.contains(item.event) { again.append(item.event) }
        unsaid.removeAll()
        secondTries.removeAll()
        return again
    }

    /// Unsaid items still worth keeping the conversation open for: only a question or confirmation.
    /// An unsaid result or failure does not hold the conversation open (each open minute costs): it stays
    /// on the panel and the overlay, and is offered again at the start of the next conversation.
    func hasUnsaid(at now: TimeInterval, shelfLife: TimeInterval) -> Bool {
        unsaid.contains { ($0.event.kind == .question || $0.event.kind == .confirmation) && now - $0.at < shelfLife }
    }

    // MARK: Matching

    private static func key(_ event: TaskEvent) -> String { "\(event.taskID)\u{1}\(event.text)" }

    private static let ignoredWords: Set<String> = [
        "the", "and", "for", "you", "your", "with", "this", "that", "are", "was", "will", "shall", "can",
        "should", "would", "want", "now", "about", "from", "into", "have", "has", "just", "please",
    ]

    static func meaningfulWords(_ text: String) -> Set<String> {
        let words = text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
        return Set(words.filter { $0.count >= 3 && !ignoredWords.contains($0) })
    }

    /// True when `reply` carries at least half of the meaningful words of `question`.
    static func carries(_ reply: String, _ question: String) -> Bool {
        let wanted = meaningfulWords(question)
        let got = meaningfulWords(reply)
        if wanted.isEmpty { return !got.isEmpty }
        return Double(wanted.intersection(got).count) >= Double(wanted.count) * 0.5
    }
}
