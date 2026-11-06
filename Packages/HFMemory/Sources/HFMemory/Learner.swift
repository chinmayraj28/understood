import Foundation
import HFCore
import os

/// An optional quick yes-or-no check, such as Jev, given the question, the answer and the
/// goal. Returns the probability (0...1) that the answer is a lasting preference, or nil
/// when it cannot tell. Below 0.15 the model call is skipped. The question to ask is
/// `LearningPrompts.lastingQuestion`.
public typealias LastingPreFilter = @Sendable (_ question: String, _ answer: String, _ goal: String) async -> Double?

/// Turns experience into facts, carefully. Never throws: every failure is logged and
/// means "nothing learned". docs/MEMORY.md, Part B section 8.
public struct Learner: Sendable {
    public static let preFilterThreshold = 0.15

    let store: MemoryStore
    let model: StructuredLanguageModel?
    let lastingPreFilter: LastingPreFilter?
    let prompts: LearningPrompts?
    private let logger = Logger(subsystem: "com.handsfree", category: "memory")

    public init(store: MemoryStore, model: StructuredLanguageModel?, lastingPreFilter: LastingPreFilter? = nil,
                prompts: LearningPrompts? = LearningPrompts.bundled) {
        self.store = store
        self.model = model
        self.lastingPreFilter = lastingPreFilter
        self.prompts = prompts
    }

    // MARK: Learning from a question and answer

    /// A task asked the user something and got an answer. If the answer is a lasting
    /// preference, stores it as a candidate (or strengthens an existing one).
    ///
    /// Cheapest first: the hard rules (no model), then the name-choice rule (no model),
    /// then the optional pre-filter, then the model. Whatever is proposed is checked again
    /// in code before it is stored. Without a model only the rules run.
    @discardableResult
    public func learn(question: String, answer: String, goal: String, options: [String] = [],
                      isConfirmation: Bool = false) async -> StoredFact? {
        if let reason = ExchangeRules.neverLearnReason(question: question, answer: answer,
                                                       isConfirmation: isConfirmation) {
            logger.debug("not learning from an exchange: \(reason.rawValue, privacy: .public)")
            return nil
        }
        var proposal = ExchangeRules.nameChoice(question: question, answer: answer, goal: goal, options: options)
        if proposal == nil, let model, let prompts {
            if let preFilter = lastingPreFilter, let probability = await preFilter(question, answer, goal),
               probability < Self.preFilterThreshold {
                return nil
            }
            proposal = await askModelAboutExchange(model, prompts, question: question, answer: answer, goal: goal,
                                                   options: options)
        }
        guard let proposal else { return nil }
        let said = ([question, answer] + options + [goal]).joined(separator: " ")
        guard ExchangeRules.isGrounded(proposal, said: said, goal: goal) else {
            logger.info("a proposed fact was dropped: not grounded in the exchange")
            return nil
        }
        return save(proposal, evidence: "Asked: \(question) Answered: \(answer)")
    }

    // MARK: Reflecting on a finished task

