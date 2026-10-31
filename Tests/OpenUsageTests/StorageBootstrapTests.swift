import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class StorageBootstrapTests: XCTestCase {
    private var root: URL!
    private var bundleIdentifier: String!
    private var standard: UserDefaults!
    private var telemetry: UserDefaults!
    private var previousLogSink: LogFile!
    private var ownsRoot = false

    private var databaseURL: URL { root.appendingPathComponent("data/openusage.db") }
    private var applicationSupport: URL { root.appendingPathComponent("ApplicationSupport", isDirectory: true) }

    override func setUpWithError() throws {
        AppPreferences.unconfigureStandard()
        CacheStore.configure(nil)
        previousLogSink = AppLog.sink
        if let childRoot = ProcessInfo.processInfo.environment["OPENUSAGE_BOOTSTRAP_CHILD_ROOT"] {
            let candidate = URL(fileURLWithPath: childRoot, isDirectory: true).standardizedFileURL
            let parentName = candidate.deletingLastPathComponent().lastPathComponent
            let prefix = "OpenUsageStorageTests-"
            guard candidate.lastPathComponent == "cold-process",
                  parentName.hasPrefix(prefix),
                  UUID(uuidString: String(parentName.dropFirst(prefix.count))) != nil else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            root = candidate
        } else {
            root = try StorageTestDirectory.make()
            ownsRoot = true
        }
        AppLog.sink = LogFile(directory: root.appendingPathComponent("Logs"), fileName: "bootstrap.log")
        bundleIdentifier = "OpenUsageStorageBootstrap.\(UUID().uuidString)"
        if !ownsRoot, let syntheticID = ProcessInfo.processInfo.environment["OPENUSAGE_BOOTSTRAP_SYNTHETIC_MAIN_ID"] {
            let prefix = "OpenUsageStorageBootstrap."
            guard syntheticID.hasPrefix(prefix),
                  UUID(uuidString: String(syntheticID.dropFirst(prefix.count))) != nil else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            bundleIdentifier = syntheticID
        }
        if ProcessInfo.processInfo.environment["OPENUSAGE_BOOTSTRAP_CHILD_ROOT"] != nil { return }
        standard = try XCTUnwrap(UserDefaults(suiteName: bundleIdentifier))
        telemetry = try XCTUnwrap(UserDefaults(suiteName: bundleIdentifier + ".telemetry"))
        standard.removePersistentDomain(forName: bundleIdentifier)
        telemetry.removePersistentDomain(forName: bundleIdentifier + ".telemetry")
    }

    override func tearDownWithError() throws {
        AppLog.sink = previousLogSink
        AppPreferences.unconfigureStandard()
        CacheStore.configure(nil)
        standard?.removePersistentDomain(forName: bundleIdentifier)
        telemetry?.removePersistentDomain(forName: bundleIdentifier + ".telemetry")
        if ownsRoot { try? FileManager.default.removeItem(at: root) }
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

    func testFreshStartupCreatesDefaultLegacySuitesBeforePublishingConfiguredStorage() throws {
        let fresh = try StorageBootstrap.prepare(
            bundleIdentifier: bundleIdentifier,
            databaseURL: databaseURL,
            applicationSupportDirectory: applicationSupport
        )

        XCTAssertTrue(fresh)
        XCTAssertNotNil(AppPreferences.standard.store)
        XCTAssertNoThrow(try AppPreferences.standard.checkError())
        XCTAssertNoThrow(try AppPreferences.telemetry.checkError())
        XCTAssertNoThrow(try CacheStore.resolve(nil))
        XCTAssertTrue(FirstLaunchSetup.isPending(defaults: .standard))
        XCTAssertEqual(AppPreferences.standard.integer(forKey: SettingsMigrator.schemaVersionKey), SettingsSchema.current)
    }

    func testColdProcessStartupConfiguresDefaultStorageWithoutPrecreatedSuites() throws {
        let environment = ProcessInfo.processInfo.environment
        if environment["OPENUSAGE_BOOTSTRAP_CHILD_ROOT"] != nil {
            if let expectedMainID = environment["OPENUSAGE_BOOTSTRAP_SYNTHETIC_MAIN_ID"] {
                guard expectedMainID.hasPrefix("OpenUsageStorageBootstrap."),
                      Bundle.main.bundleIdentifier == expectedMainID else {
                    return XCTFail("Packaged bootstrap did not use its synthetic bundle identity")
                }
            }
            let home = try XCTUnwrap(environment["CFFIXED_USER_HOME"])
            guard FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
                    == URL(fileURLWithPath: home).resolvingSymlinksInPath().path else {
                return XCTFail("Cold-process home isolation was not applied")
            }
            let expectedDatabase = SQLiteStoreLocation.databaseURL(
                environment: environment,
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                bundleIdentifier: bundleIdentifier
            )
            guard expectedDatabase.path.hasPrefix(root.path + "/") else {
                return XCTFail("Cold-process database escaped its fixture")
            }
            let scenario = environment["OPENUSAGE_BOOTSTRAP_SCENARIO"] ?? "fresh"
            var legacyDomain: NSDictionary?
            if scenario == "legacy" {
                guard environment["OPENUSAGE_BOOTSTRAP_SYNTHETIC_MAIN_ID"] != nil else {
                    return XCTFail("Legacy current-domain test requires its synthetic app bundle")
                }
                UserDefaults.standard.set("dark", forKey: "appearance")
                UserDefaults.standard.set(["claude"], forKey: "openusage.enabledProviders.v1")
                legacyDomain = NSDictionary(dictionary: UserDefaults.standard.persistentDomain(forName: bundleIdentifier) ?? [:])
            }
            XCTAssertEqual(try StorageBootstrap.prepare(
                bundleIdentifier: bundleIdentifier,
                applicationSupportDirectory: applicationSupport
            ), scenario != "legacy")
            XCTAssertTrue(FileManager.default.fileExists(atPath: expectedDatabase.path))
            XCTAssertNoThrow(try AppPreferences.standard.checkError())
            XCTAssertNoThrow(try AppPreferences.telemetry.checkError())
            XCTAssertNoThrow(try CacheStore.resolve(nil))
            XCTAssertEqual(FirstLaunchSetup.isPending(defaults: .standard), scenario != "legacy")
            if let legacyDomain {
                XCTAssertEqual(AppPreferences.standard.string(forKey: "appearance"), "dark")
                XCTAssertEqual(AppPreferences.standard.stringArray(forKey: "openusage.enabledProviders.v1"), ["claude"])
                XCTAssertEqual(NSDictionary(dictionary: UserDefaults.standard.persistentDomain(forName: bundleIdentifier) ?? [:]), legacyDomain)
            }
            if scenario == "existing" {
                AppPreferences.standard.set("light", forKey: "appearance")
                AppPreferences.unconfigureStandard()
                CacheStore.configure(nil)
                XCTAssertFalse(try StorageBootstrap.prepare(
                    bundleIdentifier: bundleIdentifier,
                    applicationSupportDirectory: applicationSupport
                ))
                XCTAssertEqual(AppPreferences.standard.string(forKey: "appearance"), "light")
                XCTAssertNoThrow(try AppPreferences.standard.checkError())
            }
            return
        }

        try runColdProcess(packaged: false)
    }

    func testPackagedProcessStartupUsesItsOwnSyntheticBundleDefaults() throws {
        try runColdProcess(packaged: true)
    }

    func testPackagedLegacyStartupPreservesItsOwnSyntheticDefaults() throws {
        try runColdProcess(packaged: true, scenario: "legacy")
    }

    func testPackagedExistingSQLiteStartupPreservesMigratedValues() throws {
        try runColdProcess(packaged: true, scenario: "existing")
    }

    private func runColdProcess(packaged: Bool, scenario: String = "fresh") throws {
        let environment = ProcessInfo.processInfo.environment
        let childRoot = root.appendingPathComponent("cold-process", isDirectory: true)
        let home = childRoot.appendingPathComponent("home", isDirectory: true)
        let temporary = childRoot.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let process = Process()
        let runner = URL(fileURLWithPath: try XCTUnwrap(CommandLine.arguments.first))
        guard runner.lastPathComponent == "xctest" else {
            return XCTFail("Cold-process bootstrap requires the XCTest runner")
        }
        process.executableURL = runner
        if packaged {
            let app = childRoot.appendingPathComponent("Bootstrap.app", isDirectory: true)
            let executable = app.appendingPathComponent("Contents/MacOS/xctest")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: runner.resolvingSymlinksInPath(), to: executable)
            let info: [String: Any] = [
                "CFBundleIdentifier": bundleIdentifier!,
                "CFBundleExecutable": "xctest",
                "CFBundlePackageType": "APPL",
                "CFBundleVersion": "1"
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
            process.executableURL = executable
        }
        process.arguments = [
            "-XCTest", "OpenUsageTests.StorageBootstrapTests/testColdProcessStartupConfiguresDefaultStorageWithoutPrecreatedSuites",
            Bundle(for: Self.self).bundleURL.path
        ]
        process.environment = [
            "HOME": home.path,
            "CFFIXED_USER_HOME": home.path,
            "XDG_DATA_HOME": childRoot.appendingPathComponent("data").path,
            "TMPDIR": temporary.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "OPENUSAGE_BOOTSTRAP_SCENARIO": scenario,
            "OPENUSAGE_BOOTSTRAP_CHILD_ROOT": childRoot.path
        ]
        if packaged { process.environment?["OPENUSAGE_BOOTSTRAP_SYNTHETIC_MAIN_ID"] = bundleIdentifier }
        let testFrameworks = Bundle(for: XCTestCase.self).bundleURL.deletingLastPathComponent().path
        process.environment?["DYLD_FRAMEWORK_PATH"] = [testFrameworks, environment["DYLD_FRAMEWORK_PATH"]]
            .compactMap { $0 }.joined(separator: ":")
        if packaged {
            let runnerDirectory = runner.resolvingSymlinksInPath().deletingLastPathComponent()
            process.environment?["DYLD_LIBRARY_PATH"] = runnerDirectory
                .appendingPathComponent("../../../usr/lib").standardizedFileURL.path
        }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + 20) == .success else {
            process.terminate()
            process.waitUntilExit()
            return XCTFail("Cold-process bootstrap exceeded its execution bound")
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, text)
        XCTAssertTrue(text.contains("Executed 1 test"), text)
        XCTAssertTrue(FileManager.default.fileExists(atPath: childRoot.path))
    }

    func testLegacyStartupWithDefaultSuitesPreservesSettingsAndConfiguresStorage() throws {
        standard.set("dark", forKey: "appearance")
        standard.set(["claude"], forKey: "openusage.enabledProviders.v1")
        telemetry.set(false, forKey: "enabled")
        let originalStandard = standardDomain()
        let originalTelemetry = NSDictionary(dictionary: telemetry.persistentDomain(forName: bundleIdentifier + ".telemetry") ?? [:])

        let fresh = try StorageBootstrap.prepare(
            bundleIdentifier: bundleIdentifier,
            databaseURL: databaseURL,
            applicationSupportDirectory: applicationSupport
        )

        XCTAssertFalse(fresh)
        XCTAssertEqual(AppPreferences.standard.string(forKey: "appearance"), "dark")
        XCTAssertEqual(AppPreferences.standard.stringArray(forKey: "openusage.enabledProviders.v1"), ["claude"])
        XCTAssertEqual(AppPreferences.telemetry.object(forKey: "enabled") as? Bool, false)
        XCTAssertNoThrow(try AppPreferences.standard.checkError())
        XCTAssertNoThrow(try CacheStore.resolve(nil))
        XCTAssertEqual(standardDomain(), originalStandard)
        XCTAssertEqual(NSDictionary(dictionary: telemetry.persistentDomain(forName: bundleIdentifier + ".telemetry") ?? [:]), originalTelemetry)
    }

    func testExistingSQLiteStartupWithDefaultSuitesKeepsMigratedValues() throws {
        standard.set("dark", forKey: "appearance")
        XCTAssertFalse(try prepare())
        AppPreferences.standard.set("light", forKey: "appearance")
        AppPreferences.unconfigureStandard()
        CacheStore.configure(nil)
        standard.set("system", forKey: "appearance")

        XCTAssertFalse(try StorageBootstrap.prepare(
            bundleIdentifier: bundleIdentifier,
            databaseURL: databaseURL,
            applicationSupportDirectory: applicationSupport
        ))

        XCTAssertEqual(AppPreferences.standard.string(forKey: "appearance"), "light")
        XCTAssertNoThrow(try AppPreferences.standard.checkError())
        XCTAssertNoThrow(try CacheStore.resolve(nil))
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
