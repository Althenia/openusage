import Foundation

struct CursorUsageDay: Codable, Sendable, Equatable {
    var models: [String: TokenBreakdown]
    var isComplete: Bool

    private enum CodingKeys: String, CodingKey {
        case models
        case isComplete
    }

    init(models: [String: TokenBreakdown], isComplete: Bool) {
        self.models = models
        self.isComplete = isComplete
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        models = try container.decode([String: TokenBreakdown].self, forKey: .models)
        isComplete = try container.decodeIfPresent(Bool.self, forKey: .isComplete) ?? false
    }

    mutating func add(_ tokens: TokenBreakdown, for model: String) {
        var existing = models[model] ?? TokenBreakdown()
        existing.input += tokens.input
        existing.cacheWrite5m += tokens.cacheWrite5m
        existing.cacheWrite1h += tokens.cacheWrite1h
        existing.cacheRead += tokens.cacheRead
        existing.output += tokens.output
        existing.isFast = existing.isFast || tokens.isFast
        models[model] = existing
    }
}

struct CursorUsageHistoryStore: Sendable {
    private struct File: Codable {
        var schemaVersion: Int
        var userID: String
        var timeZone: String
        var days: [String: CursorUsageDay]
    }

    static let namespace = "cursor-usage-history"
    private static let schemaVersion = 2

    private var store: SQLiteStore?

    init(store: SQLiteStore? = nil) {
        self.store = store
    }

    func load(userID: String, timeZone: String) -> [String: CursorUsageDay] {
        do {
            let store = try CacheStore.resolve(store)
            guard let data = try store.data(namespace: Self.namespace, key: key(userID: userID)) else {
                return [:]
            }
            let file = try JSONDecoder().decode(File.self, from: data)
            guard file.schemaVersion == Self.schemaVersion,
                  file.userID == userID,
                  file.timeZone == timeZone
            else {
                return [:]
            }
            return file.days
        } catch {
            AppLog.warn(LogTag.plugin("cursor"), "usage history cache could not be read")
            return [:]
        }
    }

    func save(_ days: [String: CursorUsageDay], userID: String, timeZone: String) {
        let file = File(
            schemaVersion: Self.schemaVersion,
            userID: userID,
            timeZone: timeZone,
            days: days
        )
        do {
            let store = try CacheStore.resolve(store)
            try store.set(
                try JSONEncoder().encode(file),
                namespace: Self.namespace,
                key: key(userID: userID)
            )
        } catch {
            AppLog.warn(LogTag.plugin("cursor"), "usage history cache could not be saved")
        }
    }

    private func key(userID: String) -> String {
        JSONLScanCachePaths.stableFingerprint(userID)
    }
}
