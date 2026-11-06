import Foundation
import HFCore
import os

/// The three fast decisions. Each asks Jev first and falls back to word rules
/// when Jev is disabled, fails, times out or is not confident enough, and says
/// which path decided in `Decision.source`:
///
/// - `.rule`: a fixed local rule decided without asking Jev.
/// - `.jev`: Jev answered and was confident enough.
/// - `.keywords`: the fallback word list decided.
///
/// None of them throws. `classifyRisk` never fails open. `classifyAnswer` never
/// returns yes unless it is sure.
public final class Classifiers: UtteranceClassifying, RiskClassifying, AnswerClassifying, Sendable {
    /// Nil means Jev is disabled: every decision uses the rules.
    public let client: JevClient?
    private let riskCache: VerdictCache
    private static let logger = Logger(subsystem: "com.handsfree", category: "HFDecisions")

    public init(client: JevClient?, riskCacheSeconds: Double = 600) {
        self.client = client
        self.riskCache = VerdictCache(lifetimeSeconds: riskCacheSeconds)
    }

    /// Classifiers backed by Jev when the settings have an OpenRouter key.
    public convenience init(settings: Settings) {
        self.init(client: JevClient(settings: settings))
    }

    // MARK: - Utterance

    public func classifyUtterance(_ text: String, context: UtteranceContext) async -> Decision<Intent> {
        let started = ContinuousClock.now
        let text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        if SpeechText.normalise(text).isEmpty {
            return Decision(label: .other, confidence: 1, source: .rule, reason: "empty or filler only").timed(from: started)
        }
        if let ruled = UtteranceRules.instantDecision(text, awaitingAnswer: context.awaitingAnswer) {
            return ruled.timed(from: started)
        }
        guard let client else {
            return UtteranceRules.fallback(text, context: context, why: "jev disabled").timed(from: started)
        }
        let state: JSONValue = [
            "said": .string(text),
            "assistant_is_working": .bool(context.taskRunning),
            // The question itself when the caller knows it; otherwise only that one is open.
            "assistant_question": .string(
                context.awaitingAnswer || context.question != nil
                    ? (context.question ?? JevQuestions.unknownOpenQuestion) : ""),
        ]
        let answer: JevAnswer
        do {
            guard let reply = try await client.ask(state: state, questions: [JevQuestions.utteranceID: JevQuestions.utterance])[JevQuestions.utteranceID]
            else { throw JevError.badResponse("missing") }
            answer = reply
        } catch {
            Self.logger.info("utterance: jev failed (\(String(describing: error), privacy: .public)); using keywords")
            return UtteranceRules.fallback(text, context: context, why: "jev failed: \(error)").timed(from: started)
        }
        let cancelProbability = answer.probability(of: "cancel")
        let cancelThreshold = context.awaitingAnswer
            ? Thresholds.cancelWhileAwaiting
            : (context.taskRunning ? Thresholds.cancelWhileWorking : Thresholds.cancelWhileIdle)
        if cancelProbability >= cancelThreshold {
            return Decision(label: .cancel, confidence: cancelProbability, source: .jev,
                            reason: "p(cancel)=\(format(cancelProbability)) >= \(cancelThreshold)").timed(from: started)
        }
        let (best, bestProbability) = ["command", "answer", "other"]
            .map { ($0, answer.probability(of: $0)) }
            .max { $0.1 < $1.1 }!
        if bestProbability >= Thresholds.utteranceLabelMinimum {
            return Decision(label: best == "command" ? .command : .other, confidence: bestProbability, source: .jev,
                            reason: "jev said \(best) p=\(format(bestProbability)); p(cancel)=\(format(cancelProbability))")
                .timed(from: started)
        }
        return UtteranceRules.fallback(
            text, context: context,
            why: "jev unsure (top \(best) p=\(format(bestProbability)), cancel \(format(cancelProbability)))"
        ).timed(from: started)
    }

    // MARK: - Risk

    public func classifyRisk(_ action: ScreenAction) async -> Decision<Risk> {
        let started = ContinuousClock.now
        func ask(_ reason: String, _ source: DecisionSource, confidence: Double = 1) -> Decision<Risk> {
            Decision(label: .needsConfirmation, confidence: confidence, source: source, reason: reason).timed(from: started)
        }
        if let category = RiskRules.alwaysAsk(action) { return ask("always ask: \(category)", .rule) }
        if RiskRules.isPlainlySafe(action) {
            return Decision(label: .safe, confidence: 1, source: .rule, reason: "only focuses, opens or looks").timed(from: started)
        }
        // Jev sees only the one sentence built in HFCore, never the user's message text.
        let description = action.description
        if let cached = riskCache.verdict(for: description) {
            return Decision(label: cached.label, confidence: cached.confidence, source: .jev,
                            reason: "cached: \(cached.reason)").timed(from: started)
        }
        guard let client else { return ask("jev disabled, so ask", .keywords, confidence: 0.5) }
        let probabilityOfSafe: Double
        do {
            guard let reply = try await client.ask(state: ["action": .string(description)], questions: [JevQuestions.riskID: JevQuestions.risk])[JevQuestions.riskID]
            else { throw JevError.badResponse("missing") }
            probabilityOfSafe = reply.probability(of: "safe")
        } catch {
            Self.logger.info("risk: jev failed (\(String(describing: error), privacy: .public)); asking")
            return ask("jev failed (\(error)), so ask", .keywords, confidence: 0.5)
        }
        let decision: Decision<Risk>
        if probabilityOfSafe >= Thresholds.safe {
            decision = Decision(label: .safe, confidence: probabilityOfSafe, source: .jev,
                                reason: "p(safe)=\(format(probabilityOfSafe))")
        } else {
            decision = Decision(label: .needsConfirmation, confidence: 1 - probabilityOfSafe, source: .jev,
                                reason: "p(safe)=\(format(probabilityOfSafe)) < \(Thresholds.safe)")
        }
        riskCache.store(decision, for: description)
        return decision.timed(from: started)
    }

