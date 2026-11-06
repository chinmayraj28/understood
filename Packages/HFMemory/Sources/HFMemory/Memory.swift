import Foundation
import HFCore
import os

/// Memory as the rest of the app sees it: hints for the screen agent, a summary for
/// the voice agent, and learning from answers and finished tasks.
///
/// Nothing here throws or waits for learning: `learn` and `taskEnded` hand the work to
/// one background queue and return at once, so memory can never slow down or break a task.
///
/// The shared protocol does not carry ids, so `Memory` keeps a small record per goal of
/// what `hints(forGoal:)` handed out (facts, recipes, unconfirmed suggestions). Answers
/// and the end of the task for the same goal are matched to it, and the record is dropped
/// when the task ends. One task runs at a time, so this stays tiny.
public final class Memory: MemoryProviding, @unchecked Sendable {
    /// The store behind this memory (the voice tools use it directly).
    public let store: MemoryStore
    private let learner: Learner
    private let worker = BackgroundWorker()
    private let logger = Logger(subsystem: "com.handsfree", category: "memory")

    /// What `hints(forGoal:)` handed out for one goal.
    struct Offer {
        let goal: String
        let hints: MemoryHints
        let at: Date
    }

    private let offersLock = NSLock()
    private var offers: [Offer] = []
    /// An offer older than this is forgotten even if its task never reported back.
    static let offerLifetimeSeconds = 3600.0

    /// - Parameters:
    ///   - store: the SQLite store.
    ///   - model: the language model used for learning; nil means only the rules learn
    ///     (name choices still are), and everything else works as normal.
    ///   - lastingPreFilter: an optional quick yes-or-no check (Jev) run before the model.
    public init(store: MemoryStore, model: StructuredLanguageModel? = nil,
                lastingPreFilter: LastingPreFilter? = nil) {
        self.store = store
        self.learner = Learner(store: store, model: model, lastingPreFilter: lastingPreFilter)
    }

    /// Opens `<settings.dataDirectory>/memory.db`, with the built-in recipes loaded.
    public static func openDefault(settings: Settings, model: StructuredLanguageModel?,
                                   lastingPreFilter: LastingPreFilter? = nil) throws -> Memory {
        Memory(store: try MemoryStore.openDefault(settings: settings), model: model,
               lastingPreFilter: lastingPreFilter)
    }

    // MARK: MemoryProviding

    /// One or two recipes, the names and preferences that matter for this goal, and any
    /// unconfirmed suggestion to check with a yes-or-no question.
    public func hints(forGoal goal: String) async -> String { hintDetails(forGoal: goal).text }

    /// The same as `hints(forGoal:)`, with the ids of what was handed out (for tests and the
    /// app's memory panel). Also records the offer for this goal.
    public func hintDetails(forGoal goal: String) -> MemoryHints {
        do {
            let hints = try store.memoryHints(forGoal: goal)
            record(Offer(goal: goal, hints: hints, at: Date()))
            return hints
        } catch {
            logger.error("building memory hints failed: \(String(describing: type(of: error)), privacy: .public)")
            return .empty
        }
    }

    public func summaryForPrompt(maxCharacters: Int) async -> String {
        (try? store.summaryForPrompt(maxCharacters: maxCharacters)) ?? ""
    }

    public func learn(fromQuestion question: String, options: [String], answer: String, goal: String) async {
        learnInBackground(question: question, options: options, answer: answer, goal: goal, isConfirmation: false)
    }

    /// The fuller form, for a caller that knows the question was a confirmation (which is
    /// then never learned from).
    public func learn(fromQuestion question: String, options: [String], answer: String, goal: String,
                      isConfirmation: Bool) async {
        learnInBackground(question: question, options: options, answer: answer, goal: goal,
                          isConfirmation: isConfirmation)
    }

    public func taskEnded(goal: String, status: TaskStatus, summary: String, steps: [String], seconds: Double) async {
        do {
            try store.logEpisode(goal: goal, executor: "screen", status: status.rawValue, summary: summary,
                                 steps: steps.count, seconds: seconds)
        } catch {
            logger.error("logging an episode failed: \(String(describing: type(of: error)), privacy: .public)")
        }
        let recipeIDs = takeOffer(for: goal)?.hints.recipeIDs ?? []  // the task is over: drop its record
        let learner = learner
        worker.enqueue {
            await learner.reflect(goal: goal, status: status, summary: summary, steps: steps, recipeIDs: recipeIDs)
        }
    }

