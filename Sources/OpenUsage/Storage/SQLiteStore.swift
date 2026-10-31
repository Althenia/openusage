import Foundation
import SQLite3

final class SQLiteStore: @unchecked Sendable {
    static let applicationID: Int32 = 0x4F55_5347
    static let schemaVersion = 1

    private let connection: SQLiteConnection
    private let lock = NSRecursiveLock()
    private var depth = 0

    init(url: URL, busyTimeout: TimeInterval = 1.5) throws {
        let directory = try SQLiteStoreBootstrap.prepareDirectory(url.deletingLastPathComponent().path)
        let path = (directory as NSString).appendingPathComponent(url.lastPathComponent)
        try SQLiteStoreBootstrap.createFileIfMissing(path: path)
        connection = try SQLiteConnection(path: path, busyTimeout: busyTimeout, operation: .open)
        try SQLiteStoreBootstrap.validateExisting(connection)
        try SQLiteStoreBootstrap.tightenPermissions(directory: directory, databasePath: path)
        try SQLiteStoreBootstrap.configure(connection)
        try SQLiteStoreBootstrap.tightenPermissions(directory: directory, databasePath: path)
    }

    var isInTransaction: Bool {
        lock.lock()
        defer { lock.unlock() }
        return depth > 0
    }

    func data(namespace: String, key: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        var result: Data?
        try connection.run(
            "SELECT value FROM entries WHERE namespace = ?1 AND key = ?2",
            bindings: [.text(namespace), .text(key)],
            operation: .read
        ) { result = SQLiteConnection.blob(in: $0, column: 0) }
        return result
    }

    func set(_ data: Data, namespace: String, key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try connection.run(
            "INSERT OR REPLACE INTO entries (namespace, key, value, updated_at) VALUES (?1, ?2, ?3, ?4)",
            bindings: [.text(namespace), .text(key), .blob(data), .real(Date().timeIntervalSince1970)],
            operation: .write
        )
    }

    func remove(namespace: String, key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try connection.run(
            "DELETE FROM entries WHERE namespace = ?1 AND key = ?2",
            bindings: [.text(namespace), .text(key)],
            operation: .write
        )
    }

    func removeNamespace(_ namespace: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try connection.run(
            "DELETE FROM entries WHERE namespace = ?1",
            bindings: [.text(namespace)],
            operation: .write
        )
    }

    func keys(namespace: String) throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var result: [String] = []
        try connection.run(
            "SELECT key FROM entries WHERE namespace = ?1 ORDER BY key",
            bindings: [.text(namespace)],
            operation: .read
        ) { statement in
            if let key = SQLiteConnection.text(in: statement, column: 0) { result.append(key) }
        }
        return result
    }

    func namespaces(prefix: String) throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var result: [String] = []
        try connection.run(
            """
            SELECT DISTINCT namespace FROM entries
            WHERE substr(CAST(namespace AS BLOB), 1, ?1) = CAST(?2 AS BLOB)
            ORDER BY namespace
            """,
            bindings: [.integer(Int64(prefix.utf8.count)), .text(prefix)],
            operation: .read
        ) { statement in
            if let namespace = SQLiteConnection.text(in: statement, column: 0) { result.append(namespace) }
        }
        return result
    }

    func modifiedAt(namespace: String, key: String) throws -> Date? {
        lock.lock()
        defer { lock.unlock() }
        var result: Date?
        try connection.run(
            "SELECT updated_at FROM entries WHERE namespace = ?1 AND key = ?2",
            bindings: [.text(namespace), .text(key)],
            operation: .read
        ) { result = Date(timeIntervalSince1970: sqlite3_column_double($0, 0)) }
        return result
    }

    func transaction<T>(_ body: (SQLiteStore) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard depth == 0 else { throw SQLiteStoreError.nestedTransaction }
        try connection.execute("BEGIN IMMEDIATE", operation: .transaction)
        depth = 1
        defer { depth = 0 }
        do {
            let result = try body(self)
            try connection.execute("COMMIT", operation: .transaction)
            return result
        } catch {
            connection.rollback(operation: .transaction)
            throw error
        }
    }
}
