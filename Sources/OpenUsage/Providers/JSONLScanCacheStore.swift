import Foundation
import os

/// Disk policy for one JSONL parser. `namespace` identifies the provider/parser; the scanner adds a
/// stable provider/home identity below it. Bump `schemaVersion` whenever the persisted item meaning
/// changes, including changes to nested values such as `TokenBreakdown`.
struct JSONLScanCachePersistence: Sendable {
    var namespace: String
    var schemaVersion: Int
    var store: SQLiteStore?
    var writeDebounce: Duration

    init(
        namespace: String,
        schemaVersion: Int,
        store: SQLiteStore? = nil,
        writeDebounce: Duration = .seconds(2)
    ) {
        precondition(!namespace.isEmpty)
        precondition(namespace.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" })
        precondition(schemaVersion > 0)
        self.namespace = namespace
        self.schemaVersion = schemaVersion
        self.store = store
        self.writeDebounce = writeDebounce
    }

    func resolvedStore() throws -> SQLiteStore {
        try CacheStore.resolve(store)
    }
}

enum CacheStore {
    private static let configured = OSAllocatedUnfairLock(initialState: Optional<SQLiteStore>.none)

    static func configure(_ store: SQLiteStore?) {
        configured.withLock { $0 = store }
    }

    static func resolve(_ store: SQLiteStore?) throws -> SQLiteStore {
        guard let resolved = store ?? configured.withLock({ $0 }) else {
            throw SQLiteStoreError.notConfigured
        }
        return resolved
    }
}

struct JSONLScanCacheFileMetadata: Codable, Sendable, Equatable {
    var size: Int
    var mtime: Date
    var recordFileName: String
}

struct JSONLScanCacheManifest: Codable, Sendable {
    var formatVersion: Int
    var schemaVersion: Int
    var identity: String
    /// Diagnostic/retention timestamp for the last successful lock-scoped manifest merge.
    var generatedAt: Date
    var files: [String: JSONLScanCacheFileMetadata]
}

struct JSONLScanCacheUpsert: Sendable {
    var metadata: JSONLScanCacheFileMetadata
    var recordData: Data
}

struct JSONLScanCacheWriteBatch: Sendable {
    var persistence: JSONLScanCachePersistence
    var identity: String
    /// Only new or changed source paths are present. The writer verifies each path's current stat before
    /// publishing it, so a slow process cannot replace a newer parse of the same source file.
    var upserts: [String: JSONLScanCacheUpsert]
    /// A removal applies only while the on-disk metadata still equals the value this scanner observed.
    /// Paths added or changed by another app/CLI process are therefore preserved.
    var removals: [String: JSONLScanCacheFileMetadata]
}

struct JSONLScanCacheCommitResult: Sendable {
    var manifest: JSONLScanCacheManifest
    var acceptedUpsertPaths: Set<String>
}

struct JSONLScanCacheRecord<Item: Codable & Sendable>: Codable, Sendable {
    var path: String
    var size: Int
    var mtime: Date
    var items: [Item]
}

struct JSONLScanCachedFile<Item: Codable & Sendable>: Sendable {
    var size: Int
    var mtime: Date
    var items: [Item]
}

struct JSONLScanCacheReadSnapshot<Item: Codable & Sendable>: Sendable {
    var manifest: JSONLScanCacheManifest
    var files: [String: JSONLScanCachedFile<Item>]
    var invalidRecords: [String: JSONLScanCacheFileMetadata]
}

enum JSONLScanCachePaths {
    static let formatVersion = 1
    static let staleIdentityRetention: TimeInterval = 35 * 86_400
    static let manifestKey = "manifest"
    static let recordKeyPrefix = "file/"
    static let storeNamespacePrefix = "log-scan/"

    static func storeNamespace(persistence: JSONLScanCachePersistence, identity: String) -> String {
        "\(storeNamespacePrefix)\(persistence.namespace)-\(stableFingerprint(identity))"
    }

    static func recordKey(fileName: String) -> String {
        "\(recordKeyPrefix)\(fileName)"
    }

    static func recordFileName(path: String) -> String {
        "\(stableFingerprint(path)).plist"
    }

