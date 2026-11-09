import Foundation
import SQLite3

// The thinnest useful wrapper over the system SQLite library, copied from HFMemory's
// SQLiteDatabase (packages depend only on HFCore, so it is copied rather than imported),
// with one addition: blobs, because the phrasebook keeps short audio clips.

/// A value bound to, or read from, a SQLite statement.
enum PhrasebookValue: Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

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
    var blob: Data? { if case .blob(let value) = self { return value } else { return nil } }
}

/// One row of a query result, by column name.
typealias PhrasebookRow = [String: PhrasebookValue]

/// Something went wrong inside SQLite. Never shown to the user as is.
struct PhrasebookDatabaseError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// Not thread-safe on its own: `Phrasebook` serialises every call behind one lock.
final class PhrasebookDatabase {
    private var handle: OpaquePointer?

    /// Tells SQLite to copy bound strings and bytes, because Swift may free them before the statement runs.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &handle, flags, nil) != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(handle)
            handle = nil
            throw PhrasebookDatabaseError(message: "open failed: \(message)")
        }
        sqlite3_busy_timeout(handle, 2000)
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    /// Runs one or more statements that take no parameters and return no rows.
    func executeScript(_ sql: String) throws {
        guard let handle else { throw PhrasebookDatabaseError(message: "database is closed") }
        var errorPointer: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &errorPointer) != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errorPointer)
            throw PhrasebookDatabaseError(message: message)
        }
    }

    /// Runs one statement with parameters. Returns how many rows it changed.
    @discardableResult
    func execute(_ sql: String, _ parameters: [PhrasebookValue] = []) throws -> Int {
        _ = try query(sql, parameters)
        return Int(sqlite3_changes(handle))
    }

    /// Runs one statement with parameters and returns every row.
    func query(_ sql: String, _ parameters: [PhrasebookValue] = []) throws -> [PhrasebookRow] {
        guard let handle else { throw PhrasebookDatabaseError(message: "database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw PhrasebookDatabaseError(message: "prepare failed: \(String(cString: sqlite3_errmsg(handle)))")
        }
        defer { sqlite3_finalize(statement) }
        for (offset, parameter) in parameters.enumerated() {
            let index = Int32(offset + 1)
            switch parameter {
            case .null: sqlite3_bind_null(statement, index)
            case .integer(let value): sqlite3_bind_int64(statement, index, value)
            case .real(let value): sqlite3_bind_double(statement, index, value)
            case .text(let value): sqlite3_bind_text(statement, index, value, -1, Self.transient)
            case .blob(let value):
                // An empty Data has no base address; SQLite stores a zero-length blob for it.
                _ = value.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), Self.transient)
                }
            }
        }
        var rows: [PhrasebookRow] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw PhrasebookDatabaseError(message: "step failed: \(String(cString: sqlite3_errmsg(handle)))")
            }
            var row: PhrasebookRow = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(statement, column))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(statement, column)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    if let bytes = sqlite3_column_blob(statement, column), count > 0 {
                        row[name] = .blob(Data(bytes: bytes, count: count))
                    } else {
                        row[name] = .blob(Data())
                    }
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }
}
