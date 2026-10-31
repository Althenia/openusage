import Foundation
import XCTest
@testable import OpenUsage

private final class HookBox<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

final class StorageMigrationTests: XCTestCase {
    private struct Probe: Error {}

    private var fixtures: [LegacyFixture] = []

    override func tearDownWithError() throws {
        for fixture in fixtures { fixture.cleanUp() }
        fixtures = []
    }

    private func makeFixture() throws -> LegacyFixture {
        let fixture = try LegacyFixture.make()
        fixtures.append(fixture)
        return fixture
    }

    private func isBooleanNumber(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private func marker(_ store: SQLiteStore) throws -> Data? {
        try store.data(namespace: "store.migrations", key: "import.legacy.v1")
    }

    private func expectedNamespaces(_ fixture: LegacyFixture) -> Set<String> {
        var namespaces: Set<String> = ["app", "telemetry", "store.migrations", "cursor-usage-history", "pricing"]
        for cache in fixture.scanCaches { namespaces.insert(cache.storeNamespace) }
        return namespaces
    }

    private func assertFullyImported(
        _ fixture: LegacyFixture,
        into store: SQLiteStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let app = AppPreferences(store: store, namespace: "app")
        for (key, value) in LegacyFixture.strings {
            XCTAssertEqual(app.string(forKey: key), value, key, file: file, line: line)
        }
        for (key, value) in LegacyFixture.bools {
            XCTAssertEqual(app.object(forKey: key) as? Bool, value, key, file: file, line: line)
        }
        for (key, value) in LegacyFixture.integers {
            XCTAssertEqual(app.object(forKey: key) as? Int, value, key, file: file, line: line)
        }
        for (key, value) in LegacyFixture.doubles {
            XCTAssertEqual(app.double(forKey: key), value, key, file: file, line: line)
        }
        for (key, value) in LegacyFixture.stringArrays {
            XCTAssertEqual(app.stringArray(forKey: key), value, key, file: file, line: line)
        }
        for key in LegacyFixture.dataKeys {
            XCTAssertEqual(app.data(forKey: key), fixture.dataValues[key], key, file: file, line: line)
        }

        let telemetry = AppPreferences(store: store, namespace: "telemetry")
        XCTAssertEqual(telemetry.string(forKey: "installID"), LegacyFixture.telemetryInstallID, file: file, line: line)
        XCTAssertEqual(telemetry.object(forKey: "enabled") as? Bool, false, file: file, line: line)
        XCTAssertEqual(telemetry.string(forKey: "activeDay"), LegacyFixture.telemetryActiveDay, file: file, line: line)
        XCTAssertEqual(telemetry.data(forKey: "providerDays"), LegacyFixture.telemetryProviderDays, file: file, line: line)

        for cache in fixture.scanCaches {
            XCTAssertEqual(
                Set(try store.keys(namespace: cache.storeNamespace)),
                ["manifest", cache.recordKey],
                file: file, line: line
            )
            XCTAssertEqual(
                try store.data(namespace: cache.storeNamespace, key: "manifest"),
                try Data(contentsOf: cache.manifestURL),
                file: file, line: line
            )
            XCTAssertEqual(
                try store.data(namespace: cache.storeNamespace, key: cache.recordKey),
                try Data(contentsOf: cache.recordURL),
                file: file, line: line
            )
        }

        XCTAssertEqual(try store.keys(namespace: "cursor-usage-history"), [fixture.cursorKey], file: file, line: line)
        XCTAssertEqual(
            try store.data(namespace: "cursor-usage-history", key: fixture.cursorKey),
            try Data(contentsOf: fixture.cursorFileURL),
            file: file, line: line
        )

        XCTAssertEqual(
            Set(try store.keys(namespace: "pricing")),
            ["litellm.json", "models_dev.json", "supplement.json", "state.json"],
            file: file, line: line
        )
        for (name, data) in fixture.pricingFiles {
            XCTAssertEqual(try store.data(namespace: "pricing", key: name), data, name, file: file, line: line)
        }
        XCTAssertNotNil(try marker(store), file: file, line: line)
    }

    func testImportCopiesEveryKnownSettingCacheHistoryAndPricingFileInOneRun() throws {
        let fixture = try makeFixture()
        let store = try fixture.makeStore()

        let report = try fixture.runImport(into: store)

        XCTAssertTrue(report.didImport)
        try assertFullyImported(fixture, into: store)
        XCTAssertEqual(Set(try store.namespaces(prefix: "")), expectedNamespaces(fixture))
    }

    func testImportedSnapshotCacheKeepsOriginalV9KeyAndStampedIdentity() throws {
        let fixture = try makeFixture()
        let store = try fixture.makeStore()

        _ = try fixture.runImport(into: store)

        let app = AppPreferences(store: store, namespace: "app")
        let blob = try XCTUnwrap(app.data(forKey: LegacyFixture.snapshotCacheKey))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: blob) as? [String: Any])
        let stamps = try XCTUnwrap(object["producedByIdentityKeys"] as? [String: String])
        XCTAssertEqual(stamps["claude"], "identity-synthetic")
        let dayKey = DailyUsageAccumulator.dayKey(from: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertNotNil(String(data: blob, encoding: .utf8)?.range(of: dayKey))
    }