    /// Waits until every learning job queued by a call that has already returned is done.
    /// For tests and for shutdown.
    public func waitForBackgroundWork() async { await worker.drain() }

    // MARK: Learning

    /// Queues the work before returning (synchronously), so a later `waitForBackgroundWork`
    /// always covers it.
    private func learnInBackground(question: String, options: [String], answer: String, goal: String,
                                   isConfirmation: Bool) {
        let suggestedIDs = offer(for: goal)?.hints.suggestedIDs ?? []
        let learner = learner
        let store = store
        worker.enqueue {
            if !isConfirmation,
               Self.answerSuggestion(question: question, answer: answer, suggestedIDs: suggestedIDs, store: store) {
                return
            }
            await learner.learn(question: question, answer: answer, goal: goal, options: options,
                                isConfirmation: isConfirmation)
        }
    }

    private static let yesAnswer = Pattern(
        #"^\s*(yes|yeah|yep|yup|sure|correct|right|exactly|ok(ay)?|that's (right|her|him|it|the one)|that is right)\b"#,
        caseInsensitive: true)
    private static let noAnswer = Pattern(#"^\s*(no|nope|nah|not)\b"#, caseInsensitive: true)
    private static let negation = Pattern(#"\b(no|not|nope|wrong|other)\b"#, caseInsensitive: true)

    /// If the question checked an unconfirmed suggestion ("Priya Shah, like last time?"),
    /// a clear yes promotes it and a clear no retires it. Returns true if it was handled.
    ///
    /// Never for a question about a risky step: a yes to "Send it to Priya Shah?" is a
    /// confirmation, and confirmations are never learned from.
    static func answerSuggestion(question: String, answer: String, suggestedIDs: [Int64],
                                 store: MemoryStore) -> Bool {
        guard !suggestedIDs.isEmpty,
              ExchangeRules.neverLearnReason(question: question, answer: "x") == nil
        else { return false }
        let lowered = question.lowercased()
        let candidates = suggestedIDs.compactMap { try? store.get($0) }
            .filter { $0.status == .candidate && lowered.contains($0.value.lowercased()) }
        guard let suggestion = candidates.first else { return false }
        do {
            if yesAnswer.matches(answer) && !negation.matches(answer) {
                try store.confirmCandidate(suggestion.id,
                                           evidence: "Asked: \(question) Answered: \(answer)")
                return true
            }
            if noAnswer.matches(answer) {
                try store.rejectCandidate(suggestion.id)
                return true
            }
        } catch {
            return false
        }
        return false  // not a clear yes or no: let the ordinary learning look at it
    }

    // MARK: Offers per goal

    private func record(_ offer: Offer) {
        offersLock.lock()
        defer { offersLock.unlock() }
        offers.removeAll { $0.goal == offer.goal || offer.at.timeIntervalSince($0.at) > Self.offerLifetimeSeconds }
        offers.append(offer)
    }

    /// The offer for this goal; if the goal text changed on the way, the latest recent one
    /// (one task runs at a time).
    private func offer(for goal: String) -> Offer? {
        offersLock.lock()
        defer { offersLock.unlock() }
        return matchingIndex(for: goal).map { offers[$0] }
    }

    private func takeOffer(for goal: String) -> Offer? {
        offersLock.lock()
        defer { offersLock.unlock() }
        return matchingIndex(for: goal).map { offers.remove(at: $0) }
    }

    private func matchingIndex(for goal: String) -> Int? {
        if let index = offers.lastIndex(where: { $0.goal == goal }) { return index }
        guard let last = offers.indices.last,
              Date().timeIntervalSince(offers[last].at) < Self.offerLifetimeSeconds else { return nil }
        return last
    }

    /// How many goals have a live record (for tests).
    var offerCount: Int {
        offersLock.lock()
        defer { offersLock.unlock() }
        return offers.count
    }
}

/// Runs jobs one after another, in the order they were queued, off the caller's path.
///
/// `enqueue` is synchronous: by the time it returns the job is in the chain, so a `drain`
/// started afterwards always waits for it.
final class BackgroundWorker: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    func enqueue(_ job: @escaping @Sendable () async -> Void) {
        lock.lock()
        defer { lock.unlock() }
        let previous = tail
        tail = Task(priority: .utility) {
            await previous?.value
            await job()
        }
    }

    /// Waits for everything queued so far, including jobs queued while waiting.
    func drain() async {
        while true {
            let current = lock.withLock { tail }
            guard let current else { return }
            await current.value
            let unchanged = lock.withLock { tail == current }
            if unchanged { return }
        }
    }
}
