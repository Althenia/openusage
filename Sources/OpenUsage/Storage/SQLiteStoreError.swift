import Foundation
import SQLite3

enum SQLiteStoreOperation: String, Sendable {
    case open
    case validate
    case read
    case write
    case transaction
    case permissions
}

enum SQLiteStoreError: Error, LocalizedError, Equatable, Sendable {
    case notConfigured
    case corrupt(code: Int32)
    case foreign
    case schemaTooNew(found: Int, supported: Int)
    case readOnly(code: Int32)
    case busy
    case nestedTransaction
    case invalidValue
    case io(operation: SQLiteStoreOperation, errno: Int32)
    case sqlite(operation: SQLiteStoreOperation, code: Int32)

    static func make(code: Int32, operation: SQLiteStoreOperation) -> SQLiteStoreError {
        switch code & 0xFF {
        case SQLITE_BUSY, SQLITE_LOCKED:
            return .busy
        case SQLITE_READONLY, SQLITE_PERM, SQLITE_AUTH, SQLITE_CANTOPEN:
            return .readOnly(code: code)
        case SQLITE_CORRUPT, SQLITE_NOTADB:
            return .corrupt(code: code)
        default:
            return .sqlite(operation: operation, code: code)
        }
    }

    var logDescription: String {
        switch self {
        case .notConfigured:
            return "storage is not configured"
        case .corrupt(let code):
            return "database is corrupt (sqlite code \(code))"
        case .foreign:
            return "database belongs to another application"
        case .schemaTooNew(let found, let supported):
            return "database schema v\(found) is newer than supported v\(supported)"
        case .readOnly(let code):
            return "database is not writable (sqlite code \(code))"
        case .busy:
            return "database is busy"
        case .nestedTransaction:
            return "transactions cannot be nested"
        case .invalidValue:
            return "value cannot be stored"
        case .io(let operation, let errno):
            return "file operation failed during \(operation.rawValue) (errno \(errno))"
        case .sqlite(let operation, let code):
            return "sqlite failure during \(operation.rawValue) (code \(code))"
        }
    }

    var errorDescription: String? {
        "OpenUsage storage problem: \(logDescription)."
    }
}