    func testUnknownAndCredentialLikeDataIsNeverImported() throws {
        let fixture = try makeFixture()
        let store = try fixture.makeStore()

        _ = try fixture.runImport(into: store)

        let app = AppPreferences(store: store, namespace: "app")
        for key in LegacyFixture.unknownStandard.keys {
            XCTAssertNil(app.object(forKey: key), key)
        }
        let telemetry = AppPreferences(store: store, namespace: "telemetry")
        for key in LegacyFixture.unknownTelemetry.keys {
            XCTAssertNil(telemetry.object(forKey: key), key)
        }
        XCTAssertNil(telemetry.object(forKey: "openusage.future.unknown"))
        XCTAssertEqual(
            Set(try store.namespaces(prefix: "")).subtracting(expectedNamespaces(fixture)),
            []
        )
        XCTAssertNil(try store.data(namespace: "pricing", key: "notes.txt"))
        XCTAssertFalse(try store.keys(namespace: "cursor-usage-history").contains { $0.hasSuffix(".lock") })
        for cache in fixture.scanCaches {
            XCTAssertFalse(try store.keys(namespace: cache.storeNamespace).contains { $0.contains("lock") })
        }

        let sentinels = Array(LegacyFixture.unknownStandard.values)
            + Array(LegacyFixture.unknownTelemetry.values)
            + [LegacyFixture.fileCredentialSentinel]
        for (name, data) in try DatabaseFiles.bytes(of: fixture.databaseURL) {
            for sentinel in sentinels {
                XCTAssertNil(data.range(of: Data(sentinel.utf8)), "\(name) leaks \(sentinel)")
            }
        }
    }

    func testOriginalDefaultsAndFilesAreByteForByteUnchanged() throws {
        let fixture = try makeFixture()
        let store = try fixture.makeStore()
        let standardBefore = fixture.standardDomain()
        let telemetryBefore = fixture.telemetryDomain()
        let filesBefore = try FileTreeSnapshot.capture(fixture.applicationSupport)

        _ = try fixture.runImport(into: store)

        XCTAssertEqual(fixture.standardDomain(), standardBefore)
        XCTAssertEqual(fixture.telemetryDomain(), telemetryBefore)
        XCTAssertEqual(try FileTreeSnapshot.capture(fixture.applicationSupport), filesBefore)
    }

    func testSettingsVersionAndLayoutAreImportedAsIsWithoutTransformation() throws {
        let fixture = try makeFixture()
        let store = try fixture.makeStore()

        _ = try fixture.runImport(into: store)

        let app = AppPreferences(store: store, namespace: "app")
        XCTAssertEqual(app.object(forKey: "openusage.settings.schemaVersion") as? Int, 2)
        let layout = try XCTUnwrap(app.data(forKey: LegacyFixture.layoutKey))
        XCTAssertNotNil(String(data: layout, encoding: .utf8)?.range(of: LegacyFixture.deadMetricID))
        XCTAssertEqual(layout, fixture.dataValues[LegacyFixture.layoutKey])
    }

