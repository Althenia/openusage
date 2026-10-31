import Foundation
import SQLite3
import XCTest
@testable import OpenUsage

private final class TestPreferencesRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var directories: [URL] = []
    private var exitHookInstalled = false

    func track(_ directory: URL) {
        lock.lock()
        defer { lock.unlock() }
        directories.append(directory)
        if !exitHookInstalled {
            exitHookInstalled = true
            atexit { TestPreferences.removeAll() }
        }
    }

    func removeAll() {
        lock.lock()
        let pending = directories
        directories = []
        lock.unlock()
        for directory in pending { try? FileManager.default.removeItem(at: directory) }
    }
}

enum TestPreferences {
    private static let registry = TestPreferencesRegistry()

    static func makeStore(_ name: String = "") -> SQLiteStore {
        let label = name.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTestPreferences-\(label)-\(UUID().uuidString)", isDirectory: true)
        registry.track(directory)
        return try! SQLiteStore(url: directory.appendingPathComponent("preferences.db"))
    }

    static func make(_ name: String = "", namespace: String = "app") -> AppPreferences {
        AppPreferences(store: makeStore(name), namespace: namespace)
    }

    static func make(sharing store: SQLiteStore, namespace: String) -> AppPreferences {
        AppPreferences(store: store, namespace: namespace)
    }

    fileprivate static func removeAll() {
        registry.removeAll()
    }
}

extension XCTestCase {
    func configureStandardPreferences(_ preferences: AppPreferences) {
        AppPreferences.configureStandard(preferences)
        addTeardownBlock { AppPreferences.unconfigureStandard() }
    }
}

enum StorageTestDirectory {
    static func make() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageStorageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

struct RawSQLiteError: Error {
    let message: String
}

final class RawSQLiteConnection {
    private var handle: OpaquePointer?

    init(url: URL, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let error = failure("open")
            close()
            throw error
        }
    }

    deinit {
        close()
    }

    private func failure(_ operation: String) -> RawSQLiteError {
        guard let handle else { return RawSQLiteError(message: "\(operation) failed: no connection") }
        let message = String(cString: sqlite3_errmsg(handle))
        return RawSQLiteError(
            message: "\(operation) failed (code \(sqlite3_errcode(handle)), extended \(sqlite3_extended_errcode(handle))): \(message)"
        )
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let detail = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw RawSQLiteError(message: "\(sql) failed: \(detail)")
        }
    }

    func userVersion() throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else {
            throw failure("prepare")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw failure("step")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func flushCache() throws {
        guard sqlite3_db_cacheflush(handle) == SQLITE_OK else {
            throw failure("cacheflush")
        }
    }

    func scalarText(_ sql: String) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw failure("prepare")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw failure("step")
        }
        return sqlite3_column_text(statement, 0).map { String(cString: $0) }
    }

    func close() {
        if let handle {
            sqlite3_close(handle)
            self.handle = nil
        }
    }
}

struct DatabaseLogicalState: Equatable {
    var payload: [String: Data]
    var sidecarNames: Set<String>
    var permissions: [String: Int]
}

enum DatabaseFiles {
    static func logicalState(of databaseURL: URL) throws -> DatabaseLogicalState {
        let directory = databaseURL.deletingLastPathComponent()
        let all = try bytes(of: databaseURL)
        var payload: [String: Data] = [:]
        var permissions: [String: Int] = [:]
        for (name, data) in all {
            permissions[name] = try Self.permissions(of: directory.appendingPathComponent(name))
            if !name.hasSuffix("-shm") { payload[name] = data }
        }
        return DatabaseLogicalState(payload: payload, sidecarNames: Set(all.keys), permissions: permissions)
    }

    static func bytes(of databaseURL: URL) throws -> [String: Data] {
        let directory = databaseURL.deletingLastPathComponent()
        let prefix = databaseURL.lastPathComponent
        var result: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path)
        where name.hasPrefix(prefix) {
            result[name] = try Data(contentsOf: directory.appendingPathComponent(name))
        }
        return result
    }

    static func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

struct FileTreeSnapshot: Equatable {
    struct Entry: Equatable {
        var data: Data?
        var modified: Date?
    }

    var entries: [String: Entry]

    static func capture(_ root: URL) throws -> FileTreeSnapshot {
        let base = root.resolvingSymlinksInPath()
        var entries: [String: Entry] = [:]
        let enumerator = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: []
        )
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            let relative = String(url.path.dropFirst(base.path.count))
            if values.isDirectory == true {
                entries[relative] = Entry(data: nil, modified: nil)
            } else {
                entries[relative] = Entry(
                    data: try Data(contentsOf: url),
                    modified: values.contentModificationDate
                )
            }
        }
        return FileTreeSnapshot(entries: entries)
    }
}

