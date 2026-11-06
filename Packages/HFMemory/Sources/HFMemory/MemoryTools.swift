import Foundation
import HFCore
import os

/// The memory voice tools: remember, recall, forget, forget_everything, correct_memory
/// and recent_tasks, so the user can run their memory entirely by voice.
///
/// Names, descriptions and parameter schemas come from Fixtures/memory_tools.json (bundled),
/// so the voice agent's tool definitions and this code can never drift apart. Behaviour and
/// spoken sentences: docs/MEMORY.md, Part B section 9. Every handler returns at once and
/// never throws.
public enum MemoryTools {
    static let spokenItemLimit = 5
    static let genericFailure = "Sorry, something went wrong with my memory."
    private static let logger = Logger(subsystem: "com.handsfree", category: "memory")

    /// One tool definition from the bundled JSON.
    struct Definition: Decodable {
        let name: String
        let description: String
        let parameters: JSONValue
        let timeoutSeconds: Int

        enum CodingKeys: String, CodingKey {
            case name, description, parameters
            case timeoutSeconds = "timeout_s"
        }
    }

    static let definitions: [String: Definition] = {
        struct File: Decodable { let tools: [Definition] }
        guard let url = Bundle.module.url(forResource: "memory_tools", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: file.tools.map { ($0.name, $0) })
    }()

    /// The six memory tools, bound to one memory.
    public static func make(memory: Memory) -> [ToolSpec] {
        let store = memory.store
        let handlers: [(String, @Sendable (JSONObject, MemoryStore) throws -> JSONObject)] = [
            ("remember", { try remember($0, $1) }),
            ("recall", { try recall($0, $1) }),
            ("forget", { try forget($0, $1) }),
            ("forget_everything", { try forgetEverything($0, $1) }),
            ("correct_memory", { try correct($0, $1) }),
            ("recent_tasks", { try recentTasks($0, $1) }),
        ]
        return handlers.compactMap { name, body in
            guard let definition = definitions[name] else {
                logger.error("no definition bundled for memory tool \(name, privacy: .public)")
                return nil
            }
            return ToolSpec(
                name: name, description: definition.description, parameters: definition.parameters, tier: .meta,
                timeoutSeconds: definition.timeoutSeconds,
                handler: { parameters in
                    do {
                        return try body(parameters, store)
                    } catch let error as SpeakableError {
                        return ToolResult.failure(error.spokenMessage)
                    } catch {
                        logger.error("memory tool \(name, privacy: .public) failed: \(String(describing: type(of: error)), privacy: .public)")
                        return ToolResult.failure(genericFailure)
                    }
                })
        }
    }

    // MARK: remember

    static let kindWords: [String: FactKind] = [
        "alias": .alias, "name": .alias, "contact": .alias, "person": .alias,
        "preference": .preference, "default": .preference, "choice": .preference, "account": .preference,
        "app": .preference, "style": .style, "behaviour": .style, "behavior": .style, "routine": .routine,
        "note": .note, "other": .note,
    ]

    static func remember(_ parameters: JSONObject, _ store: MemoryStore) throws -> JSONObject {
        let kind = kindWords[text(parameters["kind"]).lowercased()] ?? .note
        let key = text(parameters["key"])
        let value = text(parameters["value"])
        let app = text(parameters["app"])
        guard !key.isEmpty, !value.isEmpty else { return ToolResult.failure("Tell me what to remember and what it means.") }
        let before = try store.lookupLive(kind, key: key, scope: app)
        let fact = try store.remember(kind, key: key, value: value, scope: app, source: .explicit,
                                      evidence: "The user asked me to remember this.")
        let replaced = before.flatMap { $0.id == fact.id ? nil : FactWording.describe($0) }
        var say = "Got it. I'll remember \(FactWording.describe(fact))."
        if let replaced { say += " That replaces \(replaced)." }
        return ToolResult.ok([
            "saved": .string(FactWording.describe(fact)), "replaced": replaced.map(JSONValue.string) ?? .null,
            "fact_id": .number(Double(fact.id)), "say": .string(say),
        ])
    }

