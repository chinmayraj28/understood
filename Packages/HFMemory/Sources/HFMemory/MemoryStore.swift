import Foundation
import HFCore
import os

/// The numbers that drive the lifecycle, named so the rules are easy to explain.
/// docs/MEMORY.md, Part B section 4.
public enum MemoryLimits {
    public static let explicitConfidence = 0.9
    public static let learnedConfidence = 0.5
    public static let promotedConfidence = 0.7
    public static let builtInConfidence = 0.8
    public static let builtInFloor = 0.3
    public static let trustThreshold = 0.5
    public static let retireThreshold = 0.25
    public static let useStep = 0.1
    public static let correctionStep = 0.3
    public static let recipeSuccessStep = 0.15
    public static let recipeFailureStep = 0.15
    public static let maximumValueLength = 300
    public static let maximumBuiltInRecipeLength = 450
    public static let maximumEvidenceLength = 300
    public static let maximumPitfallLength = 120
    public static let maximumPitfalls = 2
    public static let maximumEpisodes = 500
    public static let recentWindowSeconds = 15.0 * 60
    public static let wipeMinimumWaitSeconds = 2.0
    public static let wipeMaximumWaitSeconds = 120.0
}

/// The SQLite-backed memory. Every public method is safe to call from any thread
/// or task: one connection, guarded by one lock, and every write is a transaction.
///
/// The lifecycle in plain words:
/// - what the user says explicitly is trusted at once; what is inferred starts as a
///   candidate and is promoted when seen again;
/// - there is at most one live fact per kind, key and scope (built-in recipes are
///   counted separately), and a new value retires the old one;
/// - use and success raise confidence; corrections and failures lower it;
/// - `forget` wipes values, because the user asked.
public final class MemoryStore: @unchecked Sendable {
    public let fileURL: URL
    private let clock: @Sendable () -> Date
    private let lock = NSRecursiveLock()
    /// Internal so tests can prove the database itself enforces the rules.
    let database: SQLiteDatabase
    private let logger = Logger(subsystem: "com.handsfree", category: "memory")
    /// Facts used or offered recently, newest last, for "no, the other one".
    private var recent: [(id: Int64, at: Double)] = []
    private var forgetAllAskedAt: Double?
    private var builtInRecipes: [BuiltInRecipe] = []

    static let schemaVersion = 1
    static let columns = """
        id, kind, key, value, scope, status, source, confidence, evidence, uses, sightings, corrections, \
        successes, failures, created_at, updated_at, last_used_at, retired_at, retired_reason, extra
        """

    /// Opens (or creates) the database at `fileURL`, making the folder 0700 and the file 0600.
    public init(fileURL: URL, clock: @escaping @Sendable () -> Date = { Date() }) throws {
        self.fileURL = fileURL
        self.clock = clock
        try Self.preparePrivateFile(fileURL)
        database = try SQLiteDatabase(path: fileURL.path)
        try database.executeScript("PRAGMA secure_delete = ON; PRAGMA foreign_keys = ON;")
        try migrate()
    }

    /// Opens `<settings.dataDirectory>/memory.db` and loads the bundled built-in recipes.
    public static func openDefault(settings: Settings) throws -> MemoryStore {
        let store = try MemoryStore(fileURL: settings.dataDirectory.appendingPathComponent("memory.db"))
        try store.seedBuiltInRecipes(BuiltInRecipe.bundled())
        return store
    }

    public func close() { locked { database.close() } }

    /// The current time from the injected clock, in seconds since 1970.
    var now: Double { clock().timeIntervalSince1970 }

    func locked<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: - Writing