    static func stableFingerprint(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}

actor JSONLScanCacheWriter {
    static let shared = JSONLScanCacheWriter()

    func commit(_ batch: JSONLScanCacheWriteBatch) throws -> JSONLScanCacheCommitResult {
        let persistence = batch.persistence
        let identity = batch.identity
        let store = try persistence.resolvedStore()
        let namespace = JSONLScanCachePaths.storeNamespace(persistence: persistence, identity: identity)

        return try store.transaction { store in
            let current = try Self.readManifest(store: store, namespace: namespace)
            var mergedFiles: [String: JSONLScanCacheFileMetadata]
            if current?.formatVersion == JSONLScanCachePaths.formatVersion,
               current?.schemaVersion == persistence.schemaVersion,
               current?.identity == identity
            {
                mergedFiles = current?.files ?? [:]
            } else {
                mergedFiles = [:]
            }

            for (path, expectedMetadata) in batch.removals
                where mergedFiles[path] == expectedMetadata
            {
                mergedFiles[path] = nil
            }

            var acceptedUpsertPaths: Set<String> = []
            for (path, upsert) in batch.upserts
                where Self.sourceMatches(path: path, metadata: upsert.metadata)
            {
                try store.set(
                    upsert.recordData,
                    namespace: namespace,
                    key: JSONLScanCachePaths.recordKey(fileName: upsert.metadata.recordFileName)
                )
                mergedFiles[path] = upsert.metadata
                acceptedUpsertPaths.insert(path)
            }

            let manifest = JSONLScanCacheManifest(
                formatVersion: JSONLScanCachePaths.formatVersion,
                schemaVersion: persistence.schemaVersion,
                identity: identity,
                generatedAt: Date(),
                files: mergedFiles
            )
            if mergedFiles.isEmpty {
                try store.removeNamespace(namespace)
                return JSONLScanCacheCommitResult(
                    manifest: manifest,
                    acceptedUpsertPaths: acceptedUpsertPaths
                )
            }

            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try store.set(
                try encoder.encode(manifest),
                namespace: namespace,
                key: JSONLScanCachePaths.manifestKey
            )

            let referenced = Set(mergedFiles.values.map {
                JSONLScanCachePaths.recordKey(fileName: $0.recordFileName)
            })
            for key in try store.keys(namespace: namespace)
                where key.hasPrefix(JSONLScanCachePaths.recordKeyPrefix) && !referenced.contains(key)
            {
                try store.remove(namespace: namespace, key: key)
            }
            return JSONLScanCacheCommitResult(
                manifest: manifest,
                acceptedUpsertPaths: acceptedUpsertPaths
            )
        }
    }

    nonisolated func load<Item: Codable & Sendable>(
        persistence: JSONLScanCachePersistence,
        identity: String,
        itemType: Item.Type
    ) throws -> JSONLScanCacheReadSnapshot<Item>? {
        _ = itemType
        let store = try persistence.resolvedStore()
        let namespace = JSONLScanCachePaths.storeNamespace(persistence: persistence, identity: identity)
        return try store.transaction { store in
            guard let manifestData = try store.data(
                namespace: namespace,
                key: JSONLScanCachePaths.manifestKey
            ) else { return nil }
            let manifest = try PropertyListDecoder().decode(
                JSONLScanCacheManifest.self,
                from: manifestData
            )
            var files: [String: JSONLScanCachedFile<Item>] = [:]
            var invalidRecords: [String: JSONLScanCacheFileMetadata] = [:]
            if manifest.formatVersion == JSONLScanCachePaths.formatVersion,
               manifest.schemaVersion == persistence.schemaVersion,
               manifest.identity == identity
            {
                files.reserveCapacity(manifest.files.count)
                let recordDecoder = PropertyListDecoder()
                for (path, metadata) in manifest.files {
                    guard let data = try store.data(
                        namespace: namespace,
                        key: JSONLScanCachePaths.recordKey(fileName: metadata.recordFileName)
                    ),
                          let record = try? recordDecoder.decode(
                              JSONLScanCacheRecord<Item>.self,
                              from: data
                          ),
                          record.path == path,
                          record.size == metadata.size,
                          record.mtime == metadata.mtime
                    else {
                        invalidRecords[path] = metadata
                        continue
                    }
                    files[path] = JSONLScanCachedFile(
                        size: record.size,
                        mtime: record.mtime,
                        items: record.items
                    )
                }
            }
            do {
                try store.set(
                    manifestData,
                    namespace: namespace,
                    key: JSONLScanCachePaths.manifestKey
                )
            } catch {
                AppLog.warn(
                    .cache,
                    "could not mark \(persistence.namespace) log parse cache as used: \(error.localizedDescription)"
                )
            }
            return JSONLScanCacheReadSnapshot(
                manifest: manifest,
                files: files,
                invalidRecords: invalidRecords
            )
        }
    }

    func pruneStaleIdentities(
        persistence: JSONLScanCachePersistence,
        before cutoff: Date
    ) {
        do {
            let store = try persistence.resolvedStore()
            let prefix = "\(JSONLScanCachePaths.storeNamespacePrefix)\(persistence.namespace)-"
            for namespace in try store.namespaces(prefix: prefix) {
                try store.transaction { store in
                    guard let modified = try store.modifiedAt(
                        namespace: namespace,
                        key: JSONLScanCachePaths.manifestKey
                    ),
                    modified < cutoff
                    else { return }
                    try store.removeNamespace(namespace)
                }
            }
        } catch {
            AppLog.warn(
                .cache,
                "could not prune stale \(persistence.namespace) log parse cache: \(error.localizedDescription)"
            )
        }
    }

    private static func readManifest(store: SQLiteStore, namespace: String) throws -> JSONLScanCacheManifest? {
        guard let data = try store.data(namespace: namespace, key: JSONLScanCachePaths.manifestKey) else {
            return nil
        }
        return try? PropertyListDecoder().decode(JSONLScanCacheManifest.self, from: data)
    }

    private static func sourceMatches(
        path: String,
        metadata: JSONLScanCacheFileMetadata
    ) -> Bool {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys) else {
            return false
        }
        return values.isRegularFile == true
            && values.fileSize == metadata.size
            && values.contentModificationDate == metadata.mtime
    }
}
