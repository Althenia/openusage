import XCTest
@testable import OpenUsage

/// The YCoding fold-in against real temp-dir fixture databases (never the live YCoding DB): day
/// bucketing, carried vs NULL cost handling, provider mapping, the scan window, and missing sources.
final class YCodingUsageScannerTests: XCTestCase {
    /// Gregorian local noon on 2026-07-12, so SQLite's `localtime` day and the accumulator's local
    /// day agree in any test-machine time zone and system calendar.
    private var now: Date {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = .current
        return gregorian.date(from: DateComponents(year: 2026, month: 7, day: 12, hour: 12))!
    }

    private func daysAgo(_ days: Int) -> Int {
        let date = Calendar.current.date(byAdding: .day, value: -days, to: now)!
        return Int(date.timeIntervalSince1970 * 1000)
    }

    private func dayKey(daysAgo days: Int) -> String {
        DailyUsageAccumulator.dayKey(from: Calendar.current.date(byAdding: .day, value: -days, to: now)!)
    }

    private let pricing = ModelPricing(
        supplement: PricingSupplement(),
        primary: PricingCatalog(entries: [
            "claude-opus-4-8": ModelRates(
                inputPerMillion: 10, outputPerMillion: 20,
                cacheWritePerMillion: 10, cacheReadPerMillion: 1
            )
        ]),
        secondary: PricingCatalog(entries: [:])
    )

    private func row(
        ms: Int, provider: String, model: String, cost: String,
        input: Int = 0, output: Int = 0, reasoning: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0
    ) -> String {
        """
        INSERT INTO session_provider_request (time_created, cost, tokens, model) VALUES (\(ms), \(cost),
          '{"input":\(input),"output":\(output),"reasoning":\(reasoning),"cache":{"read":\(cacheRead),"write":\(cacheWrite)}}',
          '{"id":"\(model)","providerID":"\(provider)"}');
        """
    }

    private func makeScanner(inserts: String, schema: String? = nil) throws -> YCodingUsageScanner {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("ycoding.db").path
        try SQLiteCLIAccessor().execute(path: path, sql: (schema ?? """
            CREATE TABLE session_provider_request (
              id TEXT PRIMARY KEY, time_created INTEGER NOT NULL, cost REAL, tokens TEXT NOT NULL, model TEXT NOT NULL);
            """) + inserts)
        return YCodingUsageScanner(databasePath: { path })
    }

    func testCarriedCostBucketsByDayAndCountsReasoningInTokens() async throws {
        let scanner = try makeScanner(inserts: [
            row(ms: daysAgo(0), provider: "anthropic", model: "claude-opus-4-8", cost: "1.5", input: 100, output: 40, reasoning: 10),
            row(ms: daysAgo(1), provider: "anthropic", model: "claude-opus-4-8", cost: "2.5", input: 200)
        ].joined(separator: "\n"))

        let scan = await scanner.scan(cardID: "claude", now: now, pricing: .empty)
        let today = scan?.series.daily.first { $0.date == dayKey(daysAgo: 0) }
        let yesterday = scan?.series.daily.first { $0.date == dayKey(daysAgo: 1) }
        XCTAssertEqual(try XCTUnwrap(today?.costUSD), 1.5, accuracy: 0.0001)
        XCTAssertEqual(today?.totalTokens, 150)
        XCTAssertEqual(try XCTUnwrap(yesterday?.costUSD), 2.5, accuracy: 0.0001)
        XCTAssertEqual(yesterday?.totalTokens, 200)
        XCTAssertEqual(scan?.modelUsage?.daily.flatMap(\.models).map(\.model), ["claude-opus-4-8", "claude-opus-4-8"])
    }

    func testCarriedCostUsedAsIsForUnpriceableModel() async throws {
        let scanner = try makeScanner(inserts:
            row(ms: daysAgo(0), provider: "anthropic", model: "mystery-model", cost: "3.25", input: 500))

        let scan = await scanner.scan(cardID: "claude", now: now, pricing: .empty)
        XCTAssertEqual(try XCTUnwrap(scan?.series.daily.first?.costUSD), 3.25, accuracy: 0.0001)
        XCTAssertEqual(scan?.series.daily.first?.totalTokens, 500)
        XCTAssertTrue(scan?.unknownModelsByDay.isEmpty == true)
    }

    func testNullCostIsPricedThroughTheEngine() async throws {
        let scanner = try makeScanner(inserts:
            row(ms: daysAgo(0), provider: "anthropic", model: "claude-opus-4-8", cost: "NULL",
                input: 100_000, output: 50_000))

        let scan = await scanner.scan(cardID: "claude", now: now, pricing: pricing)
        XCTAssertEqual(try XCTUnwrap(scan?.series.daily.first?.costUSD), 2.0, accuracy: 0.0001)
        XCTAssertEqual(scan?.series.daily.first?.totalTokens, 150_000)
    }

