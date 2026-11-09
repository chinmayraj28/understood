import Foundation
import HFCore
import os

/// The whole understanding layer for one turn: hear it several ways at once, look it up in the
/// phrasebook, repair it with context when the evidence is not enough, decide in code, and
/// learn from how the turn ended. See docs/SPEECH_PLAN.md.
public final class Understander: Understanding, @unchecked Sendable {
    private let hearers: [any Hearing]
    private let repairer: Repairer?
    private let phrasebook: Phrasebook
    private let configuration: UnderstanderConfiguration
    private let logger = Logger(subsystem: "com.handsfree", category: "understand")
    private let lock = NSLock()
    private var failedTries = 0
    /// The last question this layer asked, so an answer to it can be recognised.
    private var lastQuestion: String?

    /// - Parameters:
    ///   - hearers: the recognisers, run in parallel. Results keep this order.
    ///   - repairModel: the language model for the repair stage. Nil turns repair off.
    ///   - phrasebook: this person's phrasebook.
    public init(
        hearers: [any Hearing], repairModel: StructuredLanguageModel?, phrasebook: Phrasebook,
        configuration: UnderstanderConfiguration = .init()
    ) {
        self.hearers = hearers
        self.repairer = repairModel.map(Repairer.init(model:))
        self.phrasebook = phrasebook
        self.configuration = configuration
    }

    /// Turns in a row that ended without being understood. Reset when a turn is acted on or confirmed.
    public var consecutiveFailedTries: Int {
        lock.withLock { failedTries }
    }

    public func understand(_ turn: RecordedTurn, context: UnderstandingContext) async -> UnderstandingResult {
        let start = Date()
        let hints = hints(for: context)
        let hypotheses = await hearAll(turn, hints: hints)
        let transcripts = hypotheses.map(\.text).filter { !$0.isEmpty }
        // Same-recogniser matches are what the decider may act on; the best one overall is
        // reported, and shown to the repair stage as a hint.
        let byHearer = configuration.usePhrasebook ? phrasebook.matchesByHearer(for: hypotheses) : [:]
        let match = configuration.usePhrasebook ? phrasebook.bestMatch(for: transcripts) : nil
        var input = DecisionInput(
            hypotheses: hypotheses, phrasebookMatch: match, phrasebookMatchesByHearer: byHearer, context: context,
            failedTries: consecutiveFailedTries, hintedTerms: hints.keyterms, liveTranscript: turn.liveTranscript)

        // Fast path: when the evidence alone already lets the decider act (agreement, a strong
        // phrasebook match, an expected answer, or "stop"), the repair call is skipped.
        var decision = Decider.decide(input)
        if case .act = decision {
        } else if !transcripts.isEmpty, configuration.useRepair, let repairer {
            if configuration.postsActivity { ActivityBus.shared.post(.thinking(caption: "Working out what you said")) }
            do {
                input.reading = try await withDeadline(seconds: configuration.repairTimeoutSeconds) {
                    try await repairer.repair(hypotheses: hypotheses, phrasebookMatches: match.map { [$0] } ?? [], context: context)
                }
            } catch {
                // Claude down or slow: decide without a reading (agreement, phrasebook, else ask).
                logger.error("Repair failed: \(String(describing: error), privacy: .public)")
            }
            decision = Decider.decide(input)
        }

        countTry(decision, context: context)
        return UnderstandingResult(
            hypotheses: hypotheses, phrasebookMatch: match, reading: input.reading, decision: decision,
            seconds: Date().timeIntervalSince(start))
    }

