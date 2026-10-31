import Foundation
import XCTest
@testable import OpenUsage

final class SQLiteStoreTests: XCTestCase {
    private struct Probe: Error {}

    private var directory: URL!

    private var databaseURL: URL { directory.appendingPathComponent("store.db") }

    override func setUpWithError() throws {
        directory = try StorageTestDirectory.make()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testFreshStoreCreatesDatabaseAtVersionOneInMissingDirectories() throws {
        let nested = directory.appendingPathComponent("a/b/store.db")

        _ = try SQLiteStore(url: nested)

        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
        let connection = try RawSQLiteConnection(url: nested, readOnly: true)
        XCTAssertEqual(try connection.userVersion(), 1)
    }

    func testFreshDatabaseUsesRollbackJournalDeleteModeWithoutSidecars() throws {
        let store = try SQLiteStore(url: databaseURL)
        try store.set(Data("value".utf8), namespace: "app", key: "key")

        let connection = try RawSQLiteConnection(url: databaseURL, readOnly: true)
        XCTAssertEqual(try connection.scalarText("PRAGMA journal_mode")?.lowercased(), "delete")
        XCTAssertEqual(Set(try DatabaseFiles.bytes(of: databaseURL).keys), ["store.db"])
    }

    func testDatabaseAndCreatedDirectoryAreOwnerOnly() throws {
        let nested = directory.appendingPathComponent("private/store.db")
        let store = try SQLiteStore(url: nested)
        try store.set(Data("value".utf8), namespace: "app", key: "key")

        XCTAssertEqual(try DatabaseFiles.permissions(of: nested.deletingLastPathComponent()) & 0o077, 0)
        for name in try DatabaseFiles.bytes(of: nested).keys {
            let url = nested.deletingLastPathComponent().appendingPathComponent(name)
            XCTAssertEqual(try DatabaseFiles.permissions(of: url) & 0o077, 0, name)
        }
    }

    func testDataRoundTripsAndOverwrites() throws {
        let store = try SQLiteStore(url: databaseURL)
        let binary = Data((0...255).map { UInt8($0) })

        try store.set(binary, namespace: "app", key: "blob")
        XCTAssertEqual(try store.data(namespace: "app", key: "blob"), binary)

        try store.set(Data("replacement".utf8), namespace: "app", key: "blob")
        XCTAssertEqual(try store.data(namespace: "app", key: "blob"), Data("replacement".utf8))
    }

    func testEmptyBlobIsStoredAndDistinctFromAbsent() throws {
        let store = try SQLiteStore(url: databaseURL)

        XCTAssertNil(try store.data(namespace: "app", key: "empty"))
        try store.set(Data(), namespace: "app", key: "empty")

        XCTAssertEqual(try store.data(namespace: "app", key: "empty"), Data())
        XCTAssertEqual(try store.keys(namespace: "app"), ["empty"])
    }

    func testSameKeyInDifferentNamespacesIsIsolated() throws {
        let store = try SQLiteStore(url: databaseURL)

        try store.set(Data("app".utf8), namespace: "app", key: "shared")
        try store.set(Data("telemetry".utf8), namespace: "telemetry", key: "shared")

        XCTAssertEqual(try store.data(namespace: "app", key: "shared"), Data("app".utf8))
        XCTAssertEqual(try store.data(namespace: "telemetry", key: "shared"), Data("telemetry".utf8))
    }

    func testKeysListsOnlyTheRequestedNamespace() throws {
        let store = try SQLiteStore(url: databaseURL)
        try store.set(Data("1".utf8), namespace: "app", key: "one")
        try store.set(Data("2".utf8), namespace: "app", key: "two")
        try store.set(Data("3".utf8), namespace: "other", key: "three")

        XCTAssertEqual(Set(try store.keys(namespace: "app")), ["one", "two"])
        XCTAssertEqual(try store.keys(namespace: "missing"), [])
    }

    func testNamespacesFilterByLiteralPrefix() throws {
        let store = try SQLiteStore(url: databaseURL)
        for namespace in ["log-scan/a", "log-scan/b", "app", "log_scan/x", "logXscan/y", "100%/z", "100abc/z"] {
            try store.set(Data("v".utf8), namespace: namespace, key: "k")
        }

        XCTAssertEqual(Set(try store.namespaces(prefix: "log-scan/")), ["log-scan/a", "log-scan/b"])
        XCTAssertEqual(Set(try store.namespaces(prefix: "log_")), ["log_scan/x"])
        XCTAssertEqual(Set(try store.namespaces(prefix: "100%")), ["100%/z"])
        XCTAssertEqual(Set(try store.namespaces(prefix: "")), [
            "log-scan/a", "log-scan/b", "app", "log_scan/x", "logXscan/y", "100%/z", "100abc/z"
        ])
    }

    func testRemoveKeyLeavesSiblingsAndOtherNamespaces() throws {
        let store = try SQLiteStore(url: databaseURL)
        try store.set(Data("1".utf8), namespace: "app", key: "one")
        try store.set(Data("2".utf8), namespace: "app", key: "two")
        try store.set(Data("3".utf8), namespace: "other", key: "one")

        try store.remove(namespace: "app", key: "one")

        XCTAssertNil(try store.data(namespace: "app", key: "one"))
        XCTAssertEqual(try store.data(namespace: "app", key: "two"), Data("2".utf8))
        XCTAssertEqual(try store.data(namespace: "other", key: "one"), Data("3".utf8))
        try store.remove(namespace: "app", key: "never-existed")
    }

    func testRemoveNamespaceOnlyRemovesThatExactNamespace() throws {
        let store = try SQLiteStore(url: databaseURL)
        try store.set(Data("1".utf8), namespace: "app", key: "one")
        try store.set(Data("2".utf8), namespace: "app", key: "two")
        try store.set(Data("3".utf8), namespace: "app2", key: "one")
        try store.set(Data("4".utf8), namespace: "telemetry", key: "installID")

        try store.removeNamespace("app")

        XCTAssertEqual(try store.keys(namespace: "app"), [])
        XCTAssertEqual(try store.data(namespace: "app2", key: "one"), Data("3".utf8))
        XCTAssertEqual(try store.data(namespace: "telemetry", key: "installID"), Data("4".utf8))
    }

    func testModifiedAtTracksWritesAndRemoval() throws {
        let store = try SQLiteStore(url: databaseURL)
        XCTAssertNil(try store.modifiedAt(namespace: "app", key: "key"))

        let before = Date()
        try store.set(Data("1".utf8), namespace: "app", key: "key")
        let first = try XCTUnwrap(try store.modifiedAt(namespace: "app", key: "key"))
        XCTAssertGreaterThanOrEqual(first.timeIntervalSince(before), -2)
        XCTAssertLessThanOrEqual(first.timeIntervalSince(Date()), 2)

        try store.set(Data("2".utf8), namespace: "app", key: "key")
        let second = try XCTUnwrap(try store.modifiedAt(namespace: "app", key: "key"))
        XCTAssertGreaterThanOrEqual(second, first)

        try store.remove(namespace: "app", key: "key")
        XCTAssertNil(try store.modifiedAt(namespace: "app", key: "key"))
    }

    func testTransactionCommitsAllWritesAndReturnsClosureValue() throws {
        let store = try SQLiteStore(url: databaseURL)

        let result = try store.transaction { transactional -> Int in
            try transactional.set(Data("1".utf8), namespace: "app", key: "one")
            try transactional.set(Data("2".utf8), namespace: "app", key: "two")
            return 42
        }

        XCTAssertEqual(result, 42)
        XCTAssertEqual(Set(try store.keys(namespace: "app")), ["one", "two"])
    }

    func testThrowingTransactionRollsBackSetsAndRemovals() throws {
        let store = try SQLiteStore(url: databaseURL)
        try store.set(Data("keep".utf8), namespace: "app", key: "existing")

        XCTAssertThrowsError(try store.transaction { transactional in
            try transactional.set(Data("new".utf8), namespace: "app", key: "added")
            try transactional.set(Data("changed".utf8), namespace: "app", key: "existing")
            try transactional.removeNamespace("other")
            throw Probe()
        }) { XCTAssertTrue($0 is Probe) }

        XCTAssertNil(try store.data(namespace: "app", key: "added"))
        XCTAssertEqual(try store.data(namespace: "app", key: "existing"), Data("keep".utf8))
    }

    func testRolledBackRemovalRestoresRows() throws {
        let store = try SQLiteStore(url: databaseURL)
        try store.set(Data("1".utf8), namespace: "app", key: "one")

        XCTAssertThrowsError(try store.transaction { transactional in
            try transactional.removeNamespace("app")
            XCTAssertEqual(try transactional.keys(namespace: "app"), [])
            throw Probe()
        })

        XCTAssertEqual(try store.data(namespace: "app", key: "one"), Data("1".utf8))
    }

    func testNestedTransactionIsRejectedAndTheOuterTransactionRollsBack() throws {
        let store = try SQLiteStore(url: databaseURL)

        XCTAssertThrowsError(try store.transaction { outer in
            try outer.set(Data("outer".utf8), namespace: "app", key: "outer")
            try outer.transaction { inner in
                try inner.set(Data("inner".utf8), namespace: "app", key: "inner")
            }
        }) { error in
            guard case .nestedTransaction? = error as? SQLiteStoreError else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try store.keys(namespace: "app"), [])
    }

    func testUncommittedTransactionIsInvisibleToAnotherConnection() throws {
        let store = try SQLiteStore(url: databaseURL)
        let other = try SQLiteStore(url: databaseURL)

        try store.transaction { transactional in
            try transactional.set(Data("pending".utf8), namespace: "app", key: "key")
            XCTAssertNil(try other.data(namespace: "app", key: "key"))
        }

        XCTAssertEqual(try other.data(namespace: "app", key: "key"), Data("pending".utf8))
    }

    func testReopenedStoreSeesPersistedValues() throws {
        do {
            let store = try SQLiteStore(url: databaseURL)
            try store.set(Data("persisted".utf8), namespace: "app", key: "key")
        }

        let reopened = try SQLiteStore(url: databaseURL)

        XCTAssertEqual(try reopened.data(namespace: "app", key: "key"), Data("persisted".utf8))
        let connection = try RawSQLiteConnection(url: databaseURL, readOnly: true)
        XCTAssertEqual(try connection.userVersion(), 1)
    }

    func testTwoConnectionsSeeEachOthersCommittedWrites() throws {
        let first = try SQLiteStore(url: databaseURL)
        let second = try SQLiteStore(url: databaseURL)

        try first.set(Data("from-first".utf8), namespace: "app", key: "first")
        try second.set(Data("from-second".utf8), namespace: "app", key: "second")

        XCTAssertEqual(try second.data(namespace: "app", key: "first"), Data("from-first".utf8))
        XCTAssertEqual(try first.data(namespace: "app", key: "second"), Data("from-second".utf8))
    }

    func testConcurrentConnectionsWritingDisjointKeysLoseNothing() async throws {
        let url = databaseURL
        _ = try SQLiteStore(url: url)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for writer in 0..<4 {
                group.addTask {
                    let store = try SQLiteStore(url: url, busyTimeout: 10)
                    for index in 0..<25 {
                        try store.set(Data("\(writer)-\(index)".utf8), namespace: "writer\(writer)", key: "key\(index)")
                    }
                }
            }
            try await group.waitForAll()
        }

        let store = try SQLiteStore(url: url)
        for writer in 0..<4 {
            XCTAssertEqual(try store.keys(namespace: "writer\(writer)").count, 25)
            XCTAssertEqual(
                try store.data(namespace: "writer\(writer)", key: "key24"),
                Data("\(writer)-24".utf8)
            )
        }
    }