    // MARK: recall

    static func recall(_ parameters: JSONObject, _ store: MemoryStore) throws -> JSONObject {
        let about = text(parameters["about"])
        if !about.isEmpty {
            let found = try store.search(about, limit: spokenItemLimit, includeCandidates: true)
            if found.isEmpty {
                return ToolResult.ok(["count": 0, "facts": [], "say": .string("I don't have anything saved about \(about).")])
            }
            let items = found.map(spoken)
            return ToolResult.ok(["count": .number(Double(found.count)), "facts": .array(items.map(JSONValue.string)),
                                  "say": .string(join(items) + ".")])
        }
        let live = try store.allLive().filter { $0.kind != .recipe }
        let order: [FactKind: Int] = [.alias: 0, .preference: 1, .style: 2, .routine: 3, .note: 4]
        let active = live.filter { $0.status == .active }.sorted { first, second in
            let firstOrder = order[first.kind, default: 9]
            let secondOrder = order[second.kind, default: 9]
            if firstOrder != secondOrder { return firstOrder < secondOrder }
            if first.useCount != second.useCount { return first.useCount > second.useCount }
            if first.confidence != second.confidence { return first.confidence > second.confidence }
            return first.id < second.id
        }
        let learningCount = live.filter { $0.status == .candidate }.count
        if active.isEmpty && learningCount == 0 {
            return ToolResult.ok(["count": 0, "facts": [], "say": "I don't remember anything about you yet."])
        }
        let items = active.prefix(spokenItemLimit).map(spoken)
        var say = "I know \(active.count) thing\(active.count == 1 ? "" : "s")"
        if !items.isEmpty { say += ": \(join(Array(items)))" }
        if active.count > spokenItemLimit { say += ", and \(active.count - spokenItemLimit) more" }
        say += "."
        if learningCount > 0 {
            say += " I'm also still checking \(learningCount) thing\(learningCount == 1 ? "" : "s") I've noticed."
        }
        return ToolResult.ok([
            "count": .number(Double(active.count)), "learning": .number(Double(learningCount)),
            "facts": .array(items.map(JSONValue.string)), "say": .string(say),
        ])
    }

    // MARK: forget

    static func forget(_ parameters: JSONObject, _ store: MemoryStore) throws -> JSONObject {
        let about = text(parameters["about"])
        guard !about.isEmpty else { return ToolResult.failure("What should I forget?") }
        if ["everything", "all", "it all", "everything about me"].contains(about.lowercased()) {
            return ToolResult.failure("To forget everything, use forget_everything and ask the user first.")
        }
        let gone = try store.forget(about)
        if gone.isEmpty {
            return ToolResult.ok(["forgotten": 0, "say": .string("I didn't have anything saved about \(about).")])
        }
        let items = gone.prefix(spokenItemLimit).map(FactWording.describe)
        return ToolResult.ok(["forgotten": .number(Double(gone.count)), "items": .array(items.map(JSONValue.string)),
                              "say": .string("Done. I've forgotten \(join(Array(items))).")])
    }

    static let forgetEverythingQuestion = "Do you want me to forget everything I know about you? This can't be undone."

    static func forgetEverything(_ parameters: JSONObject, _ store: MemoryStore) throws -> JSONObject {
        guard parameters["confirmed"]?.boolValue == true else {
            store.requestForgetAll()
            return ToolResult.ok(["done": false, "needs_confirmation": true, "say": .string(forgetEverythingQuestion)])
        }
        let count = try store.forgetAll(confirmed: true)
        if count < 0 {
            // The agent skipped the question, or did not wait for the answer: make it ask now.
            store.requestForgetAll()
            return ToolResult.failure("I need to ask you first. " + forgetEverythingQuestion, ["needs_confirmation": true])
        }
        return ToolResult.ok(["done": true, "forgotten": .number(Double(count)),
                              "say": "Done. I've forgotten everything I knew about you."])
    }