func legacyFingerprint(_ value: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return String(format: "%016llx", hash)
}

struct FrozenScanFile: Codable {
    var size: Int
    var mtime: Date
    var recordFileName: String
}

struct FrozenScanManifest: Codable {
    var formatVersion: Int
    var schemaVersion: Int
    var identity: String
    var generatedAt: Date
    var files: [String: FrozenScanFile]
}

struct FrozenScanRecord: Codable {
    var path: String
    var size: Int
    var mtime: Date
    var items: [Int]
}

struct ScanCacheFixture {
    let identity: String
    let sourcePath: String
    let directoryName: String
    let manifestURL: URL
    let recordURL: URL
    let recordFileName: String

    var storeNamespace: String { "log-scan/\(directoryName)" }
    var recordKey: String { "file/\(recordFileName)" }
}

struct LegacyFixture {
    static let strings: [String: String] = [
        "appearance": "dark",
        "timeFormat": "24h",
        "logLevel": "debug",
        "density": "compact",
        "openusage.codex.fallbackModel": "synthetic-model",
        "openusage.icloudSync.deviceID.v1": "synthetic-device-1",
        "openusage.totalSpend.metric": "cost",
        "openusage.totalSpend.period": "month",
        "openusage.layout.v1.menuBarStyle": "text",
        "copilot.billingOrg": "synthetic-org",
        "meterStyle": "used",
        "resetDisplayMode": "relative"
    ]

    static let bools: [String: Bool] = [
        "reduceAnimations": true,
        "showTotalSpend": false,
        "hideUsageWhileScreenSharing": true,
        "increaseTransparency": false,
        "betaUpdatesEnabled": true,
        "openusage.icloudSync.enabled.v1": true,
        "openusage.notifications.closeToRunningOut": true,
        "openusage.notifications.healthyToClose": false,
        "openusage.notifications.underTenPercent": true,
        "openusage.onboarding.welcomePending": false,
        "openusage.onboarding.customizeHintPending": true,
        "alwaysShowPacing": true
    ]

    static let integers: [String: Int] = [
        "openusage.settings.schemaVersion": 2
    ]

    static let doubles: [String: Double] = [
        "openusage.panel.height.dashboard": 520.5,
        "openusage.panel.height.customize": 480.25,
        "openusage.panel.height.settings": 400.0
    ]

    static let stringArrays: [String: [String]] = [
        "openusage.enabledProviders.v1": ["claude", "codex"],
        "openusage.knownProviders.v1": ["claude", "codex", "cursor"],
        "openusage.disabledProviders.v1": ["cursor"],
        "openusage.layout.v1.menuBarPins": ["claude.session"],
        "openusage.layout.v1.expandedMetrics": ["codex.weekly"],
        "openusage.layout.v1.expandOnEnable": ["cursor.spend"],
        "openusage.layout.v1.expandedProviders": ["claude"]
    ]

    static let snapshotCacheKey = "openusage.providerSnapshots.v9"
    static let shellSnapshotKey = "openusage.shellEnvSnapshot.v2"
    static let layoutKey = "openusage.layout.v1"
    static let deadMetricID = "antigravity.session"

    static let dataKeys: [String] = [
        layoutKey,
        "openusage.layout.v1.providerOrder",
        "openusage.layout.v1.metricOrderByProvider",
        "openusage.layout.v1.seededDefaults",
        "openusage.providerAccounts.v1",
        "openusage.providerProfiles.v1",
        shellSnapshotKey,
        snapshotCacheKey
    ]

    static let unknownStandard: [String: String] = [
        "openusage.future.unknown": "unknown-value",
        "openusage.apiKey.claude": "sentinel-credential-api-key",
        "SUPublicEDKey": "sentinel-signing-key",
        "SUEnableAutomaticChecks": "sentinel-sparkle-flag",
        "oauth:tokenCache": "sentinel-oauth-token",
        "installID": "sentinel-install-in-standard"
    ]

