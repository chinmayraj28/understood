import Foundation
import HFCore

/// What the screen agent is given for one goal, and which facts made it in.
public struct MemoryHints: Sendable, Equatable {
    /// The block for the screen agent's prompt, or "" when memory has nothing useful.
    public let text: String
    /// Preferences, names and notes that made it into the text.
    public let factIDs: [Int64]
    /// Recipes that made it into the text, so their outcome can be recorded when the task ends.
    public let recipeIDs: [Int64]
    /// Unconfirmed names and preferences offered as a suggestion to check ("Priya Shah, like
    /// last time?"), so a yes or no to that question can promote or retire them.
    public let suggestedIDs: [Int64]

    public init(text: String, factIDs: [Int64], recipeIDs: [Int64], suggestedIDs: [Int64] = []) {
        self.text = text
        self.factIDs = factIDs
        self.recipeIDs = recipeIDs
        self.suggestedIDs = suggestedIDs
    }

    public static let empty = MemoryHints(text: "", factIDs: [], recipeIDs: [])

    /// The yes-or-no question the agent should ask about an unconfirmed fact.
    public static func suggestedQuestion(for fact: StoredFact) -> String { "\(fact.value), like last time?" }
}

/// Turning a fact into words. docs/MEMORY.md, Part B section 6.5.
public enum FactWording {
    /// A short phrase for speech or a prompt: `"Mum" means Amma on WhatsApp`.
    public static func describe(_ fact: StoredFact) -> String {
        let label = fact.spokenLabel
        let value = fact.value
        let place = fact.scope.isEmpty ? "" : " on \(scopeName(fact))"
        switch fact.kind {
        case .alias: return "\"\(label)\" means \(value)\(place)"
        case .preference: return "\(label)\(place): \(value)"
        case .style: return "preferred \(label): \(value)"
        case .routine: return "\"\(label)\" means: \(value)"
        case .recipe: return "to \(label)\(place): \(value)"
        case .note: return label.isEmpty || label.lowercased() == "note" ? value : "\(label): \(value)"
        }
    }

    /// The app as the user said it, or the stored scope with spaces.
    static func scopeName(_ fact: StoredFact) -> String {
        fact.scopeLabel.isEmpty ? fact.scope.replacingOccurrences(of: "_", with: " ") : fact.scopeLabel
    }
}

extension MemoryStore {
    // MARK: Search (6.1)

    /// Preferences, names, styles, routines and notes relevant to a text, best first.
    /// Word overlap, no embeddings, so every match can be explained:
    /// +3 if every word of the key is in the text, partial credit for some, +1 if the
    /// fact's app is named, +0.5 per value word in the text (at most 2), then confidence
    /// as a tie-break. Recipes are chosen separately by `selectRecipes`.
    public func search(_ text: String, limit: Int = 8, includeCandidates: Bool = false) throws -> [StoredFact] {
        let goalWords = TextRules.tokens(text)
        guard !goalWords.isEmpty else { return [] }
        let live = try locked { try facts(where: "status != 'retired' AND kind != 'recipe'") }
        var scored: [(score: Double, fact: StoredFact)] = []
        for fact in live {
            if fact.status == .candidate && !includeCandidates { continue }
            var keyWords = TextRules.tokens(fact.key)
            if keyWords.isEmpty { keyWords = TextRules.tokens(fact.label) }
            guard !keyWords.isEmpty else { continue }
            let overlap = Double(keyWords.intersection(goalWords).count) / Double(keyWords.count)
            var score = overlap == 1 ? 3.0 : 1.5 * overlap
            if !fact.scope.isEmpty, TextRules.tokens(fact.scope).isSubset(of: goalWords) { score += 1 }
            score += 0.5 * Double(min(2, TextRules.tokens(fact.value).intersection(goalWords).count))
            guard score > 0 else { continue }
            scored.append((score + fact.confidence, fact))
        }
        scored.sort { first, second in
            if first.score != second.score { return first.score > second.score }
            if first.fact.useCount != second.fact.useCount { return first.fact.useCount > second.fact.useCount }
            return first.fact.id < second.fact.id
        }
        return scored.prefix(limit).map(\.fact)
    }

    // MARK: Summary for the voice agent (6.2)

