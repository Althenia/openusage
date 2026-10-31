import Foundation

struct LegacyImportReport: Sendable, Equatable {
    var didImport: Bool
    var counts: [String: Int]
}

enum LegacyImportError: LocalizedError {
    case unreadable(String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): "Legacy data \(name) could not be read."
        case .malformed(let name): "Legacy data \(name) is not in a recognized format."
        }
    }
}

enum LegacyImport {
    static let markerNamespace = "store.migrations"
    static let markerKey = "import.legacy.v1"
    static let markerVersion = 1

    static func run(
        store: SQLiteStore,
        standard: UserDefaults,
        telemetrySuite: UserDefaults,
        applicationSupportDirectory: URL,
        standardDomainName: String? = nil,
        telemetryDomainName: String? = nil,
        beforeCommit: (() throws -> Void)? = nil
    ) throws -> LegacyImportReport {
        return try store.transaction { store in
            if try store.data(namespace: markerNamespace, key: markerKey) != nil {
                return LegacyImportReport(didImport: false, counts: [:])
            }
            let root = applicationSupportDirectory.appendingPathComponent("OpenUsage", isDirectory: true)
            var counts: [String: Int] = [:]
            counts["settings"] = try importPreferences(
                keys: LegacyImportKeys.application,
                namespace: LegacyImportKeys.applicationNamespace,
                reader: DefaultsReader(defaults: standard, domainName: standardDomainName),
                store: store
            )
            counts["telemetry"] = try importPreferences(
                keys: LegacyImportKeys.telemetry,
                namespace: LegacyImportKeys.telemetryNamespace,
                reader: DefaultsReader(defaults: telemetrySuite, domainName: telemetryDomainName),
                store: store
            )
            counts["pricing"] = try importPricing(root: root, store: store)
            counts["cursorUsageHistory"] = try importCursorUsageHistory(root: root, store: store)
            counts["logScan"] = try importLogScanCaches(root: root, store: store)
            try beforeCommit?()
            try store.set(
                try markerData(counts: counts),
                namespace: markerNamespace,
                key: markerKey
            )
            return LegacyImportReport(didImport: true, counts: counts)
        }
    }

    private static func markerData(counts: [String: Int]) throws -> Data {
        let marker: [String: Any] = [
            "version": markerVersion,
            "importedAt": ISO8601DateFormatter().string(from: Date()),
            "counts": counts
        ]
        return try JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys])
    }

    private struct DefaultsReader {
        let defaults: UserDefaults
        let domain: [String: Any]?

        init(defaults: UserDefaults, domainName: String?) {
            self.defaults = defaults
            self.domain = domainName.map { defaults.persistentDomain(forName: $0) ?? [:] }
        }

        func value(forKey key: String) -> Any? {
            if let domain { return domain[key] }
            return defaults.object(forKey: key)
        }
    }

    private static func importPreferences(
        keys: [String: LegacyValueKind],
        namespace: String,
        reader: DefaultsReader,
        store: SQLiteStore
    ) throws -> Int {
        let preferences = AppPreferences(store: store, namespace: namespace)
        var count = 0
        for (key, kind) in keys.sorted(by: { $0.key < $1.key }) {
            guard let raw = reader.value(forKey: key) else { continue }
            let value = try kind.validated(raw, key: key)
            guard preferences.object(forKey: key) == nil else { continue }
            try preferences.trySet(value, forKey: key)
            count += 1
        }
        try preferences.checkError()
        return count
    }
}