    // MARK: - Answer

    public func classifyAnswer(_ answer: String, question: String) async -> Decision<Answer> {
        let started = ContinuousClock.now
        let reply = String(answer.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        if AnswerRules.normalise(reply).isEmpty {
            return Decision(label: .unclear, confidence: 1, source: .rule, reason: "empty or hesitation only").timed(from: started)
        }
        guard let client else { return AnswerRules.fallback(reply, why: "jev disabled").timed(from: started) }
        let state: JSONValue = ["assistant_asked": .string(question), "user_replied": .string(reply)]
        let jevAnswer: JevAnswer
        do {
            guard let result = try await client.ask(state: state, questions: [JevQuestions.answerID: JevQuestions.answer])[JevQuestions.answerID]
            else { throw JevError.badResponse("missing") }
            jevAnswer = result
        } catch {
            Self.logger.info("answer: jev failed (\(String(describing: error), privacy: .public)); using keywords")
            return AnswerRules.fallback(reply, why: "jev failed: \(error)").timed(from: started)
        }
        let yes = jevAnswer.probability(of: "yes")
        let no = jevAnswer.probability(of: "no")
        let probabilities = "p(yes)=\(format(yes)) p(no)=\(format(no))"
        // An unmistakable yes phrase ("mm, yes" is "yes" once hesitation is dropped)
        // corroborates Jev, so a slightly lower bar is enough. Never without Jev.
        let isExactYesPhrase = AnswerRules.yesPhrases.contains(AnswerRules.normalise(reply))
        if yes >= Thresholds.yes || (isExactYesPhrase && yes >= Thresholds.yesForExactPhrase) {
            if let veto = AnswerRules.yesVeto(reply) {
                return Decision(label: .unclear, confidence: yes, source: .rule,
                                reason: "jev leaned yes (\(probabilities)) but \(veto)").timed(from: started)
            }
            let why = yes >= Thresholds.yes ? probabilities : "\(probabilities), and an exact yes phrase"
            return Decision(label: .yes, confidence: yes, source: .jev, reason: why).timed(from: started)
        }
        if no >= Thresholds.no {
            return Decision(label: .no, confidence: no, source: .jev, reason: probabilities).timed(from: started)
        }
        // Unsure: never upgraded to yes by the word list.
        return Decision(label: .unclear, confidence: jevAnswer.probability(of: "unclear"), source: .jev,
                        reason: "not sure: \(probabilities)").timed(from: started)
    }
}

// MARK: - Helpers

extension Decision {
    /// The same decision with its latency measured from `start`.
    func timed(from start: ContinuousClock.Instant) -> Decision {
        Decision(label: label, confidence: confidence, source: source,
                 latencyMilliseconds: (start.duration(to: .now).milliseconds * 10).rounded() / 10, reason: reason)
    }
}

func format(_ probability: Double) -> String { String(format: "%.2f", probability) }

/// Remembers Jev's risk verdict for an exact action description for a while.
///
/// The same description comes up again and again in one task (`Click text field
/// "Search" in WhatsApp`), and Jev answers it the same way each time, so asking
/// again only adds 200 ms. Only Jev verdicts are stored; rules are instant anyway.
final class VerdictCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (decision: Decision<Risk>, storedAt: ContinuousClock.Instant)] = [:]
    private let lifetime: Duration
    private let capacity = 256

    init(lifetimeSeconds: Double) { lifetime = .milliseconds(Int(lifetimeSeconds * 1000)) }

    func verdict(for action: String) -> Decision<Risk>? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[action] else { return nil }
        if entry.storedAt.duration(to: .now) > lifetime {
            entries[action] = nil
            return nil
        }
        return entry.decision
    }

    func store(_ decision: Decision<Risk>, for action: String) {
        guard lifetime > .zero else { return }
        lock.lock()
        defer { lock.unlock() }
        if entries.count >= capacity { entries.removeAll() }  // simple and bounded
        entries[action] = (decision, .now)
    }
}
