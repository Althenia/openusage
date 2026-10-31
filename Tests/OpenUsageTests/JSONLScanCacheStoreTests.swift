import Foundation
import XCTest
@testable import OpenUsage

final class JSONLScanCacheStoreTests: XCTestCase {
    private var base: URL!
    private var store: SQLiteStore!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        store = try SQLiteStore(url: base.appendingPathComponent("cache.db"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    func testWriterMergesDisjointPathUpdatesFromSeparateSnapshots() async throws {
        let persistence = makePersistence()
        let identity = "home"
        let first = try writeSource(
            "first",
            to: base.appendingPathComponent("first.jsonl"),
            mtime: Date(timeIntervalSince1970: 2_000)
        )
        let second = try writeSource(
            "second",
            to: base.appendingPathComponent("second.jsonl"),
            mtime: Date(timeIntervalSince1970: 3_000)
        )
        let firstBatch = makeBatch(
            persistence: persistence,
            identity: identity,
            file: first,
            recordData: Data("first-record".utf8)
        )
        let secondBatch = makeBatch(
            persistence: persistence,
            identity: identity,
            file: second,
            recordData: Data("second-record".utf8)
        )
        let firstWriter = JSONLScanCacheWriter()
        let secondWriter = JSONLScanCacheWriter()

        async let firstCommit = firstWriter.commit(firstBatch)
        async let secondCommit = secondWriter.commit(secondBatch)
        _ = try await (firstCommit, secondCommit)
        let loaded = try firstWriter.load(
            persistence: persistence,
            identity: identity,
            itemType: Int.self
        )
        let snapshot = try XCTUnwrap(loaded)

        XCTAssertEqual(Set(snapshot.manifest.files.keys), Set([first.path, second.path]))
        for (file, expectedRecord) in [(first, "first-record"), (second, "second-record")] {
            XCTAssertEqual(
                try recordData(persistence: persistence, identity: identity, fileName: JSONLScanCachePaths.recordFileName(path: file.path)),
                Data(expectedRecord.utf8),
                file.path
            )
        }
    }

    func testWriterRejectsAStaleUpsertAfterTheSourceChanges() async throws {
        let persistence = makePersistence()
        let sourceURL = base.appendingPathComponent("usage.jsonl")
        let stale = try writeSource("old", to: sourceURL, mtime: Date(timeIntervalSince1970: 2_000))
        let staleBatch = makeBatch(
            persistence: persistence,
            identity: "home",
            file: stale,
            recordData: Data("stale-record".utf8)
        )
        _ = try writeSource("newer", to: sourceURL, mtime: Date(timeIntervalSince1970: 3_000))

        let result = try await JSONLScanCacheWriter().commit(staleBatch)

        XCTAssertTrue(result.manifest.files.isEmpty)
        XCTAssertTrue(result.acceptedUpsertPaths.isEmpty)
    }

    func testStaleRemovalDoesNotDeleteANewerPathUpdate() async throws {
        let persistence = makePersistence()
        let sourceURL = base.appendingPathComponent("usage.jsonl")
        let oldFile = try writeSource("old", to: sourceURL, mtime: Date(timeIntervalSince1970: 2_000))
        let oldBatch = makeBatch(
            persistence: persistence,
            identity: "home",
            file: oldFile,
            recordData: Data("old-record".utf8)
        )
        let writer = JSONLScanCacheWriter()
        let oldResult = try await writer.commit(oldBatch)
        let oldMetadata = try XCTUnwrap(oldResult.manifest.files[oldFile.path])

        let newFile = try writeSource("newer", to: sourceURL, mtime: Date(timeIntervalSince1970: 3_000))
        let newResult = try await writer.commit(makeBatch(
            persistence: persistence,
            identity: "home",
            file: newFile,
            recordData: Data("new-record".utf8)
        ))
        let newMetadata = try XCTUnwrap(newResult.manifest.files[newFile.path])
        let staleRemoval = JSONLScanCacheWriteBatch(
            persistence: persistence,
            identity: "home",
            upserts: [:],
            removals: [oldFile.path: oldMetadata]
        )

        let result = try await writer.commit(staleRemoval)

        XCTAssertEqual(result.manifest.files[newFile.path], newMetadata)
        XCTAssertEqual(
            try recordData(persistence: persistence, identity: "home", fileName: newMetadata.recordFileName),
            Data("new-record".utf8)
        )
    }

    func testLoadingAnOldIdentityTouchesItBeforeStalePruning() async throws {
        let persistence = makePersistence()
        let file = try writeSource(
            "value",
            to: base.appendingPathComponent("usage.jsonl"),
            mtime: Date()
        )
        let writer = JSONLScanCacheWriter()
        _ = try await writer.commit(makeBatch(
            persistence: persistence,
            identity: "home",
            file: file,
            recordData: Data("record".utf8)
        ))
        let namespace = JSONLScanCachePaths.storeNamespace(persistence: persistence, identity: "home")
        let written = try XCTUnwrap(try store.modifiedAt(namespace: namespace, key: JSONLScanCachePaths.manifestKey))
        try await Task.sleep(for: .milliseconds(200))

        _ = try writer.load(
            persistence: persistence,
            identity: "home",
            itemType: Int.self
        )
        let touched = try XCTUnwrap(try store.modifiedAt(namespace: namespace, key: JSONLScanCachePaths.manifestKey))
        XCTAssertGreaterThan(touched, written)
        await writer.pruneStaleIdentities(
            persistence: persistence,
            before: written.addingTimeInterval(touched.timeIntervalSince(written) / 2)
        )

        XCTAssertEqual(try store.namespaces(prefix: namespace), [namespace])
        XCTAssertNotNil(try store.data(namespace: namespace, key: JSONLScanCachePaths.manifestKey))
    }

    func testPruningRemovesOnlyIdentitiesOlderThanTheCutoffInTheSameParserNamespace() async throws {
        let persistence = makePersistence()
        let otherParser = JSONLScanCachePersistence(namespace: "other", schemaVersion: 1, store: store)
        let file = try writeSource("value", to: base.appendingPathComponent("usage.jsonl"), mtime: Date())
        let writer = JSONLScanCacheWriter()
        _ = try await writer.commit(makeBatch(
            persistence: persistence, identity: "old-home", file: file, recordData: Data("old".utf8)
        ))
        _ = try await writer.commit(makeBatch(
            persistence: otherParser, identity: "old-home", file: file, recordData: Data("other".utf8)
        ))
        try await Task.sleep(for: .milliseconds(200))
        let cutoff = Date()
        try await Task.sleep(for: .milliseconds(200))
        _ = try await writer.commit(makeBatch(
            persistence: persistence, identity: "new-home", file: file, recordData: Data("new".utf8)
        ))

        await writer.pruneStaleIdentities(persistence: persistence, before: cutoff)

        XCTAssertNil(try recordData(
            persistence: persistence, identity: "old-home",
            fileName: JSONLScanCachePaths.recordFileName(path: file.path)
        ))
        XCTAssertEqual(
            try recordData(
                persistence: persistence, identity: "new-home",
                fileName: JSONLScanCachePaths.recordFileName(path: file.path)
            ),
            Data("new".utf8)
        )
        XCTAssertEqual(
            try recordData(
                persistence: otherParser, identity: "old-home",
                fileName: JSONLScanCachePaths.recordFileName(path: file.path)
            ),
            Data("other".utf8)
        )
    }

    func testCommitReplacesManifestAndDropsRecordsNoLongerReferenced() async throws {
        let persistence = makePersistence()
        let sourceURL = base.appendingPathComponent("usage.jsonl")
        let old = try writeSource("old", to: sourceURL, mtime: Date(timeIntervalSince1970: 2_000))
        let writer = JSONLScanCacheWriter()
        let first = try await writer.commit(makeBatch(
            persistence: persistence, identity: "home", file: old, recordData: Data("old-record".utf8)
        ))
        let oldMetadata = try XCTUnwrap(first.manifest.files[old.path])
        let namespace = JSONLScanCachePaths.storeNamespace(persistence: persistence, identity: "home")

        _ = try await writer.commit(JSONLScanCacheWriteBatch(
            persistence: persistence, identity: "home", upserts: [:], removals: [old.path: oldMetadata]
        ))

        XCTAssertEqual(try store.namespaces(prefix: namespace), [])
    }

    func testFreshScannerCanPersistAfterAnotherScannerHasWrittenRepeatedly() async throws {
        let sourceURL = base.appendingPathComponent("usage.jsonl")
        let persistence = makePersistence(writeDebounce: .milliseconds(1))
        let firstScanner = IncrementalJSONLScanner<Int>(persistence: persistence)
        let baseDate = Date(timeIntervalSince1970: 10_000)

        for (index, contents) in ["1", "22", "333"].enumerated() {
            let file = try writeSource(
                contents,
                to: sourceURL,
                mtime: baseDate.addingTimeInterval(Double(index))
            )
            let scanned = await firstScanner.items(
                from: [file],
                since: .distantPast,
                cacheIdentity: "home",
                parse: ParseCounter().parse
            )
            XCTAssertEqual(scanned, [try XCTUnwrap(Int(contents))])
            await firstScanner.waitForPendingWritesForTesting()
        }

        let finalFile = try writeSource(
            "4444",
            to: sourceURL,
            mtime: baseDate.addingTimeInterval(3)
        )
        let freshScanner = IncrementalJSONLScanner<Int>(persistence: persistence)
        let finalItems = await freshScanner.items(
            from: [finalFile],
            since: .distantPast,
            cacheIdentity: "home",
            parse: ParseCounter().parse
        )
        XCTAssertEqual(finalItems, [4444])
        await freshScanner.waitForPendingWritesForTesting()

        let reloadCounter = ParseCounter()
        let reloaded = IncrementalJSONLScanner<Int>(persistence: persistence)
        let items = await reloaded.items(
            from: [finalFile],
            since: .distantPast,
            cacheIdentity: "home",
            parse: reloadCounter.parse
        )
        XCTAssertEqual(items, [4444])
        XCTAssertEqual(reloadCounter.count, 0)
    }

    func testFlushPendingWritesBypassesTheDebounceForOneShotProcesses() async throws {
        let file = try writeSource(
            "7",
            to: base.appendingPathComponent("usage.jsonl"),
            mtime: Date()
        )
        let persistence = makePersistence(writeDebounce: .seconds(60))
        let scanner = IncrementalJSONLScanner<Int>(persistence: persistence)
        _ = await scanner.items(
            from: [file],
            since: .distantPast,
            cacheIdentity: "home",
            parse: ParseCounter().parse
        )

        await scanner.flushPendingWrites()

        let reloadCounter = ParseCounter()
        let reloaded = IncrementalJSONLScanner<Int>(persistence: persistence)
        let items = await reloaded.items(
            from: [file],
            since: .distantPast,
            cacheIdentity: "home",
            parse: reloadCounter.parse
        )
        XCTAssertEqual(items, [7])
        XCTAssertEqual(reloadCounter.count, 0)
    }

    func testFlushRetriesDirtyWriteAfterDebouncedFailure() async throws {
        let file = try writeSource(
            "7",
            to: base.appendingPathComponent("usage.jsonl"),
            mtime: Date()
        )
        let blockedURL = base.appendingPathComponent("blocked.db")
        let blockedStore = try SQLiteStore(url: blockedURL, busyTimeout: 0.05)
        let persistence = JSONLScanCachePersistence(
            namespace: "test", schemaVersion: 1, store: blockedStore, writeDebounce: .milliseconds(1)
        )
        let blocker = try RawSQLiteConnection(url: blockedURL)
        try blocker.execute("BEGIN EXCLUSIVE")
        let scanner = IncrementalJSONLScanner<Int>(persistence: persistence)
        _ = await scanner.items(
            from: [file],
            since: .distantPast,
            cacheIdentity: "home",
            parse: ParseCounter().parse
        )
        await scanner.waitForPendingWritesForTesting()

        try blocker.execute("ROLLBACK")
        blocker.close()
        await scanner.flushPendingWrites()

        let reloadCounter = ParseCounter()
        let reloaded = IncrementalJSONLScanner<Int>(persistence: persistence)
        let items = await reloaded.items(
            from: [file],
            since: .distantPast,
            cacheIdentity: "home",
            parse: reloadCounter.parse
        )
        XCTAssertEqual(items, [7])
        XCTAssertEqual(reloadCounter.count, 0)
    }

    func testParseLimitIsSharedAcrossDifferentIdentities() async throws {
        let now = Date()
        let firstFiles = try makeIntegerFiles(range: 0..<4, prefix: "a", in: base, mtime: now)
        let secondFiles = try makeIntegerFiles(range: 4..<8, prefix: "b", in: base, mtime: now)
        let scanner = IncrementalJSONLScanner<Int>(maxConcurrentParses: 3)
        let probe = ConcurrencyProbe()
        let parse: @Sendable (Data) -> [Int]? = { data in
            probe.begin()
            defer { probe.end() }
            Thread.sleep(forTimeInterval: 0.01)
            return String(data: data, encoding: .utf8).flatMap(Int.init).map { [$0] }
        }

        async let first = scanner.items(
            from: firstFiles,
            since: .distantPast,
            cacheIdentity: "home-a",
            parse: parse
        )
        async let second = scanner.items(
            from: secondFiles,
            since: .distantPast,
            cacheIdentity: "home-b",
            parse: parse
        )
        let results = await (first, second)

        XCTAssertEqual(results.0, Array(0..<4))
        XCTAssertEqual(results.1, Array(4..<8))
        XCTAssertLessThanOrEqual(probe.maximumActive, 3)
    }

    func testStaleLocalEvictionCannotRemoveANewerExternalRecord() async throws {
        let persistence = makePersistence(writeDebounce: .milliseconds(1))
        let identity = "home"
        let baseDate = Date(timeIntervalSince1970: 10_000)
        let primaryURL = base.appendingPathComponent("primary.jsonl")
        let originalPrimary = try writeSource("1", to: primaryURL, mtime: baseDate)
        let firstScanner = IncrementalJSONLScanner<Int>(persistence: persistence)
        _ = await firstScanner.items(
            from: [originalPrimary],
            since: .distantPast,
            cacheIdentity: identity,
            parse: ParseCounter().parse
        )
        await firstScanner.waitForPendingWritesForTesting()

        let updatedPrimary = try writeSource(
            "2",
            to: primaryURL,
            mtime: baseDate.addingTimeInterval(10)
        )
        let externalScanner = IncrementalJSONLScanner<Int>(persistence: persistence)
        _ = await externalScanner.items(
            from: [updatedPrimary],
            since: .distantPast,
            cacheIdentity: identity,
            parse: ParseCounter().parse
        )
        await externalScanner.waitForPendingWritesForTesting()

        let secondary = try writeSource(
            "20",
            to: base.appendingPathComponent("secondary.jsonl"),
            mtime: baseDate.addingTimeInterval(20)
        )
        _ = await firstScanner.items(
            from: [secondary],
            since: .distantPast,
            cacheIdentity: identity,
            parse: ParseCounter().parse
        )
        await firstScanner.waitForPendingWritesForTesting()
        _ = await firstScanner.items(
            from: [secondary],
            since: baseDate.addingTimeInterval(5),
            cacheIdentity: identity,
            parse: ParseCounter().parse
        )
        await firstScanner.waitForPendingWritesForTesting()

        let reloadCounter = ParseCounter()
        let reloaded = IncrementalJSONLScanner<Int>(persistence: persistence)
        let items = await reloaded.items(
            from: [updatedPrimary, secondary],
            since: .distantPast,
            cacheIdentity: identity,
            parse: reloadCounter.parse
        )
        XCTAssertEqual(items, [2, 20])
        XCTAssertEqual(reloadCounter.count, 0)
    }

    private func makePersistence(writeDebounce: Duration = .seconds(2)) -> JSONLScanCachePersistence {
        JSONLScanCachePersistence(
            namespace: "test",
            schemaVersion: 1,
            store: store,
            writeDebounce: writeDebounce
        )
    }

    private func recordData(
        persistence: JSONLScanCachePersistence,
        identity: String,
        fileName: String
    ) throws -> Data? {
        try store.data(
            namespace: JSONLScanCachePaths.storeNamespace(persistence: persistence, identity: identity),
            key: JSONLScanCachePaths.recordKey(fileName: fileName)
        )
    }

    private func makeBatch(
        persistence: JSONLScanCachePersistence,
        identity: String,
        file: JSONLScanning.DiscoveredFile,
        recordData: Data
    ) -> JSONLScanCacheWriteBatch {
        let metadata = JSONLScanCacheFileMetadata(
            size: file.size,
            mtime: file.mtime,
            recordFileName: JSONLScanCachePaths.recordFileName(path: file.path)
        )
        return JSONLScanCacheWriteBatch(
            persistence: persistence,
            identity: identity,
            upserts: [file.path: JSONLScanCacheUpsert(metadata: metadata, recordData: recordData)],
            removals: [:]
        )
    }

    private func writeSource(
        _ contents: String,
        to url: URL,
        mtime: Date
    ) throws -> JSONLScanning.DiscoveredFile {
        let data = Data(contents.utf8)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return JSONLScanning.DiscoveredFile(
            path: url.path,
            size: try XCTUnwrap(attributes[.size] as? NSNumber).intValue,
            mtime: try XCTUnwrap(attributes[.modificationDate] as? Date)
        )
    }

    private func makeIntegerFiles(
        range: Range<Int>,
        prefix: String,
        in directory: URL,
        mtime: Date
    ) throws -> [JSONLScanning.DiscoveredFile] {
        try range.map { value in
            try writeSource(
                String(value),
                to: directory.appendingPathComponent("\(prefix)-\(value).jsonl"),
                mtime: mtime
            )
        }
    }
}
