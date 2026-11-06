import Foundation
import HFCore

/// How a TaskEvent is put to the voice agent.
///
/// Everything spoken is sent as a user message that starts with `[APP]`. The
/// prompt says such messages come from the Mac, never from the user, and are
/// never a yes. Each line also says what to do with it, because the agent
/// follows an instruction it can see more reliably than one it must remember.
public enum TaskEventSpeech {
    public static let marker = "[APP]"

    /// The line that asks the agent to say `event` aloud.
    public static func spokenLine(for event: TaskEvent) -> String {
        let task = "Task \(event.taskID)"
        switch event.kind {
        case .progress:
            return "\(marker) \(task) progress: \(event.text) Say this in a few words, or nothing if it adds nothing."
        case .question:
            let options = event.options.isEmpty ? "" : " Options: \(event.options.joined(separator: ", "))."
            return "\(marker) \(task) asks: \(event.text)\(options) Ask the user exactly this, then pass their reply to answer_task."
        case .confirmation:
            return "\(marker) \(task) needs a clear yes before it goes ahead: \(event.text) Say this to the user exactly, then pass their reply to answer_task word for word."
        case .result:
            switch event.status {
            case .done: return "\(marker) \(task) finished: \(event.text) Tell the user in one sentence."
            case .cancelled: return "\(marker) \(task) stopped: \(event.text) Tell the user in a word or two."
            default: return "\(marker) \(task) failed: \(event.text) Tell the user in one sentence."
            }
        }
    }

    /// Put before a push sent a second time, because the agent did not say it the first time.
    public static let sayItNow = "\(marker) The user has not heard the message below: your last reply did not say it. Say it aloud to the user now, in full. Do not skip this turn."

    /// The silent note for the agent's context, so "how's it going?" can be answered.
    public static func contextLine(for event: TaskEvent) -> String {
        "Task \(event.taskID) \(event.kind.rawValue) (\(event.status.rawValue)): \(event.text)"
    }
}

/// The order and timing rules for spoken task events. Pure, so it is easy to test.
///
/// Rules:
/// - Questions, confirmations and results are never dropped and never reordered.
/// - A progress line is the least important thing in the queue. A newer progress
///   line replaces an older one, anything more important removes it, and one
///   that waited too long is dropped rather than spoken late.
/// - Nothing is spoken while the agent is talking or the user is speaking,
///   because a pushed message cuts the agent off mid-sentence (seen in the spike).
///   After `maximumWait`, an important item is spoken anyway: a lost question is
///   worse than an interrupted sentence.
/// - Everything ready goes out together as one message, in order. If sending
///   fails, it goes back to the front of the queue and is sent as soon as possible.
public struct PushQueue: Sendable {
    public struct Timing: Sendable {
        /// The longest an important item waits for a quiet moment.
        public var maximumWait: TimeInterval = 10
        /// A progress line older than this is no longer worth saying.
        public var progressShelfLife: TimeInterval = 6
        /// A question, confirmation or result is never said more than this long after it happened.
        public var newsShelfLife: TimeInterval = 1800
        public init() {}
    }

    struct Item: Sendable {
        let event: TaskEvent
        let queuedAt: TimeInterval
        /// When the event first arrived. Kept when it is queued again (re-sent, put back after a failed send).
        var happenedAt: TimeInterval
        var isProgress: Bool { event.kind == .progress }
    }

    /// When each recent event first arrived, so a re-queued one keeps its age.
    private var firstSeen: [(event: TaskEvent, at: TimeInterval)] = []

    private mutating func happenedAt(_ event: TaskEvent, now: TimeInterval) -> TimeInterval {
        firstSeen.removeAll { now - $0.at > timing.newsShelfLife }
        if let seen = firstSeen.first(where: { $0.event == event }) { return seen.at }
        firstSeen.append((event, now))
        if firstSeen.count > 50 { firstSeen.removeFirst(firstSeen.count - 50) }
        return now
    }

    public var timing: Timing
    private(set) var items: [Item] = []

    public init(timing: Timing = Timing()) { self.timing = timing }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }
    /// How many waiting items are still young enough to be said.
    public func freshCount(at now: TimeInterval) -> Int { items.filter { now - $0.happenedAt <= timing.newsShelfLife }.count }

    /// - Parameter fresh: true when the task has just sent this event (a new occurrence, even if an
    ///   identical one came before); false when it is queued again and keeps its age.
    public mutating func add(_ event: TaskEvent, at now: TimeInterval, fresh: Bool = false) {
        if fresh { firstSeen.removeAll { $0.event == event } }
        if event.kind == .progress {
            // Only the latest progress matters, and only if nothing important is waiting.
            if items.contains(where: { !$0.isProgress }) { return }
            items.removeAll { $0.isProgress }
        } else {
            items.removeAll { $0.isProgress }
        }
        items.append(Item(event: event, queuedAt: now, happenedAt: happenedAt(event, now: now)))
    }

    /// The events to speak now, oldest first, or none to keep waiting. Removes what it returns.
    ///
    /// - Parameters:
    ///   - quiet: true when the agent is not speaking or thinking and the user is silent.
    ///   - connected: false while reconnecting; nothing is taken, nothing is lost.
    public mutating func takeReady(at now: TimeInterval, quiet: Bool, connected: Bool) -> [TaskEvent] {
        items.removeAll { $0.isProgress && now - $0.queuedAt > timing.progressShelfLife }
        // Nothing is said more than half an hour after it happened.
        items.removeAll { now - $0.happenedAt > timing.newsShelfLife }
        guard connected, let oldest = items.first else { return [] }
        let waitedTooLong = !oldest.isProgress && now - oldest.queuedAt >= timing.maximumWait
        guard quiet || waitedTooLong else { return [] }
        let ready = items.map(\.event)
        items.removeAll()
        return ready
    }

    /// Returns events whose sending failed to the front of the queue, in their order.
    public mutating func putBack(_ events: [TaskEvent], at now: TimeInterval) {
        let returned = events.filter { $0.kind != .progress }.map {
            Item(event: $0, queuedAt: now - timing.maximumWait, happenedAt: happenedAt($0, now: now))
        }
        items.removeAll { $0.isProgress && !returned.isEmpty }
        items.insert(contentsOf: returned, at: 0)
    }

    /// One message saying every event, in order.
    public static func message(for events: [TaskEvent]) -> String {
        events.map(TaskEventSpeech.spokenLine(for:)).joined(separator: "\n")
    }

    /// Short summaries of what is still waiting, for the context after a reconnect.
    public var pendingSummaries: [String] { items.map { TaskEventSpeech.contextLine(for: $0.event) } }
}