    func testNullCostUnpriceableModelIsExcludedAndRecordedUnknown() async throws {
        let scanner = try makeScanner(inserts: [
            row(ms: daysAgo(0), provider: "anthropic", model: "mystery-model", cost: "NULL", input: 500),
            row(ms: daysAgo(0), provider: "anthropic", model: "claude-opus-4-8", cost: "1.0", input: 100)
        ].joined(separator: "\n"))

        let scan = await scanner.scan(cardID: "claude", now: now, pricing: pricing)
        XCTAssertEqual(try XCTUnwrap(scan?.series.daily.first?.costUSD), 1.0, accuracy: 0.0001)
        XCTAssertEqual(scan?.series.daily.first?.totalTokens, 100)
        XCTAssertEqual(scan?.unknownModelsByDay[dayKey(daysAgo: 0)], ["mystery-model"])
    }

    func testProviderMappingIncludesOnlyMappedCards() async throws {
        let scanner = try makeScanner(inserts: [
            row(ms: daysAgo(0), provider: "anthropic", model: "claude-opus-4-8", cost: "1.0", input: 10),
            row(ms: daysAgo(0), provider: "openai", model: "gpt-5.5", cost: "2.0", input: 20),
            row(ms: daysAgo(0), provider: "muse", model: "muse-spark", cost: "4.0", input: 40),
            row(ms: daysAgo(0), provider: "custom-openai", model: "gpt-5.5", cost: "8.0", input: 80)
        ].joined(separator: "\n"))

        let claude = await scanner.scan(cardID: "claude", now: now, pricing: .empty)
        XCTAssertEqual(try XCTUnwrap(claude?.series.daily.first?.costUSD), 1.0, accuracy: 0.0001)
        XCTAssertEqual(claude?.series.daily.first?.totalTokens, 10)

        let codex = await scanner.scan(cardID: "codex", now: now, pricing: .empty)
        XCTAssertEqual(try XCTUnwrap(codex?.series.daily.first?.costUSD), 2.0, accuracy: 0.0001)
        XCTAssertEqual(codex?.series.daily.first?.totalTokens, 20)

        XCTAssertEqual(YCodingProviderMapping.cardID(forYCodingProvider: "anthropic"), "claude")
        XCTAssertEqual(YCodingProviderMapping.cardID(forYCodingProvider: "openai"), "codex")
        XCTAssertEqual(YCodingProviderMapping.cardID(forYCodingProvider: "openai-codex"), "codex")
        XCTAssertNil(YCodingProviderMapping.cardID(forYCodingProvider: "muse"))
        XCTAssertNil(YCodingProviderMapping.cardID(forYCodingProvider: "custom-openai"))
    }

    func testRowsOutsideWindowAreExcluded() async throws {
        let scanner = try makeScanner(inserts: [
            row(ms: daysAgo(31), provider: "anthropic", model: "claude-opus-4-8", cost: "9.0", input: 900),
            row(ms: daysAgo(40), provider: "anthropic", model: "claude-opus-4-8", cost: "9.0", input: 900),
            row(ms: daysAgo(30), provider: "anthropic", model: "claude-opus-4-8", cost: "1.0", input: 100)
        ].joined(separator: "\n"))

        let scan = await scanner.scan(cardID: "claude", now: now, pricing: .empty)
        XCTAssertEqual(scan?.series.daily.count, 1)
        XCTAssertEqual(scan?.series.daily.first?.date, dayKey(daysAgo: 30))
        XCTAssertEqual(try XCTUnwrap(scan?.series.daily.first?.costUSD), 1.0, accuracy: 0.0001)
    }

    func testMissingDatabaseReturnsNil() async {
        let scanner = YCodingUsageScanner(databasePath: { "/nonexistent/ycoding.db" })
        let scan = await scanner.scan(cardID: "claude", now: now, pricing: .empty)
        XCTAssertNil(scan)
    }

    func testDatabaseWithoutRequestTableReturnsNil() async throws {
        let scanner = try makeScanner(inserts: "", schema: "CREATE TABLE other (id TEXT);")
        let scan = await scanner.scan(cardID: "claude", now: now, pricing: .empty)
        XCTAssertNil(scan)
    }

    // MARK: - Per-account Claude attribution

    private let accountA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let orgA = "11111111-1111-4111-8111-111111111111"
    private let accountB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private let orgB = "22222222-2222-4222-8222-222222222222"
    private let profileDirA = "33333333-3333-4333-8333-333333333333"
    private let profileDirB = "44444444-4444-4444-8444-444444444444"
    private var identityA: String { "\(accountA)|\(orgA)" }
    private var identityB: String { "\(accountB)|\(orgB)" }