    func testLockedDatabaseThrowsAfterBusyTimeoutAndRecoversWhenReleased() throws {
        let store = try SQLiteStore(url: databaseURL, busyTimeout: 0.2)
        let blocker = try RawSQLiteConnection(url: databaseURL)
        try blocker.execute("BEGIN EXCLUSIVE")

        let started = Date()
        XCTAssertThrowsError(try store.set(Data("blocked".utf8), namespace: "app", key: "key"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)

        try blocker.execute("ROLLBACK")
        blocker.close()
        try store.set(Data("free".utf8), namespace: "app", key: "key")
        XCTAssertEqual(try store.data(namespace: "app", key: "key"), Data("free".utf8))
    }

    func testTooNewDatabaseIsRefusedAndLeftUntouched() throws {
        do {
            let store = try SQLiteStore(url: databaseURL)
            try store.set(Data("value".utf8), namespace: "app", key: "key")
        }
        let connection = try RawSQLiteConnection(url: databaseURL)
        try connection.execute("PRAGMA user_version = 99")
        connection.close()
        let before = try DatabaseFiles.logicalState(of: databaseURL)

        XCTAssertThrowsError(try SQLiteStore(url: databaseURL))

        XCTAssertEqual(try DatabaseFiles.logicalState(of: databaseURL), before)
    }

    func testForeignDatabaseIsRefusedAndLeftUntouched() throws {
        let connection = try RawSQLiteConnection(url: databaseURL)
        try connection.execute("CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)")
        try connection.execute("INSERT INTO notes (body) VALUES ('synthetic')")
        connection.close()
        let before = try DatabaseFiles.bytes(of: databaseURL)

        XCTAssertThrowsError(try SQLiteStore(url: databaseURL))

        XCTAssertEqual(try DatabaseFiles.bytes(of: databaseURL), before)
    }

    func testCorruptFilesAreRefusedAndLeftUntouched() throws {
        let garbage = Data(repeating: 0x41, count: 4_096)
        try garbage.write(to: databaseURL)
        XCTAssertThrowsError(try SQLiteStore(url: databaseURL))
        XCTAssertEqual(try Data(contentsOf: databaseURL), garbage)

        let truncatedURL = directory.appendingPathComponent("truncated.db")
        do {
            let store = try SQLiteStore(url: truncatedURL)
            try store.set(Data(repeating: 0x42, count: 8_192), namespace: "app", key: "key")
        }
        let full = try Data(contentsOf: truncatedURL)
        let truncated = full.prefix(100)
        try truncated.write(to: truncatedURL)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: truncatedURL.path + "-wal"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: truncatedURL.path + "-shm"))

