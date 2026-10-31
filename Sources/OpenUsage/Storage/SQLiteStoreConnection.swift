import Foundation
import SQLite3

enum SQLiteBinding {
    case text(String)
    case blob(Data)
    case real(Double)
    case integer(Int64)
}

final class SQLiteConnection {
    private var handle: OpaquePointer?

    init(path: String, busyTimeout: TimeInterval, operation: SQLiteStoreOperation) throws {
        let flags: Int32 = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_EXRESCODE
        var opened: OpaquePointer?
        let code = sqlite3_open_v2(path, &opened, flags, nil)
        handle = opened
        guard code == SQLITE_OK else {
            close()
            throw SQLiteStoreError.make(code: code, operation: operation)
        }
        let milliseconds = min(max(busyTimeout, 0) * 1000, Double(Int32.max))
        sqlite3_busy_timeout(opened, Int32(milliseconds))
    }

    deinit {
        close()
    }

    func close() {
        if let handle {
            sqlite3_close(handle)
            self.handle = nil
        }
    }

    func execute(_ sql: String, operation: SQLiteStoreOperation) throws {
        let code = sqlite3_exec(handle, sql, nil, nil, nil)
        guard code == SQLITE_OK else {
            throw SQLiteStoreError.make(code: code, operation: operation)
        }
    }

    func rollback(operation: SQLiteStoreOperation) {
        do {
            try execute("ROLLBACK", operation: operation)
        } catch {
            let description = (error as? SQLiteStoreError)?.logDescription ?? "unknown failure"
            AppLog.error(.config, "storage rollback failed, connection closed: \(description)")
            close()
        }
    }

    func run(
        _ sql: String,
        bindings: [SQLiteBinding] = [],
        operation: SQLiteStoreOperation,
        row: (OpaquePointer) throws -> Void = { _ in }
    ) throws {
        var prepared: OpaquePointer?
        var code = sqlite3_prepare_v2(handle, sql, -1, &prepared, nil)
        guard code == SQLITE_OK, let statement = prepared else {
            sqlite3_finalize(prepared)
            throw SQLiteStoreError.make(code: code, operation: operation)
        }
        defer { sqlite3_finalize(statement) }

        for (offset, binding) in bindings.enumerated() {
            code = bind(binding, at: Int32(offset + 1), in: statement)
            guard code == SQLITE_OK else {
                throw SQLiteStoreError.make(code: code, operation: operation)
            }
        }

        while true {
            code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                try row(statement)
            } else if code == SQLITE_DONE {
                return
            } else {
                throw SQLiteStoreError.make(code: code, operation: operation)
            }
        }
    }

    func integer(_ sql: String, operation: SQLiteStoreOperation) throws -> Int64 {
        var value: Int64 = 0
        try run(sql, operation: operation) { value = sqlite3_column_int64($0, 0) }
        return value
    }

    func text(_ sql: String, operation: SQLiteStoreOperation) throws -> String? {
        var value: String?
        try run(sql, operation: operation) { value = Self.text(in: $0, column: 0) }
        return value
    }

    static func text(in statement: OpaquePointer, column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    static func blob(in statement: OpaquePointer, column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private func bind(_ binding: SQLiteBinding, at index: Int32, in statement: OpaquePointer) -> Int32 {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        switch binding {
        case .text(let value):
            return sqlite3_bind_text(statement, index, value, -1, transient)
        case .blob(let value):
            guard !value.isEmpty else { return sqlite3_bind_zeroblob(statement, index, 0) }
            return value.withUnsafeBytes {
                sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient)
            }
        case .real(let value):
            return sqlite3_bind_double(statement, index, value)
        case .integer(let value):
            return sqlite3_bind_int64(statement, index, value)
        }
    }
}
