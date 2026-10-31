import Darwin
import Foundation
import SQLite3

enum SQLiteStoreBootstrap {
    private struct Identity {
        var applicationID: Int32
        var version: Int
        var tableCount: Int64

        var isEmpty: Bool { applicationID == 0 && version == 0 && tableCount == 0 }
    }

    static func prepareDirectory(_ directory: String) throws -> String {
        var info = stat()
        var missing: [String] = []
        var current = directory
        while lstat(current, &info) != 0 {
            guard errno == ENOENT else { throw SQLiteStoreError.io(operation: .open, errno: errno) }
            missing.append(current)
            let parent = (current as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != current else {
                throw SQLiteStoreError.io(operation: .open, errno: EINVAL)
            }
            current = parent
        }
        for path in missing.reversed() {
            if mkdir(path, 0o700) != 0 && errno != EEXIST {
                throw SQLiteStoreError.io(operation: .open, errno: errno)
            }
        }
        guard lstat(directory, &info) == 0 else {
            throw SQLiteStoreError.io(operation: .validate, errno: errno)
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else {
            throw SQLiteStoreError.io(operation: .validate, errno: EPERM)
        }
        guard let resolved = realpath(directory, nil) else {
            throw SQLiteStoreError.io(operation: .validate, errno: errno)
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func validateExisting(_ connection: SQLiteConnection) throws {
        try connection.execute("BEGIN", operation: .validate)
        do {
            let identity = try readIdentity(connection, operation: .validate)
            if !identity.isEmpty {
                try validate(identity)
                guard try connection.text("PRAGMA quick_check(1)", operation: .validate) == "ok" else {
                    throw SQLiteStoreError.corrupt(code: SQLITE_CORRUPT)
                }
            }
        } catch {
            connection.rollback(operation: .validate)
            throw error
        }
        try connection.execute("COMMIT", operation: .validate)
    }

    static func createFileIfMissing(path: String) throws {
        let ownerOnly = mode_t(S_IRUSR | S_IWUSR)
        let descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, ownerOnly)
        if descriptor >= 0 {
            defer { Darwin.close(descriptor) }
            guard fchmod(descriptor, ownerOnly) == 0 else {
                throw SQLiteStoreError.io(operation: .permissions, errno: errno)
            }
            return
        }
        guard errno == EEXIST else { throw SQLiteStoreError.io(operation: .open, errno: errno) }
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw SQLiteStoreError.io(operation: .validate, errno: errno)
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw SQLiteStoreError.io(operation: .validate, errno: EINVAL)
        }
    }

    static func configure(_ connection: SQLiteConnection) throws {
        try connection.execute("BEGIN IMMEDIATE", operation: .open)
        do {
            let identity = try readIdentity(connection, operation: .open)
            if identity.isEmpty {
                try connection.execute(
                    """
                    CREATE TABLE entries (
                        namespace TEXT NOT NULL,
                        key TEXT NOT NULL,
                        value BLOB NOT NULL,
                        updated_at REAL NOT NULL,
                        PRIMARY KEY (namespace, key)
                    ) WITHOUT ROWID
                    """,
                    operation: .open
                )
                try connection.execute("PRAGMA application_id = \(SQLiteStore.applicationID)", operation: .open)
                try connection.execute("PRAGMA user_version = \(SQLiteStore.schemaVersion)", operation: .open)
            } else {
                try validate(identity)
            }
            try connection.execute("COMMIT", operation: .open)
        } catch {
            connection.rollback(operation: .open)
            throw error
        }

        try connection.execute("PRAGMA trusted_schema = OFF", operation: .open)
    }

    static func tightenPermissions(directory: String, databasePath: String) throws {
        try tighten(path: directory, mode: 0o700, optional: false)
        for suffix in ["", "-journal"] {
            try tighten(path: databasePath + suffix, mode: 0o600, optional: suffix != "")
        }
    }

    private static func tighten(path: String, mode: mode_t, optional: Bool) throws {
        var info = stat()
        guard stat(path, &info) == 0 else {
            if optional && errno == ENOENT { return }
            throw SQLiteStoreError.io(operation: .permissions, errno: errno)
        }
        guard info.st_mode & 0o777 != mode else { return }
        guard chmod(path, mode) == 0 else {
            throw SQLiteStoreError.io(operation: .permissions, errno: errno)
        }
    }

    private static func readIdentity(_ connection: SQLiteConnection, operation: SQLiteStoreOperation) throws -> Identity {
        let applicationID = try connection.integer("PRAGMA application_id", operation: operation)
        let version = try connection.integer("PRAGMA user_version", operation: operation)
        let tableCount = try connection.integer("SELECT count(*) FROM sqlite_master", operation: operation)
        return Identity(
            applicationID: Int32(truncatingIfNeeded: applicationID),
            version: Int(version),
            tableCount: tableCount
        )
    }

    private static func validate(_ identity: Identity) throws {
        guard identity.applicationID == SQLiteStore.applicationID else { throw SQLiteStoreError.foreign }
        guard identity.version <= SQLiteStore.schemaVersion else {
            throw SQLiteStoreError.schemaTooNew(found: identity.version, supported: SQLiteStore.schemaVersion)
        }
        guard identity.version == SQLiteStore.schemaVersion else { throw SQLiteStoreError.foreign }
    }
}