    private func attributedRow(
        sessionID: String?, profile: String?, cost: String, input: Int
    ) -> String {
        let profileField = profile.map { #","profile":"\#($0)""# } ?? ""
        return """
        INSERT INTO session_provider_request (session_id, time_created, cost, tokens, model) VALUES (
          \(sessionID.map { "'\($0)'" } ?? "NULL"), \(daysAgo(0)), \(cost),
          '{"input":\(input)}',
          '{"id":"claude-opus-4-8","providerID":"anthropic"\(profileField)}');
        """
    }

    /// A two-account fixture: credentials `alice` (active) and `bob`, each naming a Claude Code
    /// profile directory whose `.claude.json` carries that account's `oauthAccount`, plus a `ghost`
    /// credential whose profile directory does not exist.
    private func makeAttributedScanner(extraRows: String = "") throws -> YCodingUsageScanner {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        for (profileDir, account, org) in [(profileDirA, accountA, orgA), (profileDirB, accountB, orgB)] {
            let profile = dir.appendingPathComponent("claude-code/profiles/\(profileDir)")
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            try #"{"oauthAccount":{"accountUuid":"\#(account)","organizationUuid":"\#(org)","emailAddress":"x@example.com"}}"#
                .write(to: profile.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        }
        let path = dir.appendingPathComponent("ycoding.db").path
        lastFixtureDatabasePath = path
        let boundSession = """
        INSERT INTO session (id, profile_binding) VALUES ('s-bound',
          '{"providerID":"anthropic","integrationID":"anthropic","profile":"bob","credentialID":"cred-b"}');
        """
        try SQLiteCLIAccessor().execute(path: path, sql: """
            CREATE TABLE session_provider_request (
              id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER NOT NULL, cost REAL,
              tokens TEXT NOT NULL, model TEXT NOT NULL);
            CREATE TABLE session (id TEXT PRIMARY KEY, profile_binding TEXT);
            CREATE TABLE credential (
              id TEXT PRIMARY KEY, integration_id TEXT, label TEXT NOT NULL, value TEXT NOT NULL,
              active INTEGER, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL);
            INSERT INTO credential VALUES ('cred-a','anthropic','alice',
              '{"type":"oauth","metadata":{"authKind":"claude-code","managed":1,"source":"\(profileDirA)"}}',1,1,2);
            INSERT INTO credential VALUES ('cred-b','anthropic','bob',
              '{"type":"oauth","metadata":{"authKind":"claude-code","managed":1,"source":"\(profileDirB)"}}',0,1,1);
            INSERT INTO credential VALUES ('cred-x','anthropic','ghost',
              '{"type":"key","metadata":{"source":"55555555-5555-4555-8555-555555555555"}}',0,1,1);
            \(boundSession)
            \(attributedRow(sessionID: nil, profile: "alice", cost: "1", input: 10))
            \(attributedRow(sessionID: nil, profile: "bob", cost: "2", input: 20))
            \(attributedRow(sessionID: nil, profile: nil, cost: "4", input: 40))
            \(attributedRow(sessionID: "s-bound", profile: "alice", cost: "32", input: 320))
            \(extraRows)
            """)
        return YCodingUsageScanner(databasePath: { path })
    }

    private func totalCost(_ scan: LogUsageScan?) -> Double {
        scan?.series.daily.compactMap(\.costUSD).reduce(0, +) ?? -1
    }

    private func totalTokens(_ scan: LogUsageScan?) -> Int {
        scan?.series.daily.reduce(0) { $0 + $1.totalTokens } ?? -1
    }

    func testTwoAccountsGetOnlyTheirRowsAndSumToTheUnfilteredTotal() async throws {
        let scanner = try makeAttributedScanner()

        let scanA = await scanner.scan(
            cardID: "claude", now: now, pricing: .empty,
            attribution: .claudeAccount(identityKey: identityA)
        )
        // alice's named row (1) + the no-profile row (4): alice owns the active credential. The
        // bound session's row is not hers even though its model.profile says "alice" — the
        // binding's credentialID (bob's) wins.
        XCTAssertEqual(totalCost(scanA), 5, accuracy: 0.0001)
        XCTAssertEqual(totalTokens(scanA), 50)

        let scanB = await scanner.scan(
            cardID: "claude", now: now, pricing: .empty,
            attribution: .claudeAccount(identityKey: identityB)
        )
        XCTAssertEqual(totalCost(scanB), 34, accuracy: 0.0001)
        XCTAssertEqual(totalTokens(scanB), 340)

        let unfiltered = await scanner.scan(cardID: "claude", now: now, pricing: .empty)
        XCTAssertEqual(totalCost(unfiltered), 39, accuracy: 0.0001)
        XCTAssertEqual(totalCost(scanA) + totalCost(scanB), totalCost(unfiltered), accuracy: 0.0001)
        XCTAssertEqual(totalTokens(scanA) + totalTokens(scanB), totalTokens(unfiltered))
    }

    func testUnresolvableProfilesAreExcludedFromEveryCard() async throws {
        let scanner = try makeAttributedScanner(extraRows: [
            attributedRow(sessionID: nil, profile: "ghost", cost: "8", input: 80),
            attributedRow(sessionID: nil, profile: "no-such-label", cost: "16", input: 160)
        ].joined(separator: "\n"))

        for identity in [identityA, identityB] {
            let scan = await scanner.scan(
                cardID: "claude", now: now, pricing: .empty,
                attribution: .claudeAccount(identityKey: identity)
            )
            XCTAssertLessThan(totalCost(scan), 39, "unresolvable rows leaked into \(identity)")
        }
        let scanA = await scanner.scan(
            cardID: "claude", now: now, pricing: .empty,
            attribution: .claudeAccount(identityKey: identityA)
        )
        let scanB = await scanner.scan(
            cardID: "claude", now: now, pricing: .empty,
            attribution: .claudeAccount(identityKey: identityB)
        )
        let unfiltered = await scanner.scan(cardID: "claude", now: now, pricing: .empty)
        XCTAssertEqual(totalCost(unfiltered), 63, accuracy: 0.0001)
        XCTAssertEqual(totalCost(scanA) + totalCost(scanB), 39, accuracy: 0.0001)
    }

    func testUnavailableCardIdentityClaimsNothing() async throws {
        let scanner = try makeAttributedScanner()
        let scan = await scanner.scan(
            cardID: "claude", now: now, pricing: .empty,
            attribution: .claudeAccount(identityKey: nil)
        )
        XCTAssertNil(scan)
    }

    func testResolverMapsCredentialsToAccountsAndPicksTheActiveOne() throws {
        _ = try makeAttributedScanner()
        let dbPath = lastFixtureDatabasePath
        let resolver = YCodingClaudeAttributionResolver(
            profilesDirectory: { YCodingUsageScanner.profilesDirectory(forDatabasePath: dbPath) }
        )
        let map = try XCTUnwrap(try resolver.load(databasePath: dbPath))
        XCTAssertEqual(map.identityByProfileLabel["alice"], identityA)
        XCTAssertEqual(map.identityByProfileLabel["bob"], identityB)
        XCTAssertNil(map.identityByProfileLabel["ghost"])
        XCTAssertEqual(map.identityByCredentialID["cred-b"], identityB)
        XCTAssertEqual(map.activeIdentityKey, identityA)
        XCTAssertTrue(map.hadUnresolvable)
        XCTAssertEqual(
            map.resolve(bindingCredentialID: "cred-b", bindingProfile: "bob", modelProfile: "alice"),
            .identity(identityB)
        )
        XCTAssertEqual(map.resolve(bindingCredentialID: nil, bindingProfile: nil, modelProfile: nil), .noProfile)
        XCTAssertEqual(map.resolve(bindingCredentialID: nil, bindingProfile: nil, modelProfile: "ghost"), .unresolvable)
    }

    private var lastFixtureDatabasePath: String = ""

    func testOAuthAccountParsingBuildsIdentityKeys() {
        XCTAssertEqual(
            YCodingClaudeAttributionResolver.identityKey(
                fromClaudeStateJSON: #"{"oauthAccount":{"accountUuid":"\#(accountA)","organizationUuid":"\#(orgA)"}}"#
            ),
            identityA
        )
        XCTAssertEqual(
            YCodingClaudeAttributionResolver.identityKey(
                fromClaudeStateJSON: #"{"oauthAccount":{"accountUuid":"\#(accountA)"}}"#
            ),
            accountA
        )
        XCTAssertNil(YCodingClaudeAttributionResolver.identityKey(fromClaudeStateJSON: #"{"userID":"x"}"#))
        XCTAssertNil(YCodingClaudeAttributionResolver.identityKey(fromClaudeStateJSON: "not json"))
    }

    func testMergedScanKeepsYCodingUsage() async throws {
        let scanner = try makeScanner(inserts:
            row(ms: daysAgo(0), provider: "anthropic", model: "claude-opus-4-8", cost: "1.5", input: 150))

        let yCoding = await scanner.scan(cardID: "claude", now: now, pricing: .empty)
        let merged = DailyUsageAccumulator.merged([nil, yCoding])
        XCTAssertEqual(try XCTUnwrap(merged?.series.daily.first?.costUSD), 1.5, accuracy: 0.0001)
        XCTAssertEqual(merged?.series.daily.first?.totalTokens, 150)
        XCTAssertEqual(merged?.modelUsage?.daily.first?.models.first?.model, "claude-opus-4-8")
    }
}
