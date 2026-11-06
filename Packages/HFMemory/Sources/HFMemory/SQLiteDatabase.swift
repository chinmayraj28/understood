import Foundation
import SQLite3

/// A value bound to, or read from, a SQLite statement.
enum SQLiteValue: Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)

    var text: String { if case .text(let value) = self { return value } else { return "" } }
    var integer: Int64 {
        switch self {
        case .integer(let value): return value
        case .real(let value): return Int64(value)
        default: return 0
        }
    }
    var real: Double {
        switch self {
        case .real(let value): return value
        case .integer(let value): return Double(value)
        default: return 0
        }
    }
    var optionalReal: Double? { self == .null ? nil : real }
    var optionalText: String? { self == .null ? nil : text }
}

/// One row of a query result, by column name.
typealias SQLiteRow = [String: SQLiteValue]

/// Something went wrong inside SQLite. Never shown to the user as is.
struct SQLiteError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// The thinnest useful wrapper over the system SQLite library.
///
/// Not thread-safe on its own: `MemoryStore` serialises every call behind one lock.
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    /// Tells SQLite to copy bound strings, because Swift may free them before the statement runs.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &handle, flags, nil) != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(handle)
            handle = nil
            throw SQLiteError(message: "open failed: \(message)")
        }
        sqlite3_busy_timeout(handle, 2000)
    }

    deinit { close() }

    func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    var isOpen: Bool { handle != nil }

    /// Runs one or more statements that take no parameters and return no rows.
    func executeScript(_ sql: String) throws {
        guard let handle else { throw SQLiteError(message: "database is closed") }
        var errorPointer: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &errorPointer) != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errorPointer)
            throw SQLiteError(message: message)
        }
    }

    /// Runs one statement with parameters. Returns the rowid of the last insert.
    @discardableResult
    func execute(_ sql: String, _ parameters: [SQLiteValue] = []) throws -> Int64 {
        _ = try query(sql, parameters)
        return sqlite3_last_insert_rowid(handle)
    }

    /// Runs one statement with parameters and returns every row.
    func query(_ sql: String, _ parameters: [SQLiteValue] = []) throws -> [SQLiteRow] {
        guard let handle else { throw SQLiteError(message: "database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError(message: "prepare failed: \(String(cString: sqlite3_errmsg(handle)))")
        }
        defer { sqlite3_finalize(statement) }
        for (offset, parameter) in parameters.enumerated() {
            let index = Int32(offset + 1)
            switch parameter {
            case .null: sqlite3_bind_null(statement, index)
            case .integer(let value): sqlite3_bind_int64(statement, index, value)
            case .real(let value): sqlite3_bind_double(statement, index, value)
            case .text(let value): sqlite3_bind_text(statement, index, value, -1, Self.transient)
            }
        }
        var rows: [SQLiteRow] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw SQLiteError(message: "step failed: \(String(cString: sqlite3_errmsg(handle)))")
            }
            var row: SQLiteRow = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(statement, column))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(statement, column)))
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    /// Runs `body` inside BEGIN IMMEDIATE ... COMMIT, rolling back if it throws.
    /// Nested calls join the outer transaction.
    func transaction<Result>(_ body: () throws -> Result) throws -> Result {
        guard let handle else { throw SQLiteError(message: "database is closed") }
        if sqlite3_get_autocommit(handle) == 0 { return try body() }  // already inside one
        try executeScript("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try executeScript("COMMIT")
            return result
        } catch {
            try? executeScript("ROLLBACK")
            throw error
        }
    }
}
