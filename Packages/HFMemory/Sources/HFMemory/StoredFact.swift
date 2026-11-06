import Foundation
import HFCore

/// A fact as the store keeps it: the shared `Fact` plus the bookkeeping that
/// drives the lifecycle (sightings, corrections, recipe outcomes, pitfalls).
public struct StoredFact: Sendable, Equatable {
    /// The shared view of this fact, as the rest of the app sees it.
    public var fact: Fact
    /// The key as the user said it ("Mum"), for speech.
    public var label: String
    /// The scope as the user said it ("WhatsApp").
    public var scopeLabel: String
    /// How many times the same value was seen (starts at 1).
    public var sightings: Int
    public var corrections: Int
    /// Recipes: tasks that succeeded or failed while this recipe was offered.
    public var successes: Int
    public var failures: Int
    public var updatedAt: Date
    /// Why it was retired: "replaced", "corrected", "forgotten", "failed" or "removed".
    public var retiredReason: String?
    /// Built-in recipes: the id and version from Fixtures/recipes.json.
    public var builtInID: String?
    public var builtInVersion: Int?
    /// Recipes: phrases that select this recipe for a goal (section 6.3).
    public var matchAny: [String]
    public var appNames: [String]
    public var notIf: [String]
    /// Recipes: short notes of what went wrong before, newest first (at most 2).
    public var pitfalls: [String]
    /// Built-in recipes whose confidence fell below 0.5: worth checking against the real app.
    public var needsReview: Bool

    public var id: Int64 { fact.id }
    public var kind: FactKind { fact.kind }
    public var key: String { fact.key }
    public var value: String { fact.value }
    public var scope: String { fact.scope }
    public var status: FactStatus { fact.status }
    public var source: FactSource { fact.source }
    public var confidence: Double { fact.confidence }
    public var evidence: String { fact.evidence }
    public var useCount: Int { fact.useCount }
    public var isBuiltIn: Bool { fact.source == .builtIn }

    /// The label if one was recorded, else the key with underscores as spaces.
    public var spokenLabel: String { label.isEmpty ? fact.key.replacingOccurrences(of: "_", with: " ") : label }
}

/// The extra fields kept as JSON in the `extra` column.
struct FactExtras: Codable, Equatable {
    var label: String?
    var scopeLabel: String?
    var builtInID: String?
    var version: Int?
    var matchAny: [String]?
    var appNames: [String]?
    var notIf: [String]?
    var pitfalls: [String]?
    var needsReview: Bool?

    enum CodingKeys: String, CodingKey {
        case label
        case scopeLabel = "scope_label"
        case builtInID = "builtin_id"
        case version
        case matchAny = "match_any"
        case appNames = "app_names"
        case notIf = "not_if"
        case pitfalls
        case needsReview = "needs_review"
    }

    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static func from(_ json: String) -> FactExtras {
        (try? JSONDecoder().decode(FactExtras.self, from: Data(json.utf8))) ?? FactExtras()
    }
}

/// One finished task, as the episode log keeps it (message wording already redacted).
public struct Episode: Sendable, Equatable {
    public let goal: String
    public let executor: String
    public let status: String
    public let summary: String
    public let steps: Int
    public let seconds: Double
    public let at: Date
}

/// A starter recipe shipped in Fixtures/recipes.json.
public struct BuiltInRecipe: Codable, Sendable, Equatable {
    public let id: String
    public let version: Int
    public let task: String
    public let app: String
    public let appNames: [String]
    public let matchAny: [String]
    public let notIf: [String]
    public let how: String

    enum CodingKeys: String, CodingKey {
        case id, version, task, app, how
        case appNames = "app_names"
        case matchAny = "match_any"
        case notIf = "not_if"
    }

    public init(id: String, version: Int, task: String, app: String, appNames: [String], matchAny: [String],
                notIf: [String], how: String) {
        self.id = id
        self.version = version
        self.task = task
        self.app = app
        self.appNames = appNames
        self.matchAny = matchAny
        self.notIf = notIf
        self.how = how
    }

    /// The recipes bundled with this package (a copy of Fixtures/recipes.json).
    public static func bundled() -> [BuiltInRecipe] {
        guard let url = Bundle.module.url(forResource: "recipes", withExtension: "json") else { return [] }
        return (try? decode(Data(contentsOf: url))) ?? []
    }

    /// Reads a recipes file: `{"format": 1, "recipes": [...]}`.
    public static func decode(_ data: Data) throws -> [BuiltInRecipe] {
        struct File: Decodable { let recipes: [BuiltInRecipe] }
        return try JSONDecoder().decode(File.self, from: data).recipes
    }
}

/// This package's resource bundle (recipes, tool definitions, prompts).
enum MemoryResources {
    static var bundle: Bundle { Bundle.module }
}