    /// A task ended. Records how the recipes it was given did (no model needed), then asks
    /// the model for a recipe (after a success), a pitfall (after a failure) and any standing
    /// preference the user stated in the goal.
    @discardableResult
    public func reflect(goal: String, status: TaskStatus, summary: String, steps: [String],
                        recipeIDs: [Int64]) async -> [StoredFact] {
        do {
            try store.recordRecipeOutcome(recipeIDs, status: status)
        } catch {
            logger.error("recording a recipe outcome failed: \(String(describing: type(of: error)), privacy: .public)")
        }
        guard status == .done || status == .failed, let model, let prompts,
              !goal.trimmingCharacters(in: .whitespaces).isEmpty
        else { return [] }

        let givenRecipes = recipeIDs.compactMap { try? store.get($0) }
        let existingNames = ((try? store.allLive()) ?? []).filter { $0.kind == .recipe }.map(\.spokenLabel)
        // Nothing private goes to the model: message wording and secrets are taken out of the
        // goal, the summary and every step first, all together, so a code named in one place
        // ("the verification code 482913") is also removed where it appears alone ("Typed 482913").
        let lastSteps = Array(steps.suffix(20))
        let safe = Self.safeForModel([goal, summary] + lastSteps)
        let safeGoal = safe[0]
        let stepLines = safe.dropFirst(2).map { "- " + String($0.prefix(200)) }
        let input = """
            Goal (the user's words): \(safeGoal)
            Outcome: \(status == .done ? "succeeded" : "failed")
            Result: \(safe[1])
            Steps taken:
            \(stepLines.isEmpty ? "(not recorded)" : stepLines.joined(separator: "\n"))
            Recipes the agent was given: \(Self.json(givenRecipes.map { ["task": $0.spokenLabel, "how": $0.value] }))
            Existing recipe names: \(Self.json(Array(Set(existingNames)).sorted().prefix(40).map { $0 }))
            """
        guard let reply = await callModel(model, instructions: prompts.reflectInstructions, input: input,
                                          schema: prompts.reflectSchema) else { return [] }

        var stored: [StoredFact] = []
        let evidence = "From the task: \(safeGoal)"
        let task = reply["task"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
        let how = reply["how"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
        let app = reply["app"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""

        if status == .done, reply["save_recipe"]?.boolValue == true, !task.isEmpty, !how.isEmpty {
            if MessageContent.repeatsMessage("\(task) \(how)", goal: goal) {
                logger.info("a learned recipe was dropped: it repeats the message wording")
            } else if !builtInAlreadySays(task: task, app: app, how: how) {
                let recipe = ProposedFact(kind: .recipe, key: String(task.prefix(60)), value: String(how.prefix(300)),
                                          scope: app)
                if let fact = save(recipe, evidence: evidence) { stored.append(fact) }
            }
        }
        if status == .failed, let pitfall = reply["pitfall"]?.stringValue?.trimmingCharacters(in: .whitespaces),
           !pitfall.isEmpty, !MessageContent.repeatsMessage(pitfall, goal: goal) {
            if let topRecipe = recipeIDs.first {
                try? store.addPitfall(topRecipe, pitfall)
            } else if let fact = recipeFromFailure(task: task, app: app, how: how, saveRecipe: reply["save_recipe"]?.boolValue == true,
                                                   goal: goal, evidence: evidence) {
                // No recipe was given, so the failure would otherwise teach nothing.
                try? store.addPitfall(fact.id, pitfall)
                if let updated = try? store.get(fact.id) { stored.append(updated) }
            }
        }
        // Preferences only when the user spoke in standing terms ("always", "from now on").
        if ExchangeRules.standingWords.matches(goal) {
            for item in reply["preferences"]?.arrayValue ?? [] {
                guard let kind = Self.factKind(fromModel: item["kind"]?.stringValue), kind != .recipe else { continue }
                let proposal = ProposedFact(kind: kind, key: item["key"]?.stringValue ?? "",
                                            value: item["value"]?.stringValue ?? "",
                                            scope: item["scope"]?.stringValue ?? "")
                guard ExchangeRules.isGrounded(proposal, said: goal, goal: goal) else { continue }
                if let fact = save(proposal, evidence: evidence) { stored.append(fact) }
            }
        }
        return stored
    }

    // MARK: Internal

    /// Text that may be sent to a model or kept as evidence: message wording and secrets removed.
    static func safeForModel(_ text: String) -> String {
        HardRules.redactSecrets(MessageContent.redact(text))
    }

    /// Several texts from one task, made safe together (see `HardRules.redactSecrets(_:)` for lists).
    static func safeForModel(_ texts: [String]) -> [String] {
        HardRules.redactSecrets(texts.map(MessageContent.redact))
    }

    /// After a failure with no recipe given: the recipe the pitfall should attach to. An
    /// existing live recipe for the same task if there is one (never promoted by a failure),
    /// else a new candidate built from what the model said worked, if it said anything.
    private func recipeFromFailure(task: String, app: String, how: String, saveRecipe: Bool, goal: String,
                                   evidence: String) -> StoredFact? {
        guard !task.isEmpty else { return nil }
        let key = TextRules.normaliseKey(task)
        let scope = TextRules.normaliseKey(app)
        let live = ((try? store.allLive()) ?? []).filter { $0.kind == .recipe && $0.key == key && $0.scope == scope }
        if let existing = live.first(where: { !$0.isBuiltIn }) ?? live.first { return existing }
        guard saveRecipe, !how.isEmpty, !MessageContent.repeatsMessage("\(task) \(how)", goal: goal) else { return nil }
        let candidate = ProposedFact(kind: .recipe, key: String(task.prefix(60)), value: String(how.prefix(300)),
                                     scope: app)
        guard let fact = save(candidate, evidence: evidence), fact.status == .candidate else { return nil }
        return fact
    }

    private func askModelAboutExchange(_ model: StructuredLanguageModel, _ prompts: LearningPrompts, question: String,
                                       answer: String, goal: String, options: [String]) async -> ProposedFact? {
        var input = "The user's goal: \(Self.safeForModel(goal))\nThe assistant asked: \(question)\n"
        if !options.isEmpty { input += "Options offered: \(Self.json(options.map(Self.safeForModel)))\n" }
        input += "The user answered: \(answer)"
        guard let reply = await callModel(model, instructions: prompts.exchangeInstructions, input: input,
                                          schema: prompts.exchangeSchema),
              reply["lasting"]?.boolValue == true,
              let kind = Self.factKind(fromModel: reply["kind"]?.stringValue), kind != .recipe
        else { return nil }
        return ProposedFact(kind: kind, key: reply["key"]?.stringValue ?? "", value: reply["value"]?.stringValue ?? "",
                            scope: reply["scope"]?.stringValue ?? "")
    }

    private func callModel(_ model: StructuredLanguageModel, instructions: String, input: String,
                           schema: JSONValue) async -> JSONValue? {
        do {
            let reply = try await model.extract(instructions: instructions, input: input, schema: schema)
            guard reply.objectValue != nil else {
                logger.warning("the learning model returned something that is not an object")
                return nil
            }
            return reply
        } catch {
            // Never log the prompt or the error text: either could hold what the user said.
            logger.warning("the learning model call failed: \(String(describing: type(of: error)), privacy: .public)")
            return nil
        }
    }

    /// True if a built-in recipe for the same task already says what worked.
    private func builtInAlreadySays(task: String, app: String, how: String) -> Bool {
        let key = TextRules.normaliseKey(task)
        let scope = TextRules.normaliseKey(app)
        let builtIns = ((try? store.allLive()) ?? []).filter { $0.isBuiltIn && $0.key == key && $0.scope == scope }
        return builtIns.contains { TextRules.sameValue(.recipe, $0.value, how) }
    }

    private func save(_ proposal: ProposedFact, evidence: String) -> StoredFact? {
        do {
            return try store.remember(proposal.kind, key: proposal.key, value: proposal.value, scope: proposal.scope,
                                      source: .learned, evidence: evidence)
        } catch let error as SpeakableError {
            logger.info("a learned fact was refused: \(error.spokenMessage, privacy: .public)")
        } catch {
            logger.error("storing a learned fact failed: \(String(describing: type(of: error)), privacy: .public)")
        }
        return nil
    }

    /// The model's kind word. "default" is the prototype's name for `preference` and is still accepted.
    static func factKind(fromModel word: String?) -> FactKind? {
        guard let word = word?.lowercased() else { return nil }
        if word == "default" { return .preference }
        return FactKind(rawValue: word)
    }

    static func json<Value: Encodable>(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}