        XCTAssertThrowsError(try SQLiteStore(url: truncatedURL))
        XCTAssertEqual(try Data(contentsOf: truncatedURL), Data(truncated))
    }

    func testSymlinkedDatabaseFileIsRefusedAndItsTargetIsLeftUntouched() throws {
        let target = directory.appendingPathComponent("target.db")
        do {
            let store = try SQLiteStore(url: target)
            try store.set(Data("value".utf8), namespace: "app", key: "key")
        }
        let before = try DatabaseFiles.bytes(of: target)
        let link = directory.appendingPathComponent("link.db")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try SQLiteStore(url: link))

        XCTAssertEqual(try DatabaseFiles.bytes(of: target), before)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
    }

    func testDanglingSymlinkedDatabaseFileIsRefusedAndCreatesNothing() throws {
        let target = directory.appendingPathComponent("missing-target.db")
        let link = directory.appendingPathComponent("link.db")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try SQLiteStore(url: link))

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
    }

    func testSymlinkedRootDirectoryIsRefusedAndNothingIsCreatedInItsTarget() throws {
        let realRoot = directory.appendingPathComponent("real-root", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        let linkedRoot = directory.appendingPathComponent("linked-root", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: realRoot)

        XCTAssertThrowsError(try SQLiteStore(url: linkedRoot.appendingPathComponent("store.db")))

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: realRoot.path), [])
    }

    func testSymlinkedAncestorDirectoryIsAllowedLikeTheSystemTemporaryDirectory() throws {
        let realAncestor = directory.appendingPathComponent("real-ancestor", isDirectory: true)
        try FileManager.default.createDirectory(at: realAncestor, withIntermediateDirectories: true)
        let linkedAncestor = directory.appendingPathComponent("linked-ancestor", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedAncestor, withDestinationURL: realAncestor)
        let url = linkedAncestor.appendingPathComponent("nested/store.db")

        let store = try SQLiteStore(url: url)
        try store.set(Data("value".utf8), namespace: "app", key: "key")

        XCTAssertEqual(try SQLiteStore(url: url).data(namespace: "app", key: "key"), Data("value".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: realAncestor.appendingPathComponent("nested/store.db").path))
    }

    func testHotRollbackJournalFromAnInterruptedTransactionIsRecoveredOnOpen() throws {
        let rowCount = 64
        func blob(_ index: Int) -> Data { Data(repeating: UInt8(index + 1), count: 8_000) }
        do {
            let store = try SQLiteStore(url: databaseURL)
            for index in 0..<rowCount {
                try store.set(blob(index), namespace: "app", key: "key\(index)")
            }
        }
        let committedMain = try Data(contentsOf: databaseURL)
        let journalURL = URL(fileURLWithPath: databaseURL.path + "-journal")

        let interrupted = try RawSQLiteConnection(url: databaseURL)
        try interrupted.execute("PRAGMA cache_size = 1")
        try interrupted.execute("BEGIN IMMEDIATE")
        try interrupted.execute("UPDATE entries SET value = zeroblob(8000)")
        try interrupted.flushCache()
        let hotMain = try Data(contentsOf: databaseURL)
        let hotJournal = try Data(contentsOf: journalURL)
        interrupted.close()

        XCTAssertFalse(hotJournal.isEmpty, "fixture must capture a non-empty rollback journal")
        XCTAssertNotEqual(hotMain, committedMain, "fixture must capture a partially written database file")
        try hotMain.write(to: databaseURL)
        try hotJournal.write(to: journalURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))

        let recovered = try SQLiteStore(url: databaseURL)

        XCTAssertEqual(try recovered.keys(namespace: "app").count, rowCount)
        for index in 0..<rowCount {
            XCTAssertEqual(try recovered.data(namespace: "app", key: "key\(index)"), blob(index), "row \(index)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        let connection = try RawSQLiteConnection(url: databaseURL, readOnly: true)
        XCTAssertEqual(try connection.userVersion(), 1)
    }

    func testStoredValuesNeverAppearInAnotherNamespaceOrStore() throws {
        let store = try SQLiteStore(url: databaseURL)
        let other = try SQLiteStore(url: directory.appendingPathComponent("other.db"))
        try store.set(Data("sentinel-private-value".utf8), namespace: "app", key: "key")

        XCTAssertNil(try other.data(namespace: "app", key: "key"))
        XCTAssertEqual(try store.namespaces(prefix: ""), ["app"])
    }
}