    static let telemetryInstallID = "install-synthetic-1"
    static let telemetryActiveDay = DailyUsageAccumulator.dayKey(from: Date(timeIntervalSince1970: 1_800_000_000))
    static let telemetryProviderDays = Data(#"{"claude":["\#(telemetryActiveDay)"]}"#.utf8)
    static let unknownTelemetry: [String: String] = [
        "secretToken": "sentinel-telemetry-secret"
    ]

    static let fileCredentialSentinel = "sentinel-file-credential"

    let root: URL
    let databaseURL: URL
    let applicationSupport: URL
    let standardSuite: String
    let telemetrySuite: String
    let standard: UserDefaults
    let telemetry: UserDefaults
    let dataValues: [String: Data]
    let scanCaches: [ScanCacheFixture]
    let cursorUserID: String
    let cursorFileURL: URL
    let pricingDirectory: URL
    let pricingFiles: [String: Data]

    var openUsageDirectory: URL { applicationSupport.appendingPathComponent("OpenUsage", isDirectory: true) }
    var cursorKey: String { legacyFingerprint(cursorUserID) }

    static func make() throws -> LegacyFixture {
        let root = try StorageTestDirectory.make()
        let applicationSupport = root.appendingPathComponent("ApplicationSupport", isDirectory: true)
        let openUsage = applicationSupport.appendingPathComponent("OpenUsage", isDirectory: true)
        let standardSuite = "OpenUsageStorageTests.standard.\(UUID().uuidString)"
        let telemetrySuite = "OpenUsageStorageTests.telemetry.\(UUID().uuidString)"
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardSuite))
        let telemetry = try XCTUnwrap(UserDefaults(suiteName: telemetrySuite))
        standard.removePersistentDomain(forName: standardSuite)
        telemetry.removePersistentDomain(forName: telemetrySuite)

        for (key, value) in strings { standard.set(value, forKey: key) }
        for (key, value) in bools { standard.set(value, forKey: key) }
        for (key, value) in integers { standard.set(value, forKey: key) }
        for (key, value) in doubles { standard.set(value, forKey: key) }
        for (key, value) in stringArrays { standard.set(value, forKey: key) }
        for (key, value) in unknownStandard { standard.set(value, forKey: key) }

        let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
        let dayKey = DailyUsageAccumulator.dayKey(from: fixedDate)
        let frozenSnapshotCache: [String: Any] = [
            "snapshots": [
                "claude": [
                    "providerID": "claude",
                    "displayName": "Claude",
                    "lines": [Any](),
                    "refreshedAt": "2027-01-15T08:00:00Z",
                    "usageHistory": [
                        "series": ["daily": [["date": dayKey, "totalTokens": 100, "costUSD": 1.5] as [String: Any]]],
                        "unknownModelsByDay": [String: Any]()
                    ] as [String: Any]
                ] as [String: Any]
            ],
            "producedByIdentityKeys": ["claude": "identity-synthetic"]
        ]
        let frozenShellSnapshot: [String: Any] = [
            "values": ["CODEX_HOME": "/synthetic/codex"],
            "capturedAt": 800_000_000.0
        ]