    /// Learns only from a spoken yes, a chosen option, or a correction. An action that just went
    /// ahead is never passed in as `.confirmed` (see `TurnOutcome`), because learning from an
    /// uncorrected mistake would make it a habit. The failed-tries count is not changed here.
    public func learn(from turn: RecordedTurn, result: UnderstandingResult, outcome: TurnOutcome) async {
        let meant: String, source: PhrasebookSource
        switch outcome {
        case .confirmed(let text): (meant, source) = (text, .confirmation)
        case .corrected(let text): (meant, source) = (text, .correction)
        case .rejected: return  // nothing learned; the "no" was already counted by `countTry`
        }
        guard !SpeechText.words(meant).isEmpty else { return }

        // One pair for each recogniser that got it wrong, so the same garble is caught next time.
        // The clip is stored once per turn, on the first pair, and becomes a recogniser example.
        let meantKey = SpeechText.normalise(meant)
        let heard = result.hypotheses.filter { !SpeechText.words($0.text).isEmpty }
        let wrong = heard.filter { SpeechText.normalise($0.text) != meantKey }
        let clip: Data? = turn.wav.isEmpty ? nil : turn.wav
        do {
            if wrong.isEmpty {
                // Every recogniser was right: keep the clip and the phrase as a confirmed example.
                let hearer = heard.first(where: { $0.hearer == .scribe })?.hearer ?? heard.first?.hearer ?? .scribe
                try phrasebook.add(heard: meant, meant: meant, hearer: hearer, wav: clip, source: source)
            } else {
                for (index, hypothesis) in wrong.enumerated() {
                    try phrasebook.add(heard: hypothesis.text, meant: meant, hearer: hypothesis.hearer,
                                       wav: index == 0 ? clip : nil, source: source)
                }
            }
        } catch {
            logger.error("Phrasebook write failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Runs each recogniser once on half a second of silence, in the background, so the first
    /// real turn does not pay for loading models (Apple's on-device model once took minutes on
    /// its first use on this Mac). What they hear is ignored, nothing is learned, and the
    /// failed-tries count is untouched. The app calls this at startup; it never delays a turn.
    @discardableResult
    public func warmUp() -> Task<Void, Never> {
        let silence = RecordedTurn(
            wav: WAV.encode(samples: Array(repeating: 0, count: 8_000), sampleRate: 16_000),
            durationSeconds: 0.5, source: "warm-up")
        let hearers = self.hearers, languageCode = configuration.languageCode
        return Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for hearer in hearers {
                    group.addTask { _ = try? await hearer.hear(silence, hints: HearingHints(languageCode: languageCode)) }
                }
            }
        }
    }

    /// The one place failed tries are counted. A turn that ends in a question counts as a
    /// failure. A turn that acts resets the count, unless it is a "no" to a question this layer
    /// asked ("Message Mum?" answered "no"), which counts as one more failure.
    private func countTry(_ decision: UnderstandingDecision, context: UnderstandingContext) {
        lock.withLock {
            switch decision {
            case .act(let text):
                let answersOurQuestion = lastQuestion != nil && context.pendingQuestion == lastQuestion
                failedTries = answersOurQuestion && SpeechText.containsNegation(text) ? failedTries + 1 : 0
                lastQuestion = nil
            case .confirm(let question, _), .choose(let question, _), .askAgain(let question):
                failedTries += 1
                lastQuestion = question
            case .cannotHear:
                failedTries += 1
                lastQuestion = nil
            }
        }
    }

    // MARK: - Stages

    /// What the recognisers are told: likely words, most likely first, and a few of this
    /// person's clips.
    func hints(for context: UnderstandingContext) -> HearingHints {
        var keyterms: [String] = []
        if configuration.useKeyterms {
            let own = configuration.usePhrasebook ? phrasebook.keyterms(limit: configuration.keytermLimit) : []
            var seen: Set<String> = []
            for term in context.expectedAnswers + own + configuration.extraKeyterms + context.screenLabels {
                let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed.count <= 50, seen.insert(trimmed.lowercased()).inserted else { continue }
                keyterms.append(trimmed)
                if keyterms.count == configuration.keytermLimit { break }
            }
        }
        let examples = configuration.useExamples ? phrasebook.examples(limit: configuration.exampleCount) : []
        return HearingHints(keyterms: keyterms, examples: examples, languageCode: configuration.languageCode)
    }

    /// Every recogniser at once, each with its own time limit. A failed or slow recogniser
    /// becomes a hypothesis with `failure` set, and the others go on without it.
    func hearAll(_ turn: RecordedTurn, hints: HearingHints) async -> [Hypothesis] {
        let timeout = configuration.hearerTimeoutSeconds
        return await withTaskGroup(of: (Int, Hypothesis).self) { group in
            for (index, hearer) in hearers.enumerated() {
                group.addTask {
                    let start = Date()
                    do {
                        let text = try await withDeadline(seconds: timeout) { try await hearer.hear(turn, hints: hints) }
                        return (index, Hypothesis(hearer: hearer.name, text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                                  seconds: Date().timeIntervalSince(start)))
                    } catch {
                        let failure: String
                        switch error {
                        case let deadline as DeadlinePassed: failure = "timed out after \(deadline.seconds) s"
                        case let speakable as SpeakableError: failure = speakable.spokenMessage
                        default: failure = String(describing: error)
                        }
                        return (index, Hypothesis(hearer: hearer.name, text: "", seconds: Date().timeIntervalSince(start), failure: failure))
                    }
                }
            }
            var results: [(Int, Hypothesis)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}