    func testTelemetryNamespaceKeepsOptOutAndInstallIdentityFromItsOwnSuite() throws {
        let fixture = try makeFixture()
        let store = try fixture.makeStore()

        _ = try fixture.runImport(into: store)

        let telemetry = AppPreferences(store: store, namespace: "telemetry")
        XCTAssertEqual(telemetry.object(forKey: "enabled") as? Bool, false)
        XCTAssertEqual(telemetry.string(forKey: "installID"), LegacyFixture.telemetryInstallID)
        let app = AppPreferences(store: store, namespace: "app")
        XCTAssertNil(app.object(forKey: "installID"))
        XCTAssertNil(app.object(forKey: "enabled"))
        XCTAssertNil(app.object(forKey: "activeDay"))
    }

    func testSecondRunIsANoOpAndNeverOverwritesLaterEditsOrReimportsChangedSources() throws {
        let fixture = try makeFixture()
        let store = try fixture.makeStore()
        XCTAssertTrue(try fixture.runImport(into: store).didImport)

        let app = AppPreferences(store: store, namespace: "app")
        app.set(false, forKey: "reduceAnimations")
        app.removeObject(forKey: "appearance")
        try store.remove(namespace: "pricing", key: "litellm.json")
        fixture.standard.set("light", forKey: "appearance")
        fixture.standard.set(true, forKey: "reduceAnimations")
        try LegacyFixture.write(Data(#"{"changed":true}"#.utf8), to: fixture.pricingDirectory.appendingPathComponent("models_dev.json"))
        let before = try snapshot(store)

        let report = try fixture.runImport(into: store)

        XCTAssertFalse(report.didImport)
        XCTAssertEqual(app.object(forKey: "reduceAnimations") as? Bool, false)
        XCTAssertNil(app.string(forKey: "appearance"))
        XCTAssertNil(try store.data(namespace: "pricing", key: "litellm.json"))
        XCTAssertEqual(try store.data(namespace: "pricing", key: "models_dev.json"), fixture.pricingFiles["models_dev.json"])
        XCTAssertEqual(try snapshot(store), before)
    }

    func testExistingStoreRowsWinOverLegacyValuesOnFirstImport() throws {
        let fixture = try makeFixture()
        let store = try fixture.makeStore()
        let app = AppPreferences(store: store, namespace: "app")
        app.set(false, forKey: "reduceAnimations")
        app.set(["cursor"], forKey: "openusage.enabledProviders.v1")
        let telemetry = AppPreferences(store: store, namespace: "telemetry")
        telemetry.set("existing-install", forKey: "installID")
        let existingPricing = Data(#"{"existing":true}"#.utf8)
        try store.set(existingPricing, namespace: "pricing", key: "litellm.json")

        let report = try fixture.runImport(into: store)

        XCTAssertTrue(report.didImport)
        XCTAssertEqual(app.object(forKey: "reduceAnimations") as? Bool, false)
        XCTAssertEqual(app.stringArray(forKey: "openusage.enabledProviders.v1"), ["cursor"])
        XCTAssertEqual(telemetry.string(forKey: "installID"), "existing-install")
        XCTAssertEqual(telemetry.object(forKey: "enabled") as? Bool, false)
        XCTAssertEqual(try store.data(namespace: "pricing", key: "litellm.json"), existingPricing)
        XCTAssertEqual(try store.data(namespace: "pricing", key: "state.json"), fixture.pricingFiles["state.json"])
        XCTAssertEqual(app.string(forKey: "appearance"), "dark")
        XCTAssertNotNil(try marker(store))
    }

    func testBeforeCommitFailureRollsBackEverythingAndRetrySucceeds() throws {
        let fixture = try makeFixture()
        let store = try fixture.makeStore()
        let hookRuns = HookBox<Int>(0)

        XCTAssertThrowsError(try fixture.runImport(into: store, beforeCommit: {
            hookRuns.value += 1
            throw Probe()
        })) { XCTAssertTrue($0 is Probe) }

        XCTAssertEqual(hookRuns.value, 1)
        XCTAssertEqual(try store.namespaces(prefix: ""), [])
        XCTAssertNil(try marker(store))

        let report = try fixture.runImport(into: store)

        XCTAssertTrue(report.didImport)
        try assertFullyImported(fixture, into: store)
    }

    func testImportedRowsAreInvisibleToOtherConnectionsUntilCommit() throws {
        let fixture = try makeFixture()
        let store = try fixture.makeStore()
        let observer = try fixture.makeStore()
        let observedDuringHook = HookBox<[String]?>(nil)

        _ = try fixture.runImport(into: store, beforeCommit: {
            observedDuringHook.value = try observer.namespaces(prefix: "")
        })

        XCTAssertEqual(observedDuringHook.value, [])
        XCTAssertEqual(Set(try observer.namespaces(prefix: "")), expectedNamespaces(fixture))
    }

    func testCorruptRecognizedFileBlocksTheWholeImportAndKeepsOriginals() throws {
        let targets: [(String, (LegacyFixture) -> URL)] = [
            ("pricing json", { $0.pricingDirectory.appendingPathComponent("litellm.json") }),
            ("pricing state", { $0.pricingDirectory.appendingPathComponent("state.json") }),
            ("cursor history json", { $0.cursorFileURL }),
            ("scan cache manifest", { $0.scanCaches[0].manifestURL }),
            ("scan cache record", { $0.scanCaches[1].recordURL })
        ]
        for (name, locate) in targets {
            let fixture = try makeFixture()
            let store = try fixture.makeStore()
            let target = locate(fixture)
            let valid = try Data(contentsOf: target)
            try Data("{not valid \u{0}".utf8).write(to: target)
            let standardBefore = fixture.standardDomain()
            let filesBefore = try FileTreeSnapshot.capture(fixture.applicationSupport)

            XCTAssertThrowsError(try fixture.runImport(into: store), name)

            XCTAssertEqual(try store.namespaces(prefix: ""), [], name)
            XCTAssertNil(try marker(store), name)
            XCTAssertTrue(AppPreferences(store: store, namespace: "app").isEmpty, name)
            XCTAssertEqual(fixture.standardDomain(), standardBefore, name)
            XCTAssertEqual(try FileTreeSnapshot.capture(fixture.applicationSupport), filesBefore, name)

            try valid.write(to: target)
            XCTAssertTrue(try fixture.runImport(into: store).didImport, name)
            try assertFullyImported(fixture, into: store)
        }
    }

    func testMalformedOrWrongShapedSettingBlobAbortsImportInsteadOfReseeding() throws {
        let corruptions: [(String, (Data) -> Data)] = [
            ("not json", { _ in Data("{not json".utf8) }),
            ("wrong outer shape", { valid in
                valid.first == UInt8(ascii: "[") ? Data(#"{"wrong":true}"#.utf8) : Data("[true]".utf8)
            })
        ]
        for key in LegacyFixture.dataKeys {
            for (label, corrupt) in corruptions {
                let fixture = try makeFixture()
                let store = try fixture.makeStore()
                let valid = try XCTUnwrap(fixture.standard.data(forKey: key))
                fixture.standard.set(corrupt(valid), forKey: key)
                let standardBefore = fixture.standardDomain()
                let filesBefore = try FileTreeSnapshot.capture(fixture.applicationSupport)

                XCTAssertThrowsError(try fixture.runImport(into: store), "\(key) \(label)")

                XCTAssertEqual(try store.namespaces(prefix: ""), [], "\(key) \(label)")
                XCTAssertNil(try marker(store), "\(key) \(label)")
                XCTAssertEqual(fixture.standardDomain(), standardBefore, "\(key) \(label)")
                XCTAssertEqual(try FileTreeSnapshot.capture(fixture.applicationSupport), filesBefore, "\(key) \(label)")

                fixture.standard.set(valid, forKey: key)
                XCTAssertTrue(try fixture.runImport(into: store).didImport, "\(key) \(label)")
                try assertFullyImported(fixture, into: store)
            }
        }
    }

    func testKnownSettingWithWrongStoredTypeAbortsImport() throws {
        let standardCases: [(String, Any)] = [
            ("reduceAnimations", "not-a-bool"),
            ("reduceAnimations", 1),
            ("openusage.panel.height.dashboard", "tall"),
            ("openusage.enabledProviders.v1", 5),
            ("appearance", 7),
            ("openusage.layout.v1", "text"),
            ("openusage.settings.schemaVersion", "three")
        ]
        for (key, wrong) in standardCases {
            let fixture = try makeFixture()
            let store = try fixture.makeStore()
            let valid = try XCTUnwrap(fixture.standard.object(forKey: key))
            fixture.standard.removeObject(forKey: key)
            fixture.standard.set(wrong, forKey: key)
            let stored = try XCTUnwrap(fixture.standard.object(forKey: key), key)
            if wrong is Int {
                XCTAssertFalse(isBooleanNumber(stored), "\(key) must be stored as a non-boolean number")
            }
            let standardBefore = fixture.standardDomain()

            XCTAssertThrowsError(try fixture.runImport(into: store), key)

            XCTAssertEqual(try store.namespaces(prefix: ""), [], key)
            XCTAssertNil(try marker(store), key)
            XCTAssertEqual(fixture.standardDomain(), standardBefore, key)

            fixture.standard.removeObject(forKey: key)
            fixture.standard.set(valid, forKey: key)
            let restored = try XCTUnwrap(fixture.standard.object(forKey: key), key)
            XCTAssertEqual(isBooleanNumber(restored), isBooleanNumber(valid), "\(key) restored with its original type")
            XCTAssertTrue(try fixture.runImport(into: store).didImport, key)
            try assertFullyImported(fixture, into: store)
        }

        let fixture = try makeFixture()
        let store = try fixture.makeStore()
        fixture.telemetry.set("maybe", forKey: "enabled")

        XCTAssertThrowsError(try fixture.runImport(into: store))

        XCTAssertEqual(try store.namespaces(prefix: ""), [])
        XCTAssertNil(try marker(store))
    }

    func testEmptyLegacyStateWritesOnlyTheMarkerAndThenIsIdempotent() throws {
        let root = try StorageTestDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let standardSuite = "OpenUsageStorageTests.empty.standard.\(UUID().uuidString)"
        let telemetrySuite = "OpenUsageStorageTests.empty.telemetry.\(UUID().uuidString)"
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardSuite))
        let telemetry = try XCTUnwrap(UserDefaults(suiteName: telemetrySuite))
        defer {
            standard.removePersistentDomain(forName: standardSuite)
            telemetry.removePersistentDomain(forName: telemetrySuite)
        }
        let store = try SQLiteStore(url: root.appendingPathComponent("data/openusage.db"))
        let support = root.appendingPathComponent("EmptyApplicationSupport", isDirectory: true)

        let first = try LegacyImport.run(
            store: store, standard: standard, telemetrySuite: telemetry, applicationSupportDirectory: support
        )
        let second = try LegacyImport.run(
            store: store, standard: standard, telemetrySuite: telemetry, applicationSupportDirectory: support
        )

        XCTAssertEqual(try store.namespaces(prefix: ""), ["store.migrations"])
        XCTAssertEqual(try store.keys(namespace: "store.migrations"), ["import.legacy.v1"])
        XCTAssertTrue(first.didImport)
        XCTAssertFalse(second.didImport)
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
    }

    private func snapshot(_ store: SQLiteStore) throws -> [String: [String: Data?]] {
        var result: [String: [String: Data?]] = [:]
        for namespace in try store.namespaces(prefix: "") {
            var rows: [String: Data?] = [:]
            for key in try store.keys(namespace: namespace) {
                rows[key] = try store.data(namespace: namespace, key: key)
            }
            result[namespace] = rows
        }
        return result
    }
}