        let encoder = JSONEncoder()
        var dataValues: [String: Data] = [:]
        dataValues[layoutKey] = Data(
            #"[{"id":"00000000-0000-0000-0000-000000000001","descriptorID":"\#(deadMetricID)"}]"#.utf8
        )
        dataValues["openusage.layout.v1.providerOrder"] = try encoder.encode(["codex", "claude"])
        dataValues["openusage.layout.v1.metricOrderByProvider"] = try encoder.encode(["claude": [deadMetricID]])
        dataValues["openusage.layout.v1.seededDefaults"] = try encoder.encode([deadMetricID])
        dataValues["openusage.providerAccounts.v1"] = Data("[]".utf8)
        dataValues["openusage.providerProfiles.v1"] = Data(#"[]"#.utf8)
        dataValues[shellSnapshotKey] = try JSONSerialization.data(
            withJSONObject: frozenShellSnapshot, options: [.sortedKeys]
        )
        dataValues[snapshotCacheKey] = try JSONSerialization.data(
            withJSONObject: frozenSnapshotCache, options: [.sortedKeys]
        )
        for (key, value) in dataValues { standard.set(value, forKey: key) }

        telemetry.set(telemetryInstallID, forKey: "installID")
        telemetry.set(false, forKey: "enabled")
        telemetry.set(telemetryActiveDay, forKey: "activeDay")
        telemetry.set(telemetryProviderDays, forKey: "providerDays")
        for (key, value) in unknownTelemetry { telemetry.set(value, forKey: key) }

        var scanCaches: [ScanCacheFixture] = []
        let scanCacheDirectory = openUsage.appendingPathComponent("log-scan-cache", isDirectory: true)
        for (namespace, identity) in [("claude", "synthetic-claude-home"), ("codex", "synthetic-codex-home")] {
            let sourcePath = "/synthetic/\(namespace)/session.jsonl"
            let mtime = Date(timeIntervalSince1970: 1_700_000_000)
            let recordFileName = "\(legacyFingerprint(sourcePath)).plist"
            let directoryName = "\(namespace)-\(legacyFingerprint(identity))"
            let identityDirectory = scanCacheDirectory.appendingPathComponent(directoryName, isDirectory: true)
            let manifest = FrozenScanManifest(
                formatVersion: 1,
                schemaVersion: 1,
                identity: identity,
                generatedAt: mtime,
                files: [sourcePath: FrozenScanFile(size: 12, mtime: mtime, recordFileName: recordFileName)]
            )
            let record = FrozenScanRecord(path: sourcePath, size: 12, mtime: mtime, items: [1, 2, 3])
            let binary = PropertyListEncoder()
            binary.outputFormat = .binary
            let manifestURL = identityDirectory.appendingPathComponent("manifest.plist")
            let recordURL = identityDirectory.appendingPathComponent("files/\(recordFileName)")
            try write(try binary.encode(manifest), to: manifestURL)
            try write(try binary.encode(record), to: recordURL)
            scanCaches.append(ScanCacheFixture(
                identity: identity,
                sourcePath: sourcePath,
                directoryName: directoryName,
                manifestURL: manifestURL,
                recordURL: recordURL,
                recordFileName: recordFileName
            ))
        }
        try write(Data(), to: scanCacheDirectory.appendingPathComponent(".claude-synthetic.lock"))

        let cursorUserID = "cursor-user-synthetic"
        let cursorDirectory = openUsage.appendingPathComponent("cursor-usage-history", isDirectory: true)
        let frozenCursorHistory: [String: Any] = [
            "schemaVersion": 2,
            "userID": cursorUserID,
            "timeZone": "Asia/Bangkok",
            "days": [
                dayKey: [
                    "models": [
                        "composer-1": [
                            "input": 5, "cacheWrite5m": 0, "cacheWrite1h": 0,
                            "cacheRead": 0, "output": 7, "isFast": false
                        ] as [String: Any]
                    ],
                    "isComplete": true
                ] as [String: Any]
            ] as [String: Any]
        ]
        let cursorFileURL = cursorDirectory.appendingPathComponent("\(legacyFingerprint(cursorUserID)).json")
        try write(
            try JSONSerialization.data(withJSONObject: frozenCursorHistory, options: [.sortedKeys]),
            to: cursorFileURL
        )

        let pricingDirectory = openUsage.appendingPathComponent("pricing", isDirectory: true)
        let pricingFiles: [String: Data] = [
            "litellm.json": Data(#"{"synthetic-model":{"input":1}}"#.utf8),
            "models_dev.json": Data(#"{"synthetic-provider":{"models":{}}}"#.utf8),
            "supplement.json": Data(#"{"updated_at":"2026-01-01T00:00:00Z"}"#.utf8),
            "state.json": Data(#"[]"#.utf8)
        ]
        for (name, data) in pricingFiles {
            try write(data, to: pricingDirectory.appendingPathComponent(name))
        }
        try write(Data("not recognized".utf8), to: pricingDirectory.appendingPathComponent("notes.txt"))
        try write(
            Data(#"{"accessToken":"\#(fileCredentialSentinel)"}"#.utf8),
            to: openUsage.appendingPathComponent("unrelated/token.json")
        )
        try write(
            Data(#"{"accessToken":"\#(fileCredentialSentinel)"}"#.utf8),
            to: applicationSupport.appendingPathComponent("Claude/credentials.json")
        )

        return LegacyFixture(
            root: root,
            databaseURL: root.appendingPathComponent("data/openusage.db"),
            applicationSupport: applicationSupport,
            standardSuite: standardSuite,
            telemetrySuite: telemetrySuite,
            standard: standard,
            telemetry: telemetry,
            dataValues: dataValues,
            scanCaches: scanCaches,
            cursorUserID: cursorUserID,
            cursorFileURL: cursorFileURL,
            pricingDirectory: pricingDirectory,
            pricingFiles: pricingFiles
        )
    }

    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    func makeStore() throws -> SQLiteStore {
        try SQLiteStore(url: databaseURL)
    }

    func runImport(into store: SQLiteStore, beforeCommit: (() throws -> Void)? = nil) throws -> LegacyImportReport {
        try LegacyImport.run(
            store: store,
            standard: standard,
            telemetrySuite: telemetry,
            applicationSupportDirectory: applicationSupport,
            beforeCommit: beforeCommit
        )
    }

    func standardDomain() -> NSDictionary {
        NSDictionary(dictionary: standard.persistentDomain(forName: standardSuite) ?? [:])
    }

    func telemetryDomain() -> NSDictionary {
        NSDictionary(dictionary: telemetry.persistentDomain(forName: telemetrySuite) ?? [:])
    }

    func cleanUp() {
        standard.removePersistentDomain(forName: standardSuite)
        telemetry.removePersistentDomain(forName: telemetrySuite)
        try? FileManager.default.removeItem(at: root)
    }
}
