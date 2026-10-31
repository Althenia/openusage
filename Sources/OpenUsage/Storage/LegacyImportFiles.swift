import Foundation

extension LegacyImport {
    static let pricingFileNames = ["litellm.json", "models_dev.json", "supplement.json", "state.json"]
    static let scanCacheNamespaces: Set<String> = ["claude", "codex", "grok", "pi"]

    static func importPricing(root: URL, store: SQLiteStore) throws -> Int {
        let directory = root.appendingPathComponent("pricing", isDirectory: true)
        var count = 0
        for name in pricingFileNames {
            guard let data = try readIfPresent(directory.appendingPathComponent(name)) else { continue }
            try validateJSON(data, name: name, requiresContainer: true)
            guard try store.data(namespace: "pricing", key: name) == nil else { continue }
            try store.set(data, namespace: "pricing", key: name)
            count += 1
        }
        return count
    }

    static func importCursorUsageHistory(root: URL, store: SQLiteStore) throws -> Int {
        let directory = root.appendingPathComponent("cursor-usage-history", isDirectory: true)
        var count = 0
        for url in try visibleEntries(of: directory) {
            let name = url.lastPathComponent
            guard name.hasSuffix(".json") else { continue }
            let key = String(name.dropLast(".json".count))
            guard isFingerprint(key) else { continue }
            guard let data = try readIfPresent(url) else { throw LegacyImportError.unreadable(name) }
            try validateJSON(data, name: name, requiresContainer: true)
            guard try store.data(namespace: "cursor-usage-history", key: key) == nil else { continue }
            try store.set(data, namespace: "cursor-usage-history", key: key)
            count += 1
        }
        return count
    }

    static func importLogScanCaches(root: URL, store: SQLiteStore) throws -> Int {
        let directory = root.appendingPathComponent("log-scan-cache", isDirectory: true)
        var count = 0
        for url in try visibleEntries(of: directory) {
            let name = url.lastPathComponent
            guard isScanCacheDirectoryName(name),
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            guard let manifestData = try readIfPresent(url.appendingPathComponent("manifest.plist")) else {
                continue
            }
            let manifestName = "\(name)/manifest.plist"
            try validatePropertyList(manifestData, name: manifestName)
            let manifest: JSONLScanCacheManifest
            do {
                manifest = try PropertyListDecoder().decode(JSONLScanCacheManifest.self, from: manifestData)
            } catch {
                throw LegacyImportError.malformed(manifestName)
            }
            var records: [String: Data] = [:]
            for metadata in manifest.files.values {
                let fileName = metadata.recordFileName
                guard isRecordFileName(fileName) else { throw LegacyImportError.malformed(manifestName) }
                guard records[fileName] == nil else { continue }
                let recordName = "\(name)/files/\(fileName)"
                let recordURL = url.appendingPathComponent("files", isDirectory: true)
                    .appendingPathComponent(fileName)
                guard let data = try readIfPresent(recordURL) else {
                    throw LegacyImportError.unreadable(recordName)
                }
                try validatePropertyList(data, name: recordName)
                records[fileName] = data
            }
            let namespace = "\(JSONLScanCachePaths.storeNamespacePrefix)\(name)"
            guard try store.data(namespace: namespace, key: JSONLScanCachePaths.manifestKey) == nil else {
                continue
            }
            for fileName in records.keys.sorted() {
                try store.set(
                    records[fileName] ?? Data(),
                    namespace: namespace,
                    key: JSONLScanCachePaths.recordKey(fileName: fileName)
                )
            }
            try store.set(manifestData, namespace: namespace, key: JSONLScanCachePaths.manifestKey)
            count += 1
        }
        return count
    }

    private static func visibleEntries(of directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        do {
            return try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw LegacyImportError.unreadable(directory.lastPathComponent)
        }
    }

    private static func readIfPresent(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw LegacyImportError.unreadable(url.lastPathComponent)
        }
    }

    private static func validateJSON(_ data: Data, name: String, requiresContainer: Bool) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              !requiresContainer || object is [Any] || object is [String: Any]
        else { throw LegacyImportError.malformed(name) }
    }

    private static func validatePropertyList(_ data: Data, name: String) throws {
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format),
              format != .openStep,
              value is [String: Any]
        else { throw LegacyImportError.malformed(name) }
    }

    private static func isFingerprint(_ value: String) -> Bool {
        value.count == 16 && value.allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }
    }

    private static func isScanCacheDirectoryName(_ name: String) -> Bool {
        guard let separator = name.lastIndex(of: "-") else { return false }
        return scanCacheNamespaces.contains(String(name[..<separator]))
            && isFingerprint(String(name[name.index(after: separator)...]))
    }

    private static func isRecordFileName(_ name: String) -> Bool {
        name.hasSuffix(".plist") && name == (name as NSString).lastPathComponent
    }
}
