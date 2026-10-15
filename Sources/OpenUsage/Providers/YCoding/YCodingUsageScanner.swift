import Foundation

/// Builds a per-day token/cost series from YCoding's local SQLite database for one OpenUsage card,
/// so usage that happened inside YCoding (e.g. a Claude subscription driven through YCoding) folds
/// into that card's spend tiles alongside its native source, the way pi usage folds in.
///
/// The database is live and multi-gigabyte, so reads go through the read-only SQLite accessor, are
/// bounded by the indexed `time_created` window, and aggregate per local day + model in SQL instead
/// of materializing one row per provider request. Because aggregation drops per-request boundaries,
/// unpriced (`cost IS NULL`) buckets are estimated without long-context tiers, matching Cursor's
/// aggregated history; rows carrying YCoding's own cost are summed as recorded.
struct YCodingUsageScanner: Sendable {
    static let shared = YCodingUsageScanner()

    private let sqlite: SQLiteAccessing
    private let files: TextFileAccessing
    private let databasePath: @Sendable () -> String
    private let readFailureReporter: UsageLogReadFailureReporter

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        databasePath: @escaping @Sendable () -> String = YCodingUsageScanner.defaultDatabasePath,
        readFailureWarning: UsageLogReadFailureReporter.Warning? = nil
    ) {
        self.sqlite = sqlite
        self.files = files
        self.databasePath = databasePath
        self.readFailureReporter = UsageLogReadFailureReporter(
            logTag: LogTag.plugin("ycoding"),
            warning: readFailureWarning
        )
    }

    static let defaultDatabasePath: @Sendable () -> String = {
        let dir = YCodingPaths.dataDirectory(
            environment: ProcessEnvironmentReader(),
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        return YCodingPaths.databasePath(dataDirectory: dir)
    }

    func scan(
        cardID: String, daysBack: Int = 30, now: Date = Date(), pricing: ModelPricing,
        attribution: YCodingAttribution = .all
    ) async -> LogUsageScan? {
        let providerIDs = YCodingProviderMapping.providerIDs(forCard: cardID)
        guard !providerIDs.isEmpty else { return nil }
        let path = databasePath()

        let targetIdentity: String?
        switch attribution {
        case .all:
            targetIdentity = nil
        case .claudeAccount(let identityKey):
            guard cardID == "claude", let identityKey = identityKey?.lowercased().nilIfEmpty else {
                await reportAttributionExclusions(count: 1)
                return nil
            }
            targetIdentity = identityKey
        }

        var rows: [Row]
        var attributionMap: YCodingClaudeAttributionMap?
        do {
            guard try hasRequestTable(in: path) else {
                await readFailureReporter.update(checkedPaths: [path], failingPaths: [])
                return nil
            }
            let cutoffMs = Int(JSONLScanning.sinceDate(daysBack: daysBack, now: now).timeIntervalSince1970 * 1000)
            let sql: String
            if targetIdentity != nil {
                let resolver = YCodingClaudeAttributionResolver(
                    sqlite: sqlite, files: files,
                    profilesDirectory: { Self.profilesDirectory(forDatabasePath: path) }
                )
                guard let loaded = try resolver.load(databasePath: path) else {
                    await reportAttributionExclusions(count: 1)
                    return nil
                }
                attributionMap = loaded
                sql = Self.attributedDataSQL(
                    cutoffMs: cutoffMs, providerIDs: providerIDs,
                    hasProfileBinding: try hasProfileBinding(in: path)
                )
            } else {
                sql = Self.dataSQL(cutoffMs: cutoffMs, providerIDs: providerIDs)
            }
            let json = try sqlite.queryValue(path: path, sql: sql)
            rows = json.map(Self.parseRows) ?? []
        } catch {
            let newlyFailing = await readFailureReporter.update(checkedPaths: [path], failingPaths: [path])
            if !newlyFailing.isEmpty {
                AppLog.warn(LogTag.plugin("ycoding"), "usage query failed for \(path): \(error.localizedDescription)")
            }
            return nil
        }
        await readFailureReporter.update(checkedPaths: [path], failingPaths: [])
        guard !Task.isCancelled else { return nil }

        if let targetIdentity, let attributionMap {
            let filtered = Self.attributed(rows: rows, map: attributionMap, targetIdentity: targetIdentity)
            rows = filtered.rows
            await reportAttributionExclusions(count: filtered.unresolvable)
        }
        return Self.aggregate(rows: rows, pricing: pricing)
    }

    private static let attributionMarker = "<ycoding profile attribution>"

    private func reportAttributionExclusions(count: Int) async {
        let newlyFailing = await readFailureReporter.update(
            checkedPaths: [Self.attributionMarker],
            failingPaths: count > 0 ? [Self.attributionMarker] : []
        )
        if !newlyFailing.isEmpty {
            AppLog.warn(
                LogTag.plugin("ycoding"),
                "some YCoding Claude usage could not be attributed to a Claude account and was left out"
            )
        }
    }

    static func attributed(
        rows: [Row], map: YCodingClaudeAttributionMap, targetIdentity: String
    ) -> (rows: [Row], unresolvable: Int) {
        var kept: [Row] = []
        var unresolvable = 0
        for row in rows {
            switch map.resolve(
                bindingCredentialID: row.bindingCredentialID,
                bindingProfile: row.bindingProfile,
                modelProfile: row.modelProfile
            ) {
            case .identity(let identity):
                if identity == targetIdentity { kept.append(row) }
            case .noProfile:
                if map.activeIdentityKey == targetIdentity {
                    kept.append(row)
                } else if map.activeIdentityKey == nil {
                    unresolvable += 1
                }
            case .unresolvable:
                unresolvable += 1
            }
        }
        return (kept, unresolvable)
    }

    static func profilesDirectory(forDatabasePath path: String) -> String {
        URL(fileURLWithPath: expandHome(path))
            .deletingLastPathComponent()
            .appendingPathComponent("claude-code/profiles")
            .path
    }

    static let profileBindingSQL =
        "SELECT COUNT(*) FROM pragma_table_info('session') WHERE name='profile_binding';"

    private func hasProfileBinding(in path: String) throws -> Bool {
        try sqlite.queryValue(path: path, sql: Self.profileBindingSQL) == "1"
    }

    static let requestTableSQL =
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='session_provider_request';"

    /// A missing database reads back as nil from the accessor, and a database without the request
    /// table has nothing to fold in; both are the "YCoding not in use" case, not a read failure.
    private func hasRequestTable(in path: String) throws -> Bool {
        try sqlite.queryValue(path: path, sql: Self.requestTableSQL) != nil
    }

    struct Row: Sendable, Equatable {
        var day: String
        var model: String
        var carriedCost: Double
        var carriedTokens: Int
        var unpricedTokens: TokenBreakdown
        var bindingCredentialID: String?
        var bindingProfile: String?
        var modelProfile: String?
    }

    /// Decodes `[day, modelID, carriedCost, carriedTokens, input, cacheWrite, cacheRead, output, reasoning]`
    /// where the token buckets cover only the rows whose recorded cost is NULL. The attributed query
    /// appends `bindingCredentialID, bindingProfile, modelProfile` at positions 9–11.
    static func parseRows(_ json: String) -> [Row] {
        guard let data = json.data(using: .utf8),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return [] }

        return payload.compactMap { element in
            guard let values = element as? [Any], values.count >= 9,
                  let day = (values[0] as? String)?.nilIfEmpty,
                  let carriedCost = ProviderParse.number(values[2]), carriedCost >= 0
            else { return nil }
            let tokens = TokenBreakdown(
                input: clampedTokens(values[4]),
                cacheWrite5m: clampedTokens(values[5]),
                cacheRead: clampedTokens(values[6]),
                output: clampedTokens(values[7]) + clampedTokens(values[8])
            )
            func string(at index: Int) -> String? {
                guard values.count > index else { return nil }
                return (values[index] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return Row(
                day: day,
                model: ((values[1] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                carriedCost: carriedCost,
                carriedTokens: clampedTokens(values[3]),
                unpricedTokens: tokens,
                bindingCredentialID: string(at: 9),
                bindingProfile: string(at: 10),
                modelProfile: string(at: 11)
            )
        }
    }

    static func aggregate(rows: [Row], pricing: ModelPricing) -> LogUsageScan {
        var accumulator = DailyUsageAccumulator()
        for row in rows {
            let day = dayKey(fromSQLDay: row.day)
            let trimmedModel = row.model.nilIfEmpty
            let modelName = trimmedModel ?? ModelUsageEntry.unattributedModelName
            if row.carriedTokens > 0 || row.carriedCost > 0 {
                accumulator.add(day: day, tokens: row.carriedTokens, cost: row.carriedCost, model: modelName)
            }
            guard row.unpricedTokens.totalTokens > 0 else { continue }
            if let model = trimmedModel,
               let estimated = pricing.estimatedCostDollars(
                   model: model, tokens: row.unpricedTokens, applyLongContextRates: false
               ) {
                accumulator.add(day: day, tokens: row.unpricedTokens.totalTokens, cost: estimated, model: model)
            } else if let model = trimmedModel {
                accumulator.addUnknownModel(day: day, model: model)
            }
        }
        return accumulator.build()
    }

    /// SQLite's `date()` always renders the Gregorian calendar, while the app's day keys come from
    /// `Calendar.current`; re-render through the shared day key so the spend tiles' Today/Yesterday
    /// lookups match under any system calendar.
    static func dayKey(fromSQLDay day: String) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return day }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = .current
        guard let date = gregorian.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
        else { return day }
        return DailyUsageAccumulator.dayKey(from: date)
    }

    private static func clampedTokens(_ value: Any) -> Int {
        Int(min(max(ProviderParse.number(value) ?? 0, 0), 1_000_000_000_000_000))
    }

    private static let tokenInput = "COALESCE(json_extract(tokens,'$.input'),0)"
    private static let tokenOutput = "COALESCE(json_extract(tokens,'$.output'),0)"
    private static let tokenReasoning = "COALESCE(json_extract(tokens,'$.reasoning'),0)"
    private static let tokenCacheRead = "COALESCE(json_extract(tokens,'$.cache.read'),0)"
    private static let tokenCacheWrite = "COALESCE(json_extract(tokens,'$.cache.write'),0)"
    private static let tokenTotal =
        "(\(tokenInput) + \(tokenOutput) + \(tokenReasoning) + \(tokenCacheRead) + \(tokenCacheWrite))"
    private static let localDay = "date(time_created/1000,'unixepoch','localtime')"

    private static func unpricedSum(_ expression: String) -> String {
        "COALESCE(SUM(CASE WHEN cost IS NULL THEN \(expression) ELSE 0 END),0)"
    }

    static func dataSQL(cutoffMs: Int, providerIDs: [String]) -> String {
        let providerFilter = "(" + providerIDs.map { "'\($0)'" }.joined(separator: ",") + ")"
        return """
        SELECT json_group_array(json_array(
                 day, modelID, carriedCost, carriedTokens,
                 unpricedInput, unpricedCacheWrite, unpricedCacheRead, unpricedOutput, unpricedReasoning))
        FROM (
          SELECT \(localDay) AS day,
                 json_extract(model,'$.id') AS modelID,
                 COALESCE(SUM(cost),0) AS carriedCost,
                 COALESCE(SUM(CASE WHEN cost IS NOT NULL THEN \(tokenTotal) ELSE 0 END),0) AS carriedTokens,
                 \(unpricedSum(tokenInput)) AS unpricedInput,
                 \(unpricedSum(tokenCacheWrite)) AS unpricedCacheWrite,
                 \(unpricedSum(tokenCacheRead)) AS unpricedCacheRead,
                 \(unpricedSum(tokenOutput)) AS unpricedOutput,
                 \(unpricedSum(tokenReasoning)) AS unpricedReasoning
          FROM session_provider_request
          WHERE time_created >= \(cutoffMs)
            AND json_valid(model)
            AND json_valid(tokens)
            AND json_extract(model,'$.providerID') IN \(providerFilter)
            AND (cost IS NULL OR cost >= 0)
          GROUP BY day, modelID
        );
        """
    }

    /// The attributed variant: same windowed day+model aggregation, additionally grouped by the
    /// request's account signals (session binding credential id/profile and `model.profile`) so
    /// Swift can claim each group for exactly one card. All request columns are qualified because
    /// the joined `session` table shares column names. Without a `profile_binding` column the
    /// binding fields come back NULL and only `model.profile` attributes.
    static func attributedDataSQL(cutoffMs: Int, providerIDs: [String], hasProfileBinding: Bool) -> String {
        let providerFilter = "(" + providerIDs.map { "'\($0)'" }.joined(separator: ",") + ")"
        let input = "COALESCE(json_extract(r.tokens,'$.input'),0)"
        let output = "COALESCE(json_extract(r.tokens,'$.output'),0)"
        let reasoning = "COALESCE(json_extract(r.tokens,'$.reasoning'),0)"
        let cacheRead = "COALESCE(json_extract(r.tokens,'$.cache.read'),0)"
        let cacheWrite = "COALESCE(json_extract(r.tokens,'$.cache.write'),0)"
        let total = "(\(input) + \(output) + \(reasoning) + \(cacheRead) + \(cacheWrite))"
        func unpriced(_ expression: String) -> String {
            "COALESCE(SUM(CASE WHEN r.cost IS NULL THEN \(expression) ELSE 0 END),0)"
        }
        let bindingCredentialID: String
        let bindingProfile: String
        let join: String
        if hasProfileBinding {
            let binding = "s.profile_binding"
            let matches = """
            \(binding) IS NOT NULL AND json_valid(\(binding))
                    AND COALESCE(json_extract(\(binding),'$.integrationID'), json_extract(\(binding),'$.providerID')) = 'anthropic'
            """
            bindingCredentialID = "CASE WHEN \(matches) THEN json_extract(\(binding),'$.credentialID') END"
            bindingProfile = "CASE WHEN \(matches) THEN json_extract(\(binding),'$.profile') END"
            join = "LEFT JOIN session s ON s.id = r.session_id"
        } else {
            bindingCredentialID = "NULL"
            bindingProfile = "NULL"
            join = ""
        }
        return """
        SELECT json_group_array(json_array(
                 day, modelID, carriedCost, carriedTokens,
                 unpricedInput, unpricedCacheWrite, unpricedCacheRead, unpricedOutput, unpricedReasoning,
                 bindingCredentialID, bindingProfile, modelProfile))
        FROM (
          SELECT date(r.time_created/1000,'unixepoch','localtime') AS day,
                 json_extract(r.model,'$.id') AS modelID,
                 COALESCE(SUM(r.cost),0) AS carriedCost,
                 COALESCE(SUM(CASE WHEN r.cost IS NOT NULL THEN \(total) ELSE 0 END),0) AS carriedTokens,
                 \(unpriced(input)) AS unpricedInput,
                 \(unpriced(cacheWrite)) AS unpricedCacheWrite,
                 \(unpriced(cacheRead)) AS unpricedCacheRead,
                 \(unpriced(output)) AS unpricedOutput,
                 \(unpriced(reasoning)) AS unpricedReasoning,
                 \(bindingCredentialID) AS bindingCredentialID,
                 \(bindingProfile) AS bindingProfile,
                 json_extract(r.model,'$.profile') AS modelProfile
          FROM session_provider_request r
          \(join)
          WHERE r.time_created >= \(cutoffMs)
            AND json_valid(r.model)
            AND json_valid(r.tokens)
            AND json_extract(r.model,'$.providerID') IN \(providerFilter)
            AND (r.cost IS NULL OR r.cost >= 0)
          GROUP BY day, modelID, bindingCredentialID, bindingProfile, modelProfile
        );
        """
    }
}
