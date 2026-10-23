import Foundation
import SQLite3

nonisolated enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

nonisolated protocol SQLBindable {
    var sqlValue: SQLValue { get }
}
nonisolated extension Int: SQLBindable { var sqlValue: SQLValue { .int(Int64(self)) } }
nonisolated extension Int64: SQLBindable { var sqlValue: SQLValue { .int(self) } }
nonisolated extension Bool: SQLBindable { var sqlValue: SQLValue { .int(self ? 1 : 0) } }
nonisolated extension Double: SQLBindable { var sqlValue: SQLValue { .double(self) } }
nonisolated extension String: SQLBindable { var sqlValue: SQLValue { .text(self) } }
nonisolated extension Data: SQLBindable { var sqlValue: SQLValue { .blob(self) } }
nonisolated extension Date: SQLBindable { var sqlValue: SQLValue { .double(timeIntervalSince1970) } }
nonisolated extension SQLValue: SQLBindable { var sqlValue: SQLValue { self } }
nonisolated extension Optional: SQLBindable where Wrapped: SQLBindable {
    var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

nonisolated struct SQLRow: Sendable {
    let values: [String: SQLValue]

    func string(_ k: String) -> String? {
        switch values[k] {
        case .text(let s): s
        case .int(let i): String(i)
        default: nil
        }
    }
    func int(_ k: String) -> Int? {
        switch values[k] {
        case .int(let i): Int(i)
        case .double(let d): Int(d)
        default: nil
        }
    }
    func bool(_ k: String) -> Bool { (int(k) ?? 0) != 0 }
    func double(_ k: String) -> Double? {
        switch values[k] {
        case .double(let d): d
        case .int(let i): Double(i)
        default: nil
        }
    }
    func date(_ k: String) -> Date? { double(k).map { Date(timeIntervalSince1970: $0) } }
    func data(_ k: String) -> Data? {
        switch values[k] {
        case .blob(let d): d
        case .text(let s): Data(s.utf8)
        default: nil
        }
    }
    func json<T: Decodable>(_ k: String, as: T.Type) -> T? {
        guard let d = data(k) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
}

nonisolated struct DatabaseError: Error, CustomStringConvertible {
    let code: Int32
    let message: String
    var description: String { "SQLite \(code): \(message)" }
}

/// Minimal thread-safe wrapper over the system SQLite library.
/// All access is serialized with a lock; callers live on the `MailStore` actor.
nonisolated final class Database: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()

    init(path: String) throws {
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            throw DatabaseError(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
        }
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA busy_timeout = 3000")
    }

    /// In-memory database for tests.
    convenience init() throws { try self.init(path: ":memory:") }

    deinit { sqlite3_close_v2(handle) }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ sql: String, _ params: [SQLBindable]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { throw lastError() }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p.sqlValue {
            case .null: sqlite3_bind_null(stmt, idx)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            case .blob(let v):
                _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), Self.transient) }
            }
        }
        return stmt
    }

    private func lastError() -> DatabaseError {
        DatabaseError(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
    }

    @discardableResult
    func execute(_ sql: String, _ params: [SQLBindable] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        if params.isEmpty && sql.contains(";") {
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
            return Int(sqlite3_changes(handle))
        }
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW { rc = sqlite3_step(stmt) }
        guard rc == SQLITE_DONE else { throw lastError() }
        return Int(sqlite3_changes(handle))
    }

    func query(_ sql: String, _ params: [SQLBindable] = []) throws -> [SQLRow] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var rows: [SQLRow] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw lastError() }
            var values: [String: SQLValue] = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: values[name] = .int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: values[name] = .double(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT: values[name] = .text(String(cString: sqlite3_column_text(stmt, c)))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, c))
                    values[name] = .blob(n > 0 ? Data(bytes: sqlite3_column_blob(stmt, c), count: n) : Data())
                default: values[name] = .null
                }
            }
            rows.append(SQLRow(values: values))
        }
        return rows
    }

    private var transactionDepth = 0

    /// Runs `body` atomically. Nested calls become savepoints.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let savepoint = "sp\(transactionDepth)"
        try execute(transactionDepth == 0 ? "BEGIN IMMEDIATE" : "SAVEPOINT \(savepoint)")
        transactionDepth += 1
        do {
            let result = try body()
            transactionDepth -= 1
            try execute(transactionDepth == 0 ? "COMMIT" : "RELEASE \(savepoint)")
            return result
        } catch {
            transactionDepth -= 1
            if transactionDepth == 0 { try? execute("ROLLBACK") } else {
                try? execute("ROLLBACK TO \(savepoint)")
                try? execute("RELEASE \(savepoint)")
            }
            throw error
        }
    }

    var userVersion: Int {
        get { (try? query("PRAGMA user_version").first?.int("user_version")) ?? 0 }
        set { _ = try? execute("PRAGMA user_version = \(newValue)") }
    }
}

nonisolated enum JSON {
    static func encode<T: Encodable>(_ value: T) -> String {
        (try? String(decoding: JSONEncoder().encode(value), as: UTF8.self)) ?? "null"
    }
}