    // MARK: correct_memory

    static func correct(_ parameters: JSONObject, _ store: MemoryStore) throws -> JSONObject {
        let about = text(parameters["about"])
        let right = text(parameters["right_value"])
        guard let target = try correctionTarget(about: about, store: store) else {
            return ToolResult.failure("I'm not sure which memory you mean. What should I correct?")
        }
        let wrong = FactWording.describe(target)
        let after = try store.recordCorrection(target.id)
        var result: JSONObject = ["corrected": .string(wrong), "fact_id": .number(Double(target.id))]
        if !right.isEmpty {
            result["use_now"] = .string(right)
            let stored = try store.remember(target.kind, key: target.spokenLabel, value: right, scope: target.scope,
                                            source: .learned,
                                            evidence: "The user corrected '\(target.value)' to '\(right)'.")
            if stored.value.lowercased() == right.lowercased() {
                result["say"] = .string("Sorry about that. I'll use \(right), and I've stopped assuming \(wrong). "
                                        + "If it's always \(right), tell me to remember it.")
            } else {  // an explicit memory stays until the user changes it explicitly
                result["say"] = .string("Sorry. I'll use \(right) this time. You told me earlier that \(wrong); "
                                        + "say 'remember' if you want to change that.")
            }
            return ToolResult.ok(result)
        }
        switch after?.status {
        case .retired?, nil: result["say"] = .string("Sorry. I've dropped \(wrong).")
        case .candidate?: result["say"] = .string("Sorry. I won't rely on \(wrong) any more without checking.")
        case .active?: result["say"] = .string("Sorry. I'll be more careful with \(wrong).")
        }
        return ToolResult.ok(result)
    }

    /// The fact a correction is about: the most recently used or offered one that matches,
    /// else the best search match. Built-in recipes are not corrected by voice.
    static func correctionTarget(about: String, store: MemoryStore) throws -> StoredFact? {
        let recent = try store.recentlyUsed().filter { !$0.isBuiltIn }
        guard !about.isEmpty else { return recent.first }
        let wanted = TextRules.tokens(about)
        if let match = recent.first(where: { fact in
            !wanted.isDisjoint(with: TextRules.tokens(fact.key).union(TextRules.tokens(fact.value))
                .union(TextRules.tokens(fact.label)))
        }) {
            return match
        }
        return try store.search(about, limit: 1, includeCandidates: true).first
    }

    // MARK: recent_tasks

    static func recentTasks(_ parameters: JSONObject, _ store: MemoryStore) throws -> JSONObject {
        let requested = parameters["count"]?.intValue ?? 3
        let count = min(5, max(1, requested))
        let episodes = try store.recentEpisodes(limit: count)
        if episodes.isEmpty { return ToolResult.ok(["tasks": [], "say": "I haven't done any tasks yet."]) }
        let lines = episodes.map { "\($0.status): \($0.summary.isEmpty ? $0.goal : $0.summary)" }
        let tasks: [JSONValue] = episodes.map { episode in
            ["goal": .string(episode.goal), "executor": .string(episode.executor), "status": .string(episode.status),
             "summary": .string(episode.summary), "steps": .number(Double(episode.steps)),
             "seconds": .number((episode.seconds * 10).rounded() / 10),
             "at": .number(episode.at.timeIntervalSince1970)]
        }
        return ToolResult.ok(["tasks": .array(tasks), "say": .string(join(lines) + ".")])
    }

    // MARK: Helpers

    /// A parameter as trimmed text. Values come from an LLM that heard speech, so anything
    /// that is not a string counts as empty.
    static func text(_ value: JSONValue?) -> String {
        value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func spoken(_ fact: StoredFact) -> String {
        FactWording.describe(fact) + (fact.status == .candidate ? " (I think; not sure yet)" : "")
    }

    /// "a", "a; and b", "a; b; and c".
    static func join(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: "; ") + "; and " + items[items.count - 1]
    }
}
