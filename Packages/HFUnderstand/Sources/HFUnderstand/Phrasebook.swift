import Foundation
import HFCore

/// Where a phrasebook entry came from.
public enum PhrasebookSource: String, Sendable, Codable {
    /// The setup screen: the person said a phrase they were shown.
    case enrolment
    /// The person corrected a reading ("no, Sam").
    case correction
    /// The person said yes to a reading, or it went ahead and was not corrected.
    case confirmation
}

/// One "heard → meant" pair: what one recogniser heard, and what the person meant.
public struct PhrasebookEntry: Sendable, Equatable {
    public var id: Int64
    public var meant: String
    public var heard: String
    public var hearer: HearerName
    /// The clip, kept on one entry per turn (not copied onto every recogniser's entry).
    public var wav: Data?
    public var createdAt: Date
    public var timesConfirmed: Int
    public var lastConfirmedAt: Date
    public var source: PhrasebookSource
}

/// This person's own phrasebook: what recognisers heard when they spoke, and what they meant.
///
/// Stored on the Mac only, in its own SQLite file readable by this user alone, because
/// recordings of a disabled person's speech are health data. Thread-safe: every call runs
/// behind one lock. Matching, examples and keyterms are in PhrasebookMatching.swift.
public final class Phrasebook: @unchecked Sendable {
    /// Pairs not confirmed for this long count half as much. Speech changes over time in
    /// progressive conditions, so an old pair should not outvote a recent one.
    public static let halfLifeDays = 30.0

    let lock = NSLock()
    let database: PhrasebookDatabase
    let now: @Sendable () -> Date

    /// Opens (or creates) the phrasebook file at `path`. `now` is for tests.
    ///
    /// The folder is made readable by this user only (0700) and the file (0600) **before**
    /// SQLite opens it, so the recordings are never readable by anyone else, not even for a
    /// moment. If that cannot be done, this throws and nothing is stored.
    public init(path: URL, now: @escaping @Sendable () -> Date = Date.init) throws {
        try Self.preparePrivateFile(at: path)
        database = try PhrasebookDatabase(path: path.path)
        self.now = now
        try createTables()
    }

    static func preparePrivateFile(at path: URL) throws {
        let files = FileManager.default
        let folder = path.deletingLastPathComponent().path
        let refused = SpeakableError("I couldn't keep your speech examples private, so I won't store them.")
        do {
            try files.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder)
            if !files.fileExists(atPath: path.path) {
                guard files.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw refused }
            }
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        } catch {
            throw refused
        }
        let filePermissions = (try? files.attributesOfItem(atPath: path.path))?[.posixPermissions] as? Int
        let folderPermissions = (try? files.attributesOfItem(atPath: folder))?[.posixPermissions] as? Int
        guard filePermissions == 0o600, folderPermissions == 0o700 else { throw refused }
    }

    private init(memoryWithClock now: @escaping @Sendable () -> Date) throws {
        database = try PhrasebookDatabase(path: ":memory:")
        self.now = now
        try createTables()
    }

    /// A phrasebook that lives in memory only: for tests and the evaluation.
    public static func inMemory(now: @escaping @Sendable () -> Date = Date.init) throws -> Phrasebook {
        try Phrasebook(memoryWithClock: now)
    }

    private func createTables() throws {
        // `heard_key` and `meant_key` are the normalised texts, so "Call Sam." and "call sam"
        // are one pair.
        try database.executeScript("""
            CREATE TABLE IF NOT EXISTS entries (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                meant TEXT NOT NULL, meant_key TEXT NOT NULL,
                heard TEXT NOT NULL, heard_key TEXT NOT NULL,
                hearer TEXT NOT NULL, wav BLOB,
                created_at REAL NOT NULL, times_confirmed INTEGER NOT NULL,
                last_confirmed_at REAL NOT NULL, source TEXT NOT NULL,
                UNIQUE (heard_key, meant_key, hearer)
            );
            CREATE INDEX IF NOT EXISTS entries_meant ON entries (meant_key);
            """)
    }

    /// Adds a pair, or, when the same recogniser has heard the same thing for the same meaning
    /// before, counts one more confirmation (and keeps the newer clip if one is given).
    public func add(heard: String, meant: String, hearer: HearerName, wav: Data? = nil, source: PhrasebookSource) throws {
        let heardKey = SpeechText.normalise(heard), meantKey = SpeechText.normalise(meant)
        guard !heardKey.isEmpty, !meantKey.isEmpty else { return }
        let time = now().timeIntervalSince1970
        lock.lock()
        defer { lock.unlock() }
        let changed = try database.execute(
            """
            UPDATE entries SET times_confirmed = times_confirmed + 1, last_confirmed_at = ?,
                wav = COALESCE(?, wav), meant = ?
            WHERE heard_key = ? AND meant_key = ? AND hearer = ?
            """,
            [.real(time), wav.map { .blob($0) } ?? .null, .text(meant), .text(heardKey), .text(meantKey), .text(hearer.rawValue)])
        if changed > 0 { return }
        try database.execute(
            """
            INSERT INTO entries (meant, meant_key, heard, heard_key, hearer, wav, created_at,
                times_confirmed, last_confirmed_at, source)
            VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
            """,
            [.text(meant), .text(meantKey), .text(heard), .text(heardKey), .text(hearer.rawValue),
             wav.map { .blob($0) } ?? .null, .real(time), .real(time), .text(source.rawValue)])
    }

    /// Removes every pair for this meaning, clips included. Returns how many were removed.
    @discardableResult
    public func forget(meant: String) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        return try database.execute("DELETE FROM entries WHERE meant_key = ?", [.text(SpeechText.normalise(meant))])
    }

    /// How many pairs are stored.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return Int((try? database.query("SELECT COUNT(*) AS total FROM entries"))?.first?["total"]?.integer ?? 0)
    }

    /// Every entry, newest first. For the panel and for tests; clips included only when asked.
    public func entries(includingAudio: Bool = false) throws -> [PhrasebookEntry] {
        lock.lock()
        defer { lock.unlock() }
        let columns = includingAudio ? "*" : "id, meant, heard, hearer, created_at, times_confirmed, last_confirmed_at, source"
        return try database.query("SELECT \(columns) FROM entries ORDER BY last_confirmed_at DESC, id DESC").map(Self.entry)
    }

    static func entry(_ row: PhrasebookRow) -> PhrasebookEntry {
        PhrasebookEntry(
            id: row["id"]?.integer ?? 0,
            meant: row["meant"]?.text ?? "",
            heard: row["heard"]?.text ?? "",
            hearer: HearerName(rawValue: row["hearer"]?.text ?? "") ?? .scribe,
            wav: row["wav"]?.blob,
            createdAt: Date(timeIntervalSince1970: row["created_at"]?.real ?? 0),
            timesConfirmed: Int(row["times_confirmed"]?.integer ?? 0),
            lastConfirmedAt: Date(timeIntervalSince1970: row["last_confirmed_at"]?.real ?? 0),
            source: PhrasebookSource(rawValue: row["source"]?.text ?? "") ?? .confirmation)
    }

    /// 1 for now, 0.5 after one half-life, 0.25 after two.
    func recencyWeight(_ date: Date) -> Double {
        let days = max(0, now().timeIntervalSince(date) / 86_400)
        return pow(0.5, days / Self.halfLifeDays)
    }
}