    /// Stores a fact following the lifecycle rules, and returns the live fact.
    ///
    /// - explicit: active at once; replaces any live fact with another value.
    /// - learned, same value as a live fact: a sighting; a candidate seen twice is promoted.
    /// - learned, different value: replaces a learned fact (the new one starts as a candidate)
    ///   but never an explicit one. Then the explicit fact comes back unchanged, so
    ///   `result.value != value`.
    ///
    /// Throws `SpeakableError` for secrets, permission to skip a confirmation, or an empty
    /// key or value. Built-in recipes are added with `seedBuiltInRecipes`, not here.
    @discardableResult
    public func remember(
        _ kind: FactKind, key: String, value: String, scope: String = "", source: FactSource = .learned,
        evidence: String = "", confidence: Double? = nil
    ) throws -> StoredFact {
        precondition(source != .builtIn, "built-in recipes are added with seedBuiltInRecipes")
        let label = TextRules.cleanValue(key, limit: TextRules.maximumKeyLength)
        let normalisedKey = TextRules.normaliseKey(key)
        let normalisedScope = TextRules.normaliseKey(scope)
        let cleanedValue = TextRules.cleanValue(value, limit: MemoryLimits.maximumValueLength)
        guard !normalisedKey.isEmpty, !cleanedValue.isEmpty else {
            throw SpeakableError("I need both what to remember and what it means.")
        }
        if let reason = HardRules.refusalReason(key: label, value: cleanedValue) {
            logger.info("memory refused a \(kind.rawValue, privacy: .public) fact")
            throw SpeakableError(reason)
        }
        var cleanedEvidence = TextRules.cleanValue(evidence, limit: MemoryLimits.maximumEvidenceLength)
        if HardRules.looksSecret(cleanedEvidence) { cleanedEvidence = "" }  // keep the fact, drop the risky context
        let explicit = source == .explicit
        let timestamp = now

        return try locked {
            try database.transaction {
                if let live = try liveFact(kind, normalisedKey, normalisedScope, builtIn: false) {
                    if TextRules.sameValue(kind, live.value, cleanedValue) {
                        return try reinforce(live, explicit: explicit, newValue: cleanedValue,
                                             evidence: cleanedEvidence, at: timestamp)
                    }
                    if !explicit && live.source == .explicit {
                        logger.info("learned value ignored: an explicit fact exists")
                        return live
                    }
                    try retire(live.id, reason: "replaced", at: timestamp)
                }
                var extras = FactExtras(label: label)
                if !scope.isEmpty { extras.scopeLabel = TextRules.cleanValue(scope, limit: 40) }
                let startingConfidence = confidence
                    ?? (explicit ? MemoryLimits.explicitConfidence : MemoryLimits.learnedConfidence)
                let id = try database.execute(
                    """
                    INSERT INTO facts (kind, key, value, scope, status, source, confidence, evidence, uses,
                        sightings, corrections, successes, failures, created_at, updated_at, last_used_at, extra)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, 1, 0, 0, 0, ?, ?, 0, ?)
                    """,
                    [.text(kind.rawValue), .text(normalisedKey), .text(cleanedValue), .text(normalisedScope),
                     .text((explicit ? FactStatus.active : .candidate).rawValue), .text(source.rawValue),
                     .real(Self.clamp(startingConfidence)), .text(cleanedEvidence), .real(timestamp),
                     .real(timestamp), .text(extras.json)])
                return try requireFact(id)
            }
        }
    }

    /// The fact was applied and helped: confidence up, use counted.
    public func recordUse(_ id: Int64) throws {
        let timestamp = now
        try locked {
            try database.transaction {
                guard let fact = try fetch(id), fact.status != .retired else { return }
                let confidence = fact.confidence + (1 - fact.confidence) * MemoryLimits.useStep
                try database.execute(
                    "UPDATE facts SET confidence = ?, uses = uses + 1, last_used_at = ?, updated_at = ? WHERE id = ?",
                    [.real(Self.clamp(confidence)), .real(timestamp), .real(timestamp), .integer(id)])
                noteRecent(id, at: timestamp)
            }
        }
    }