    /// A short block for the voice agent's system prompt, most useful first, within `maxCharacters`.
    /// Style first (it shapes every reply), then names and standing choices, then routines and
    /// notes; within that, confidence, use and recent use. No recipes and no candidates.
    public func summaryForPrompt(maxCharacters: Int = 1200) throws -> String {
        let weights: [FactKind: Double] = [.style: 3, .alias: 2.5, .preference: 2.5, .routine: 2, .note: 1]
        let currentTime = now
        let candidates = try allActive().filter { weights[$0.kind] != nil }
        guard !candidates.isEmpty else { return "" }
        func usefulness(_ fact: StoredFact) -> Double {
            let usedRecently = (fact.fact.lastUsedAt?.timeIntervalSince1970).map { currentTime - $0 < 7 * 86_400 } ?? false
            return weights[fact.kind, default: 0] * fact.confidence + 0.3 * log1p(Double(fact.useCount))
                + (usedRecently ? 0.5 : 0)
        }
        let ordered = candidates.sorted { first, second in
            let firstScore = usefulness(first)
            let secondScore = usefulness(second)
            return firstScore != secondScore ? firstScore > secondScore : first.id < second.id
        }
        let header = "What you know about the user (they told you, or it held up before):"
        var lines = [header]
        var used = header.count
        for (index, fact) in ordered.enumerated() {
            let line = "- " + TextRules.cleanValue(FactWording.describe(fact), limit: 160)
            let remaining = ordered.count - index
            let tail = "- (\(remaining) more; use the recall tool)"
            let room = used + 1 + line.count + (remaining > 1 ? 1 + tail.count : 0)
            if room > maxCharacters {
                if used + 1 + tail.count <= maxCharacters { lines.append(tail) }
                break
            }
            lines.append(line)
            used += 1 + line.count
        }
        return lines.count > 1 ? lines.joined(separator: "\n") : ""
    }

    // MARK: Recipe selection (6.3)

    /// At most two recipes for a goal: the best match, and a second only if it is for a
    /// different app ("look up the weather and add it to my notes").
    ///
    /// A recipe is skipped if any `notIf` phrase is in the goal. Otherwise it scores one
    /// point per `matchAny` phrase found (at most 3), two if one of its `appNames` is named,
    /// and one more when no app is named but an alias in the hints belongs to its app
    /// ("Message Mum" with Mum on WhatsApp). It needs 2 points to be chosen.
    public func selectRecipes(forGoal goal: String, hintFacts: [StoredFact] = []) throws -> [StoredFact] {
        let recipes = try locked { try facts(where: "kind = 'recipe' AND status != 'retired' ORDER BY id") }
        let builtIns = recipes.filter(\.isBuiltIn)
        var choices: [StoredFact] = []
        for recipe in recipes {
            if recipe.isBuiltIn {
                // A trusted learned recipe for the same task takes the built-in one's place.
                let override = recipes.first {
                    !$0.isBuiltIn && $0.key == recipe.key && $0.scope == recipe.scope && $0.status == .active
                        && $0.confidence >= recipe.confidence
                }
                if override == nil { choices.append(recipe) }
            } else {
                let sibling = builtIns.first { $0.key == recipe.key && $0.scope == recipe.scope }
                if let sibling, !(recipe.status == .active && recipe.confidence >= sibling.confidence) { continue }
                choices.append(recipe)
            }
        }
        struct Scored { let score: Double; let recipe: StoredFact }
        var scored: [Scored] = []
        for recipe in choices {
            let lists = selectionLists(for: recipe, builtIns: builtIns)
            if lists.notIf.contains(where: { TextRules.phraseMatches($0, in: goal) }) { continue }
            let hits = min(3, lists.matchAny.filter { TextRules.phraseMatches($0, in: goal) }.count)
            let appNamed = lists.appNames.contains { TextRules.phraseMatches($0, in: goal) } ? 2 : 0
            let aliasBonus = appNamed == 0 && hintFacts.contains {
                $0.kind == .alias && $0.scope == recipe.scope && !recipe.scope.isEmpty
                    && TextRules.phraseMatches($0.key.replacingOccurrences(of: "_", with: " "), in: goal)
            } ? 1 : 0
            let base = hits + appNamed + aliasBonus
            guard base >= 2 else { continue }
            scored.append(Scored(score: Double(base) + recipe.confidence, recipe: recipe))
        }
        scored.sort { first, second in
            if first.score != second.score { return first.score > second.score }
            if first.recipe.useCount != second.recipe.useCount { return first.recipe.useCount > second.recipe.useCount }
            return first.recipe.id < second.recipe.id
        }
        guard let best = scored.first else { return [] }
        var picked = [best.recipe]
        if let second = scored.dropFirst().first(where: { $0.recipe.scope != best.recipe.scope }) {
            picked.append(second.recipe)
        }
        return picked
    }

