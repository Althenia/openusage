import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class StorageBootstrapTests: XCTestCase {
    private var root: URL!
    private var bundleIdentifier: String!
    private var standard: UserDefaults!
    private var telemetry: UserDefaults!

    private var databaseURL: URL { root.appendingPathComponent("data/openusage.db") }
    private var applicationSupport: URL { root.appendingPathComponent("ApplicationSupport", isDirectory: true) }

    override func setUpWithError() throws {
        AppPreferences.unconfigureStandard()
        CacheStore.configure(nil)
        root = try StorageTestDirectory.make()
        bundleIdentifier = "OpenUsageStorageBootstrap.\(UUID().uuidString)"
        standard = try XCTUnwrap(UserDefaults(suiteName: bundleIdentifier))
        telemetry = try XCTUnwrap(UserDefaults(suiteName: bundleIdentifier + ".telemetry"))
        standard.removePersistentDomain(forName: bundleIdentifier)
        telemetry.removePersistentDomain(forName: bundleIdentifier + ".telemetry")
    }

    override func tearDownWithError() throws {
        AppPreferences.unconfigureStandard()
        CacheStore.configure(nil)
        standard.removePersistentDomain(forName: bundleIdentifier)
        telemetry.removePersistentDomain(forName: bundleIdentifier + ".telemetry")
        try? FileManager.default.removeItem(at: root)
    }

    private func prepare() throws -> Bool {
        try StorageBootstrap.prepare(
            bundleIdentifier: bundleIdentifier,
            databaseURL: databaseURL,
            standard: standard,
            telemetrySuite: telemetry,
            applicationSupportDirectory: applicationSupport
        )
    }

    private func standardDomain() -> NSDictionary {
        NSDictionary(dictionary: standard.persistentDomain(forName: bundleIdentifier) ?? [:])
    }

    func testFreshInstallIsReportedOnceAndConfiguresStandardAtCurrentSettingsVersion() throws {
        XCTAssertTrue(try prepare())

        XCTAssertNotNil(AppPreferences.standard.store)
        XCTAssertNoThrow(try CacheStore.resolve(nil))
        XCTAssertEqual(AppPreferences.standard.object(forKey: "openusage.settings.schemaVersion") as? Int, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))

        AppPreferences.unconfigureStandard()
        XCTAssertFalse(try prepare())
        XCTAssertEqual(AppPreferences.standard.object(forKey: "openusage.settings.schemaVersion") as? Int, 3)
    }

    func testLegacyV1SettingsAreImportedThenTransformedToV3InSQLiteOnly() throws {
        standard.set(1, forKey: "openusage.settings.schemaVersion")
        standard.set(["cursor"], forKey: "openusage.disabledProviders.v1")
        standard.set(["antigravity.session", "claude.session", "antigravity.geminiPro"], forKey: "openusage.layout.v1.menuBarPins")
        standard.set(["copilot.credits"], forKey: "openusage.layout.v1.expandedMetrics")
        let originalDomain = standardDomain()

        let fresh = try prepare()

        XCTAssertFalse(fresh)
        let app = AppPreferences.standard
        XCTAssertEqual(app.object(forKey: "openusage.settings.schemaVersion") as? Int, 3)
        XCTAssertEqual(
            app.stringArray(forKey: "openusage.enabledProviders.v1"),
            ["antigravity", "claude", "codex", "copilot", "devin", "grok", "openrouter", "zai"]
        )
        XCTAssertNil(app.object(forKey: "openusage.disabledProviders.v1"))
        XCTAssertEqual(
            app.stringArray(forKey: "openusage.knownProviders.v1"),
            ["antigravity", "claude", "codex", "copilot", "cursor", "devin", "grok", "openrouter", "zai"]
        )
        XCTAssertEqual(
            app.stringArray(forKey: "openusage.layout.v1.menuBarPins"),
            ["antigravity.geminiPro", "claude.session"]
        )
        XCTAssertEqual(app.stringArray(forKey: "openusage.layout.v1.expandedMetrics"), ["copilot.premium"])
        XCTAssertEqual(standardDomain(), originalDomain)
    }

    func testImportedLegacyInstallIsNotFreshEvenWithoutAnySchemaVersion() throws {
        standard.set(["claude"], forKey: "openusage.enabledProviders.v1")
        standard.set("dark", forKey: "appearance")
        let originalDomain = standardDomain()

        XCTAssertFalse(try prepare())

        XCTAssertEqual(AppPreferences.standard.string(forKey: "appearance"), "dark")
        XCTAssertEqual(AppPreferences.standard.object(forKey: "openusage.settings.schemaVersion") as? Int, 3)
        XCTAssertEqual(standardDomain(), originalDomain)
    }

    func testMalformedLegacyFileBlocksBootstrapAndLeavesStandardUnconfigured() throws {
        standard.set("dark", forKey: "appearance")
        let pricing = applicationSupport.appendingPathComponent("OpenUsage/pricing/litellm.json")
        try LegacyFixture.write(Data("{not json".utf8), to: pricing)
        let originalDomain = standardDomain()
        let filesBefore = try FileTreeSnapshot.capture(applicationSupport)

        XCTAssertThrowsError(try prepare())

        XCTAssertNil(AppPreferences.standard.store)
        XCTAssertThrowsError(try CacheStore.resolve(nil))
        XCTAssertNil(AppPreferences.standard.string(forKey: "appearance"))
        XCTAssertEqual(standardDomain(), originalDomain)
        XCTAssertEqual(try FileTreeSnapshot.capture(applicationSupport), filesBefore)
        let store = try SQLiteStore(url: databaseURL)
        XCTAssertEqual(try store.namespaces(prefix: ""), [])
    }

    func testSecondPrepareDoesNotReimportChangedLegacyValues() throws {
        standard.set("dark", forKey: "appearance")
        XCTAssertFalse(try prepare())
        AppPreferences.standard.set("light", forKey: "appearance")
        AppPreferences.unconfigureStandard()
        standard.set("system", forKey: "appearance")

        XCTAssertFalse(try prepare())

        XCTAssertEqual(AppPreferences.standard.string(forKey: "appearance"), "light")
    }

    func testFreshBootstrapMarksWelcomePendingAndKeepsItUntilCleared() throws {
        XCTAssertTrue(try prepare())
        XCTAssertTrue(FirstLaunchSetup.isPending(defaults: .standard))

        AppPreferences.unconfigureStandard()
        XCTAssertFalse(try prepare())
        XCTAssertTrue(FirstLaunchSetup.isPending(defaults: .standard))

        FirstLaunchSetup.clearPending(defaults: .standard)
        AppPreferences.unconfigureStandard()
        XCTAssertFalse(try prepare())
        XCTAssertFalse(FirstLaunchSetup.isPending(defaults: .standard))
    }

    func testExistingInstallBootstrapDoesNotMarkWelcomePending() throws {
        standard.set("dark", forKey: "appearance")

        XCTAssertFalse(try prepare())

        XCTAssertFalse(FirstLaunchSetup.isPending(defaults: .standard))
    }
}