    /// The user said this fact was wrong: confidence down by 0.3. An active fact below 0.5
    /// becomes a candidate (never applied silently); at 0.25 or below it is retired.
    /// Built-in recipes change only through task outcomes. Returns the fact as it is now.
    @discardableResult
    public func recordCorrection(_ id: Int64) throws -> StoredFact? {
        let timestamp = now
        return try locked {
            try database.transaction {
                guard let fact = try fetch(id) else { return nil }
                guard fact.status != .retired, !fact.isBuiltIn else { return fact }
                let confidence = Self.clamp(fact.confidence - MemoryLimits.correctionStep)
                try database.execute(
                    "UPDATE facts SET confidence = ?, corrections = corrections + 1, updated_at = ? WHERE id = ?",
                    [.real(confidence), .real(timestamp), .integer(id)])
                if confidence <= MemoryLimits.retireThreshold {
                    try retire(id, reason: "corrected", at: timestamp)
                } else if fact.status == .active && confidence < MemoryLimits.trustThreshold {
                    try setStatus(id, .candidate, at: timestamp)
                }
                return try fetch(id)
            }
        }
    }

    /// The user said yes to "Priya Shah, like last time?": the candidate counts as seen
    /// again, so it is promoted to active. Only candidates of the user's own kinds qualify.
    @discardableResult
    public func confirmCandidate(_ id: Int64, evidence: String = "") throws -> StoredFact? {
        try locked {
            guard let fact = try fetch(id), fact.status == .candidate, !fact.isBuiltIn, fact.kind != .recipe else {
                return try fetch(id)
            }
            return try remember(fact.kind, key: fact.spokenLabel, value: fact.value, scope: fact.scope,
                                source: .learned, evidence: evidence)
        }
    }

    /// The user said no to "Priya Shah, like last time?": the candidate was wrong, so it is
    /// retired (reason "corrected") and the agent asks the open question instead.
    @discardableResult
    public func rejectCandidate(_ id: Int64) throws -> StoredFact? {
        let timestamp = now
        return try locked {
            try database.transaction {
                guard let fact = try fetch(id), fact.status == .candidate, !fact.isBuiltIn, fact.kind != .recipe else {
                    return try fetch(id)
                }
                try database.execute("UPDATE facts SET corrections = corrections + 1 WHERE id = ?", [.integer(id)])
                try retire(id, reason: "corrected", at: timestamp)
                return try fetch(id)
            }
        }
    }

    /// A task ended while these recipes were offered: success raises their confidence,
    /// failure lowers it. A cancel changes nothing (it was the user's choice).
    public func recordRecipeOutcome(_ recipeIDs: [Int64], status: TaskStatus) throws {
        guard status == .done || status == .failed else { return }
        let timestamp = now
        try locked {
            try database.transaction {
                for id in Set(recipeIDs) {
                    guard let recipe = try fetch(id), recipe.kind == .recipe, recipe.status != .retired else { continue }
                    var confidence = recipe.confidence
                    if status == .done {
                        confidence += (1 - confidence) * MemoryLimits.recipeSuccessStep
                        try database.execute(
                            "UPDATE facts SET successes = successes + 1, confidence = ?, updated_at = ? WHERE id = ?",
                            [.real(Self.clamp(confidence)), .real(timestamp), .integer(id)])
                        // Offered and it worked: that counts as a learned recipe's second sighting.
                        if recipe.status == .candidate { try setStatus(id, .active, at: timestamp) }
                    } else {
                        confidence -= MemoryLimits.recipeFailureStep
                        if recipe.isBuiltIn { confidence = max(confidence, MemoryLimits.builtInFloor) }
                        try database.execute(
                            "UPDATE facts SET failures = failures + 1, confidence = ?, updated_at = ? WHERE id = ?",
                            [.real(Self.clamp(confidence)), .real(timestamp), .integer(id)])
                        if !recipe.isBuiltIn {
                            if confidence <= MemoryLimits.retireThreshold {
                                try retire(id, reason: "failed", at: timestamp)
                            } else if recipe.status == .active && confidence < MemoryLimits.trustThreshold {
                                try setStatus(id, .candidate, at: timestamp)
                            }
                        }
                    }
                    if recipe.isBuiltIn {
                        try updateExtras(id) { $0.needsReview = confidence < MemoryLimits.trustThreshold }
                    }
                }
            }
        }
    }

