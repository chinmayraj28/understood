import Foundation

public enum FactKind: String, Sendable, CaseIterable, Codable {
    case alias  // a name the user says means a real thing: "Mum" is "Amma" on WhatsApp
    case preference  // a standing choice: which Google account, which music app
    case style  // how the user likes the agent to behave: shorter confirmations
    case routine  // a named set of steps: "morning routine"
    case recipe  // how a task is done on this Mac, as advice for the screen agent
    case note  // anything else worth knowing
}

public enum FactStatus: String, Sendable, Codable {
    case candidate  // seen once; not yet relied on
    case active  // relied on
    case retired  // replaced, corrected or forgotten; kept for the audit trail
}

public enum FactSource: String, Sendable, Codable {
    case explicit  // the user said "remember that..."
    case learned  // inferred from an answer or a finished task
    case builtIn  // shipped with the app (starter recipes)
}

/// One thing the agent knows about the user.
public struct Fact: Sendable, Equatable, Identifiable, Codable {
    public var id: Int64
    public var kind: FactKind
    /// Normalised lookup key: "mum", "google_account".
    public var key: String
    public var value: String
    /// The app or area it applies to, e.g. "whatsapp". Empty means everywhere.
    public var scope: String
    public var status: FactStatus
    public var source: FactSource
    public var confidence: Double
    /// The sentence or exchange it came from.
    public var evidence: String
    public var useCount: Int
    public var createdAt: Date
    public var lastUsedAt: Date?

    public init(
        id: Int64, kind: FactKind, key: String, value: String, scope: String = "",
        status: FactStatus = .candidate, source: FactSource = .learned, confidence: Double = 0.5,
        evidence: String = "", useCount: Int = 0, createdAt: Date = Date(), lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.key = key
        self.value = value
        self.scope = scope
        self.status = status
        self.source = source
        self.confidence = confidence
        self.evidence = evidence
        self.useCount = useCount
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

/// What the rest of the app needs from memory. Implemented by HFMemory.
///
/// Every method is safe to call from anywhere and none of them throws: memory
/// must never slow down or break a task.
public protocol MemoryProviding: Sendable {
    /// Preferences and recipes relevant to a goal, as a short block for the screen agent's prompt.
    func hints(forGoal goal: String) async -> String
    /// What we know about the user, as a short block for the voice agent's prompt.
    func summaryForPrompt(maxCharacters: Int) async -> String
    /// Called after a task asked the user something and got an answer.
    /// Decides in the background whether the answer is a lasting preference.
    /// `options` are the choices that were offered, if any ("Priya Shah", "Priya Patel"),
    /// so learning does not depend on how the question happened to be worded.
    func learn(fromQuestion question: String, options: [String], answer: String, goal: String) async
    /// Called when a task ends. Logs it, and may learn a recipe from a success.
    func taskEnded(goal: String, status: TaskStatus, summary: String, steps: [String], seconds: Double) async
}