    /// Built-in recipes carry their phrase lists; a learned one uses the words of its task
    /// name, or inherits the lists of a built-in recipe for the same task.
    private func selectionLists(for recipe: StoredFact, builtIns: [StoredFact])
        -> (matchAny: [String], appNames: [String], notIf: [String])
    {
        if recipe.isBuiltIn { return (recipe.matchAny, recipe.appNames, recipe.notIf) }
        if let sibling = builtIns.first(where: { $0.key == recipe.key && $0.scope == recipe.scope }) {
            return (sibling.matchAny, sibling.appNames, sibling.notIf)
        }
        let appWords = TextRules.tokens(recipe.scope)
        let words = TextRules.tokens(recipe.spokenLabel).subtracting(appWords).sorted()
        let appName = recipe.scope.replacingOccurrences(of: "_", with: " ")
        return (words, appName.isEmpty ? [] : [appName], [])
    }

    // MARK: Hints for the screen agent (6.4)

    /// The compact block the task runner puts in `context.memoryHints`: one or two recipes,
    /// the names and preferences that matter for this goal, and nothing else. It is read on
    /// every step, so it stays within `maxCharacters`; lines are dropped, never cut.
    public func memoryHints(forGoal goal: String, maxCharacters: Int = 700) throws -> MemoryHints {
        let wantedKinds: Set<FactKind> = [.alias, .preference, .routine, .note]
        let found = try search(goal, limit: 8, includeCandidates: true).filter { wantedKinds.contains($0.kind) }
        let facts = Array(found.filter { $0.status == .active }.prefix(4))
        // One answer should already help next time: an unconfirmed name or preference is
        // offered as something to check with a yes-or-no question, never relied on silently.
        let suggestions = Array(found.filter { $0.status == .candidate && ($0.kind == .alias || $0.kind == .preference) }
            .prefix(2))
        let recipes = try selectRecipes(forGoal: goal, hintFacts: facts + suggestions)

        let header = "Advice from memory (check each step on screen; it never replaces asking before sending):"
        var lines = [header]
        var used = header.count
        var factIDs: [Int64] = []
        var recipeIDs: [Int64] = []

        func add(_ line: String) -> Bool {
            guard used + 1 + line.count <= maxCharacters else { return false }
            lines.append(line)
            used += 1 + line.count
            return true
        }
        func addRecipe(_ recipe: StoredFact) {
            let note = recipe.status == .candidate ? " (not yet confirmed; check it)" : ""
            let line = "How to \(recipe.spokenLabel): \(TextRules.cleanValue(recipe.value, limit: 450))\(note)"
            guard add(line) else { return }
            recipeIDs.append(recipe.id)
            if let pitfall = recipe.pitfalls.first { _ = add("  Watch out: \(pitfall)") }
        }

        if let first = recipes.first { addRecipe(first) }
        let aliases = facts.filter { $0.kind == .alias }
        if !aliases.isEmpty {
            let names = aliases.map { alias -> String in
                let place = alias.scope.isEmpty ? "" : " (\(FactWording.scopeName(alias)))"
                return "\"\(alias.spokenLabel)\" is \(alias.value)\(place)"
            }
            if add("Names: " + names.joined(separator: "; ") + ".") { factIDs += aliases.map(\.id) }
        }
        let preferences = facts.filter { $0.kind == .preference }
        if !preferences.isEmpty,
           add("Preferences: " + preferences.map(FactWording.describe).joined(separator: "; ") + ".") {
            factIDs += preferences.map(\.id)
        }
        var suggestedIDs: [Int64] = []
        for suggestion in suggestions {
            let question = MemoryHints.suggestedQuestion(for: suggestion)
            let meaning = suggestion.kind == .alias
                ? "Last time \"\(suggestion.spokenLabel)\" meant \(suggestion.value)"
                : "Last time \(suggestion.spokenLabel) was \(suggestion.value)"
            if add("\(meaning) (not yet confirmed: ask \"\(question)\").") { suggestedIDs.append(suggestion.id) }
        }
        for fact in facts where fact.kind == .routine || fact.kind == .note {
            if add(TextRules.cleanValue(FactWording.describe(fact), limit: 300)) { factIDs.append(fact.id) }
        }
        if recipes.count > 1 { addRecipe(recipes[1]) }

        guard lines.count > 1 else { return .empty }
        noteOffered(factIDs + recipeIDs + suggestedIDs)
        return MemoryHints(text: lines.joined(separator: "\n"), factIDs: factIDs, recipeIDs: recipeIDs,
                           suggestedIDs: suggestedIDs)
    }
}