    /// Adds a short note of what went wrong to a recipe (newest first, at most 2).
    /// Refused if it looks like a secret or a rule that skips a confirmation.
    public func addPitfall(_ recipeID: Int64, _ text: String) throws {
        let pitfall = TextRules.cutAtWord(TextRules.cleanValue(text, limit: 1000), limit: MemoryLimits.maximumPitfallLength)
        guard !pitfall.isEmpty, HardRules.refusalReason(key: "pitfall", value: pitfall) == nil else { return }
        try locked {
            try database.transaction {
                guard let recipe = try fetch(recipeID), recipe.kind == .recipe else { return }
                if recipe.pitfalls.contains(where: { TextRules.overlap($0, pitfall) >= 0.5 }) { return }
                try updateExtras(recipeID) { extras in
                    extras.pitfalls = Array(([pitfall] + (extras.pitfalls ?? [])).prefix(MemoryLimits.maximumPitfalls))
                }
            }
        }
    }

    /// Notes that these facts were just given to an agent as hints, so "no, the other one"
    /// can find them. Does not change confidence.
    public func noteOffered(_ ids: [Int64]) {
        let timestamp = now
        locked { for id in ids { noteRecent(id, at: timestamp) } }
    }

    // MARK: - Forgetting

    /// Retires every live fact about `text` and wipes its value, evidence and extras.
    /// "forget what I said about Priya" → `forget("what I said about Priya")`. Episodes that
    /// mention the forgotten words are deleted. Built-in recipes are never matched: they
    /// hold nothing about the user. The returned facts still carry their old values so the
    /// caller can say what went; on disk they are gone.
    @discardableResult
    public func forget(_ text: String) throws -> [StoredFact] {
        let wanted = TextRules.tokens(text)
        guard !wanted.isEmpty else { return [] }
        let timestamp = now
        let matched: [StoredFact] = try locked {
            try database.transaction {
                let matches = try facts(where: "status != 'retired' AND source != 'builtIn'").filter { fact in
                    let words = TextRules.tokens(fact.key).union(TextRules.tokens(fact.value))
                        .union(TextRules.tokens(fact.scope)).union(TextRules.tokens(fact.label))
                    return !wanted.isDisjoint(with: words)
                }
                for fact in matches {
                    try database.execute(
                        """
                        UPDATE facts SET value = '', evidence = '', extra = '{}', status = 'retired',
                            retired_at = ?, retired_reason = 'forgotten', updated_at = ? WHERE id = ?
                        """, [.real(timestamp), .real(timestamp), .integer(fact.id)])
                }
                let episodeWords = matches.reduce(wanted) { $0.union(TextRules.tokens($1.key)) }
                for row in try database.query("SELECT id, goal, summary FROM episodes") {
                    let words = TextRules.tokens(row["goal"]?.text ?? "").union(TextRules.tokens(row["summary"]?.text ?? ""))
                    if !episodeWords.isDisjoint(with: words) {
                        try database.execute("DELETE FROM episodes WHERE id = ?", [row["id"] ?? .null])
                    }
                }
                return matches
            }
        }
        return matched
    }

    /// Step one of "forget everything": notes that the user is being asked.
    public func requestForgetAll() { locked { forgetAllAskedAt = now } }

