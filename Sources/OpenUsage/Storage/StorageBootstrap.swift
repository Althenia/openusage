import Foundation

@MainActor
enum StorageBootstrap {
    static func prepare(
        bundleIdentifier: String,
        databaseURL: URL? = nil,
        standard: UserDefaults? = nil,
        telemetrySuite: UserDefaults? = nil,
        applicationSupportDirectory: URL? = nil
    ) throws -> Bool {
        let url = databaseURL ?? SQLiteStoreLocation.databaseURL(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            bundleIdentifier: bundleIdentifier
        )
        let store = try SQLiteStore(url: url)
        guard let standard = standard ?? UserDefaults(suiteName: bundleIdentifier),
              let telemetry = telemetrySuite ?? UserDefaults(suiteName: bundleIdentifier + ".telemetry") else {
            throw SQLiteStoreError.notConfigured
        }
        _ = try LegacyImport.run(
            store: store,
            standard: standard,
            telemetrySuite: telemetry,
            applicationSupportDirectory: applicationSupportDirectory ?? FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            )[0],
            standardDomainName: bundleIdentifier,
            telemetryDomainName: bundleIdentifier + ".telemetry"
        )
        let preferences = AppPreferences(store: store, namespace: "app")
        let isFreshInstall = preferences.isEmpty
        try preferences.checkError()
        let settingsVersion = SettingsMigrator.migrate(defaults: preferences)
        try preferences.checkError()
        guard settingsVersion >= SettingsSchema.current else {
            throw StorageBootstrapError.settingsUpgradeFailed
        }
        if isFreshInstall { FirstLaunchSetup.markPending(defaults: preferences) }
        try preferences.checkError()
        let cacheStore = try SQLiteStore(url: url)
        CacheStore.configure(cacheStore)
        AppPreferences.configureStandard(preferences)
        return isFreshInstall
    }
}

private enum StorageBootstrapError: LocalizedError {
    case settingsUpgradeFailed

    var errorDescription: String? {
        "Local settings could not be upgraded. Existing data has been retained."
    }
}