    /// Deletes every fact and episode, then restores the built-in recipes.
    ///
    /// Needs `confirmed` and a `requestForgetAll()` between 2 seconds and 2 minutes earlier:
    /// a spoken question and answer take more than 2 seconds, so an agent that retries at
    /// once without asking is refused. Returns how many of the user's facts were deleted,
    /// or -1 if the confirmation was missing.
    @discardableResult
    public func forgetAll(confirmed: Bool) throws -> Int {
        try locked {
            let waited = now - (forgetAllAskedAt ?? -.infinity)
            guard confirmed, forgetAllAskedAt != nil,
                  waited >= MemoryLimits.wipeMinimumWaitSeconds, waited < MemoryLimits.wipeMaximumWaitSeconds
            else { return -1 }
            forgetAllAskedAt = nil
            let count = try database.transaction { () -> Int in
                let count = try database.query("SELECT COUNT(*) AS n FROM facts WHERE source != 'builtIn'")
                    .first?["n"]?.integer ?? 0
                try database.execute("DELETE FROM facts")
                try database.execute("DELETE FROM episodes")
                return Int(count)
            }
            recent.removeAll()
            try database.executeScript("VACUUM")
            try seedBuiltInRecipes(builtInRecipes)
            return count
        }
    }

    // MARK: - Built-in recipes

    /// Loads the starter recipes: inserts new ones, refreshes ones whose version went up,
    /// leaves unchanged ones alone (they keep what they learned), and retires ones that are
    /// no longer shipped. A recipe that breaks a hard rule is skipped and logged.
    public func seedBuiltInRecipes(_ recipes: [BuiltInRecipe]) throws {
        let timestamp = now
        try locked {
            builtInRecipes = recipes
            try database.transaction {
                var seenIDs = Set<String>()
                let existing = try facts(where: "source = 'builtIn' AND status != 'retired'")
                for recipe in recipes {
                    guard !seenIDs.contains(recipe.id) else {
                        logger.error("duplicate built-in recipe id \(recipe.id, privacy: .public)")
                        continue
                    }
                    guard recipe.how.count <= MemoryLimits.maximumBuiltInRecipeLength,
                          HardRules.refusalReason(key: recipe.task, value: recipe.how) == nil,
                          !TextRules.normaliseKey(recipe.task).isEmpty
                    else {
                        logger.error("built-in recipe \(recipe.id, privacy: .public) breaks a rule; skipped")
                        continue
                    }
                    seenIDs.insert(recipe.id)
                    let extras = FactExtras(
                        label: recipe.task, scopeLabel: recipe.app, builtInID: recipe.id, version: recipe.version,
                        matchAny: recipe.matchAny, appNames: recipe.appNames, notIf: recipe.notIf, pitfalls: [],
                        needsReview: false)
                    let how = TextRules.cleanValue(recipe.how, limit: MemoryLimits.maximumBuiltInRecipeLength)
                    if let current = existing.first(where: { $0.builtInID == recipe.id }) {
                        guard (current.builtInVersion ?? 0) < recipe.version else { continue }
                        try database.execute(
                            """
                            UPDATE facts SET key = ?, value = ?, scope = ?, confidence = ?, successes = 0,
                                failures = 0, extra = ?, updated_at = ? WHERE id = ?
                            """,
                            [.text(TextRules.normaliseKey(recipe.task)), .text(how),
                             .text(TextRules.normaliseKey(recipe.app)), .real(MemoryLimits.builtInConfidence),
                             .text(extras.json), .real(timestamp), .integer(current.id)])
                    } else {
                        try database.execute(
                            """
                            INSERT INTO facts (kind, key, value, scope, status, source, confidence, evidence, uses,
                                sightings, corrections, successes, failures, created_at, updated_at, last_used_at, extra)
                            VALUES ('recipe', ?, ?, ?, 'active', 'builtIn', ?, '', 0, 1, 0, 0, 0, ?, ?, 0, ?)
                            """,
                            [.text(TextRules.normaliseKey(recipe.task)), .text(how),
                             .text(TextRules.normaliseKey(recipe.app)), .real(MemoryLimits.builtInConfidence),
                             .real(timestamp), .real(timestamp), .text(extras.json)])
                    }
                }
                for stale in existing where !seenIDs.contains(stale.builtInID ?? "") {
                    try retire(stale.id, reason: "removed", at: timestamp)
                }
            }
        }
    }

    // MARK: - Reading

    public func get(_ id: Int64) throws -> StoredFact? { try locked { try fetch(id) } }

    /// The ACTIVE fact for exactly this kind, key and scope, or nil.
    public func lookup(_ kind: FactKind, key: String, scope: String = "") throws -> StoredFact? {
        let fact = try lookupLive(kind, key: key, scope: scope)
        return fact?.status == .active ? fact : nil
    }

    /// Like `lookup`, but candidates count too (for showing, never for acting).
    public func lookupLive(_ kind: FactKind, key: String, scope: String = "") throws -> StoredFact? {
        try locked {
            try liveFact(kind, TextRules.normaliseKey(key), TextRules.normaliseKey(scope), builtIn: false)
        }
    }

    public func allActive() throws -> [StoredFact] {
        try locked { try facts(where: "status = 'active' ORDER BY kind, key, id") }
    }

    public func allLive() throws -> [StoredFact] {
        try locked { try facts(where: "status != 'retired' ORDER BY kind, key, id") }
    }

    /// Every row for a key, newest first, retired ones included: the audit trail.
    public func history(key: String) throws -> [StoredFact] {
        try locked { try facts(where: "key = ? ORDER BY id DESC", [.text(TextRules.normaliseKey(key))]) }
    }

    /// Live facts used or offered in the last `seconds`, most recent first.
    public func recentlyUsed(within seconds: Double = MemoryLimits.recentWindowSeconds) throws -> [StoredFact] {
        try locked {
            let cutoff = now - seconds
            var seen = Set<Int64>()
            var result: [StoredFact] = []
            for entry in recent.reversed() where entry.at >= cutoff && !seen.contains(entry.id) {
                seen.insert(entry.id)
                if let fact = try fetch(entry.id), fact.status != .retired { result.append(fact) }
            }
            return result
        }
    }

    // MARK: - Episodes

    /// Records one finished task. Message wording is replaced by "[message]".
    @discardableResult
    public func logEpisode(goal: String, executor: String, status: String, summary: String, steps: Int,
                           seconds: Double) throws -> Int64 {
        let timestamp = now
        // Goal and summary are cleaned together, so a number one gives away is removed from both.
        let cleaned = HardRules.redactSecrets([MessageContent.redact(goal), MessageContent.redact(summary)])
            .map { TextRules.cleanValue($0, limit: 300) }
        return try locked {
            try database.transaction {
                let id = try database.execute(
                    "INSERT INTO episodes (goal, executor, status, summary, steps, seconds, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    [.text(cleaned[0]),
                     .text(String(executor.prefix(20))), .text(String(status.prefix(20))),
                     .text(cleaned[1]),
                     .integer(Int64(steps)), .real(seconds), .real(timestamp)])
                try database.execute(
                    "DELETE FROM episodes WHERE id NOT IN (SELECT id FROM episodes ORDER BY id DESC LIMIT ?)",
                    [.integer(Int64(MemoryLimits.maximumEpisodes))])
                return id
            }
        }
    }

    /// The newest episodes first.
    public func recentEpisodes(limit: Int = 5) throws -> [Episode] {
        try locked {
            try database.query(
                "SELECT goal, executor, status, summary, steps, seconds, created_at FROM episodes ORDER BY id DESC LIMIT ?",
                [.integer(Int64(limit))]
            ).map { row in
                Episode(goal: row["goal"]?.text ?? "", executor: row["executor"]?.text ?? "",
                        status: row["status"]?.text ?? "", summary: row["summary"]?.text ?? "",
                        steps: Int(row["steps"]?.integer ?? 0), seconds: (row["seconds"]?.real ?? 0),
                        at: Date(timeIntervalSince1970: row["created_at"]?.real ?? 0))
            }
        }
    }

    // MARK: - Internal

    func facts(where clause: String, _ parameters: [SQLiteValue] = []) throws -> [StoredFact] {
        try database.query("SELECT \(Self.columns) FROM facts WHERE \(clause)", parameters).map(Self.storedFact)
    }

    func fetch(_ id: Int64) throws -> StoredFact? { try facts(where: "id = ?", [.integer(id)]).first }

    private func requireFact(_ id: Int64) throws -> StoredFact {
        guard let fact = try fetch(id) else { throw SQLiteError(message: "fact \(id) vanished") }
        return fact
    }

    private func liveFact(_ kind: FactKind, _ key: String, _ scope: String, builtIn: Bool) throws -> StoredFact? {
        try facts(
            where: "kind = ? AND key = ? AND scope = ? AND status != 'retired' AND (source = 'builtIn') = ?",
            [.text(kind.rawValue), .text(key), .text(scope), .integer(builtIn ? 1 : 0)]
        ).first
    }

    private func retire(_ id: Int64, reason: String, at timestamp: Double) throws {
        try database.execute(
            "UPDATE facts SET status = 'retired', retired_at = ?, retired_reason = ?, updated_at = ? WHERE id = ?",
            [.real(timestamp), .text(reason), .real(timestamp), .integer(id)])
    }

    private func setStatus(_ id: Int64, _ status: FactStatus, at timestamp: Double) throws {
        try database.execute("UPDATE facts SET status = ?, updated_at = ? WHERE id = ?",
                             [.text(status.rawValue), .real(timestamp), .integer(id)])
    }

    private func updateExtras(_ id: Int64, _ change: (inout FactExtras) -> Void) throws {
        guard let row = try database.query("SELECT extra FROM facts WHERE id = ?", [.integer(id)]).first else { return }
        var extras = FactExtras.from(row["extra"]?.text ?? "{}")
        change(&extras)
        try database.execute("UPDATE facts SET extra = ? WHERE id = ?", [.text(extras.json), .integer(id)])
    }

    /// Seen again with the same value: count it, and promote it if it has earned that.
    private func reinforce(_ live: StoredFact, explicit: Bool, newValue: String, evidence: String,
                           at timestamp: Double) throws -> StoredFact {
        var status = live.status
        var source = live.source
        var confidence = live.confidence
        if explicit {
            status = .active
            source = .explicit
            confidence = max(confidence, MemoryLimits.explicitConfidence)
        } else if status == .candidate {
            status = .active  // the second sighting
            confidence = max(confidence + 0.2, MemoryLimits.promotedConfidence)
        } else {
            confidence += (1 - confidence) * MemoryLimits.useStep
        }
        // A recipe keeps its newest wording; other kinds keep the value they had.
        let value = live.kind == .recipe ? newValue : live.value
        try database.execute(
            """
            UPDATE facts SET value = ?, status = ?, source = ?, confidence = ?, sightings = sightings + 1,
                evidence = CASE WHEN ? = '' THEN evidence ELSE ? END, updated_at = ? WHERE id = ?
            """,
            [.text(value), .text(status.rawValue), .text(source.rawValue), .real(Self.clamp(confidence)),
             .text(evidence), .text(evidence), .real(timestamp), .integer(live.id)])
        return try requireFact(live.id)
    }

    private func noteRecent(_ id: Int64, at timestamp: Double) {
        recent.append((id, timestamp))
        if recent.count > 50 { recent.removeFirst(recent.count - 50) }
    }

    private func migrate() throws {
        let version = try database.query("PRAGMA user_version").first?["user_version"]?.integer ?? 0
        guard version < Self.schemaVersion else { return }
        try database.executeScript(
            """
            CREATE TABLE IF NOT EXISTS facts (
                id INTEGER PRIMARY KEY,
                kind TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL,
                scope TEXT NOT NULL DEFAULT '',
                status TEXT NOT NULL, source TEXT NOT NULL,
                confidence REAL NOT NULL, evidence TEXT NOT NULL DEFAULT '',
                uses INTEGER NOT NULL DEFAULT 0, sightings INTEGER NOT NULL DEFAULT 1,
                corrections INTEGER NOT NULL DEFAULT 0,
                successes INTEGER NOT NULL DEFAULT 0, failures INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL, updated_at REAL NOT NULL, last_used_at REAL NOT NULL DEFAULT 0,
                retired_at REAL, retired_reason TEXT,
                extra TEXT NOT NULL DEFAULT '{}'
            );
            -- At most one live fact per kind, key and scope, counted separately for built-in rows.
            CREATE UNIQUE INDEX IF NOT EXISTS facts_one_live
                ON facts (kind, key, scope, source = 'builtIn') WHERE status != 'retired';
            CREATE INDEX IF NOT EXISTS facts_key ON facts (key);
            CREATE TABLE IF NOT EXISTS episodes (
                id INTEGER PRIMARY KEY, goal TEXT NOT NULL, executor TEXT NOT NULL, status TEXT NOT NULL,
                summary TEXT NOT NULL, steps INTEGER NOT NULL, seconds REAL NOT NULL, created_at REAL NOT NULL
            );
            PRAGMA user_version = 1;
            """)
    }

    static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }

    static func storedFact(_ row: SQLiteRow) -> StoredFact {
        let extras = FactExtras.from(row["extra"]?.text ?? "{}")
        let lastUsed = row["last_used_at"]?.real ?? 0
        let fact = Fact(
            id: row["id"]?.integer ?? 0,
            kind: FactKind(rawValue: row["kind"]?.text ?? "") ?? .note,
            key: row["key"]?.text ?? "",
            value: row["value"]?.text ?? "",
            scope: row["scope"]?.text ?? "",
            status: FactStatus(rawValue: row["status"]?.text ?? "") ?? .retired,
            source: FactSource(rawValue: row["source"]?.text ?? "") ?? .learned,
            confidence: (row["confidence"]?.real ?? 0).rounded(toPlaces: 4),
            evidence: row["evidence"]?.text ?? "",
            useCount: Int(row["uses"]?.integer ?? 0),
            createdAt: Date(timeIntervalSince1970: row["created_at"]?.real ?? 0),
            lastUsedAt: lastUsed > 0 ? Date(timeIntervalSince1970: lastUsed) : nil)
        return StoredFact(
            fact: fact, label: extras.label ?? "", scopeLabel: extras.scopeLabel ?? "",
            sightings: Int(row["sightings"]?.integer ?? 1), corrections: Int(row["corrections"]?.integer ?? 0),
            successes: Int(row["successes"]?.integer ?? 0), failures: Int(row["failures"]?.integer ?? 0),
            updatedAt: Date(timeIntervalSince1970: row["updated_at"]?.real ?? 0),
            retiredReason: row["retired_reason"]?.optionalText,
            builtInID: extras.builtInID, builtInVersion: extras.version, matchAny: extras.matchAny ?? [],
            appNames: extras.appNames ?? [], notIf: extras.notIf ?? [], pitfalls: extras.pitfalls ?? [],
            needsReview: extras.needsReview ?? false)
    }

    /// File 0600, so only this macOS user can read the memory. A folder we create is made
    /// 0700 too; a folder that already exists is left as it is, because it may not be ours
    /// (the database file itself is still protected).
    static func preparePrivateFile(_ url: URL) throws {
        let fileManager = FileManager.default
        let folder = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: folder.path) {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        }
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw SpeakableError("I couldn't create my memory file.")
            }
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}
