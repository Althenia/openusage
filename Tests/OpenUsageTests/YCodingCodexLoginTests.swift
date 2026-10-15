import XCTest
@testable import OpenUsage

/// YCoding's `openai` OAuth login as a read-only Codex credential source — the pi rules applied to
/// YCoding's database: discovery only keeps complete identities, candidates carry no refresh token
/// and can't be saved over, reloads see YCoding's own rotations, and assembly attaches the login
/// to its account's card (or the plain card when it's the only account). All databases are
/// temp-dir fixtures.
@MainActor
final class YCodingCodexLoginTests: XCTestCase {
    private typealias Fixtures = CodexMultiAccountFixtures

    private func oauthValue(token: String, accountID: String? = nil) -> String {
        let metadata = accountID.map { #","metadata":{"accountID":"\#($0)"}"# } ?? ""
        return #"{"type":"oauth","access":"\#(token)","refresh":"yc-refresh","expires":9999999999999,"methodID":"oauth"\#(metadata)}"#
    }

    /// The fixture DB's path; `update` rewrites its single row so a rotation can be simulated.
    private func fixtureDatabase(value: String?, integration: String = "openai") throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("ycoding.db").path
        let insert = value.map {
            "INSERT INTO credential VALUES ('c1','\(integration)','default','\($0)',NULL,NULL,1,0,0,100,100);"
        } ?? ""
        try SQLiteCLIAccessor().execute(path: path, sql: """
            CREATE TABLE credential (id TEXT PRIMARY KEY, integration_id TEXT, label TEXT NOT NULL,
              value TEXT NOT NULL, connector_id TEXT, method_id TEXT, active INTEGER,
              generation INTEGER DEFAULT 0 NOT NULL, account_generation INTEGER DEFAULT 0 NOT NULL,
              time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL);
            \(insert)
            """)
        return path
    }

    private func reader(databasePath: String) -> YCodingCredentialReader {
        YCodingCredentialReader(
            sqlite: SQLiteCLIAccessor(),
            files: LocalTextFileAccessor(),
            environment: FakeEnvironment(),
            databasePath: databasePath
        )
    }

    private func scanner(databasePath: String) -> YCodingCodexLoginScanner {
        YCodingCodexLoginScanner(credentials: reader(databasePath: databasePath))
    }

    private func store(
        databasePath: String,
        identity: CodexAccountIdentity? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) -> CodexAuthStore {
        CodexAuthStore(
            files: FakeFiles(), keychain: FakeKeychain(), now: now,
            expectedIdentity: identity,
            ycodingCredentialSources: [CodexYCodingCredentialSource(databasePath: databasePath)],
            ycodingCredentials: reader(databasePath: databasePath)
        )
    }

    // MARK: - Discovery

    func testScannerDiscoversTheOAuthLoginAndNamesItsAccount() throws {
        let token = Fixtures.token(accountID: "ACCT-YC", email: "yc@test")
        let path = try fixtureDatabase(value: oauthValue(token: token, accountID: "ACCT-YC"))

        let scan = scanner(databasePath: path).scan()

        XCTAssertEqual(scan.logins.map(\.identity.key), ["acct-yc|yc@test"])
        XCTAssertEqual(scan.logins.map(\.source), [CodexYCodingCredentialSource(databasePath: path)])
    }

    func testScannerIgnoresAnAPIKeyRow() throws {
        let path = try fixtureDatabase(value: #"{"type":"key","key":"sk-openai"}"#)
        XCTAssertTrue(scanner(databasePath: path).scan().logins.isEmpty)
    }

    func testScannerSkipsLoginsThatCannotNameTheirAccount() throws {
        let incomplete = try fixtureDatabase(value: oauthValue(
            token: Fixtures.token(accountID: "ACCT-YC", email: ""), accountID: "ACCT-YC"
        ))
        XCTAssertTrue(scanner(databasePath: incomplete).scan().logins.isEmpty)

        // A stored account id that contradicts the token's own claim names no account either.
        let conflicting = try fixtureDatabase(value: oauthValue(
            token: Fixtures.token(accountID: "ACCT-YC", email: "yc@test"), accountID: "ACCT-OTHER"
        ))
        XCTAssertTrue(scanner(databasePath: conflicting).scan().logins.isEmpty)
    }

    func testScannerReadsNothingWithoutADatabase() throws {
        let path = try fixtureDatabase(value: nil)
        XCTAssertTrue(scanner(databasePath: path).scan().logins.isEmpty)
    }

    // MARK: - Read-only candidates

    func testYCodingCandidateIsReadOnlyCarriesNoRefreshTokenAndCannotBeSaved() throws {
        let token = Fixtures.token(accountID: "ACCT-YC", email: "yc@test")
        let value = oauthValue(token: token, accountID: "ACCT-YC")
        let path = try fixtureDatabase(value: value)
        let identity = try XCTUnwrap(CodexAccountIdentity(accountID: "ACCT-YC", email: "yc@test"))
        let store = store(databasePath: path, identity: identity)

        let candidate = try XCTUnwrap(store.loadAuthCandidates().first)

        XCTAssertEqual(candidate.source, .ycoding(CodexYCodingCredentialSource(databasePath: path)))
        XCTAssertTrue(candidate.readOnly)
        XCTAssertNil(candidate.auth.tokens?.refreshToken)
        XCTAssertEqual(candidate.auth.tokens?.accessToken, token)
        XCTAssertEqual(candidate.auth.tokens?.accountID, "acct-yc")
        XCTAssertThrowsError(try store.save(candidate)) { error in
            XCTAssertEqual(error as? CodexAuthError, .tokenConflict)
        }
        // YCoding's row is byte-identical afterwards.
        XCTAssertEqual(try reader(databasePath: path).oauthAccessToken(integration: "openai"), token)
    }

    func testReloadPicksUpTheTokenYCodingRotatedInItsDatabase() async throws {
        let first = Fixtures.token(accountID: "ACCT-YC", email: "yc@test", exp: Date(timeIntervalSince1970: 2_000_000_000))
        let path = try fixtureDatabase(value: oauthValue(token: first, accountID: "ACCT-YC"))
        let store = store(databasePath: path)

        let candidate = try XCTUnwrap(store.loadAuthCandidates().first)
        XCTAssertEqual(candidate.auth.tokens?.accessToken, first)
        let stillCurrent = await store.isCurrent(candidate)
        XCTAssertTrue(stillCurrent)

        let rotated = Fixtures.token(accountID: "ACCT-YC", email: "yc@test", exp: Date(timeIntervalSince1970: 2_100_000_000))
        try SQLiteCLIAccessor().execute(
            path: path,
            sql: "UPDATE credential SET value = '\(oauthValue(token: rotated, accountID: "ACCT-YC"))' WHERE id = 'c1';"
        )

        let stillCurrentAfterRotation = await store.isCurrent(candidate)
        XCTAssertFalse(stillCurrentAfterRotation)
        XCTAssertEqual(store.loadAuthCandidates().map { $0.auth.tokens?.accessToken }, [rotated])
        let reloaded = store.loadYCodingAuth(CodexYCodingCredentialSource(databasePath: path))
        XCTAssertEqual(reloaded?.auth.tokens?.accessToken, rotated)
    }

    func testScopedStoreRejectsAYCodingLoginForAnotherAccount() throws {
        let token = Fixtures.token(accountID: "ACCT-YC", email: "yc@test")
        let path = try fixtureDatabase(value: oauthValue(token: token, accountID: "ACCT-YC"))
        let other = try XCTUnwrap(CodexAccountIdentity(accountID: "ACCT-OTHER", email: "other@test"))

        XCTAssertTrue(store(databasePath: path, identity: other).loadAuthCandidates().isEmpty)
    }

    // MARK: - Plain provider end to end

    func testPlainProviderRefreshesFromTheYCodingLoginAlone() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let token = Fixtures.token(accountID: "ACCT-YC", email: "yc@test", exp: now.addingTimeInterval(3600))
        let path = try fixtureDatabase(value: oauthValue(token: token, accountID: "ACCT-YC"))
        let http = RoutingHTTPClient { request in
            request.headers["Authorization"] == "Bearer \(token)"
                ? Fixtures.usageResponse()
                : HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        let provider = CodexProvider(
            authStore: store(databasePath: path, now: { now }),
            usageClient: CodexUsageClient(http: http),
            now: { now }
        )

        let detected = await provider.hasLocalCredentials()
        XCTAssertTrue(detected)
        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests.first?.headers["Authorization"], "Bearer \(token)")
    }

    // MARK: - Assembly

    /// Points the assembly's YCoding scan at a fixture DB through `XDG_DATA_HOME`; the fake file
    /// entry only answers the reader's existence probe — sqlite reads the real fixture.
    private func assemble(
        files: FakeFiles,
        ycodingValue: String?,
        directories: [String: [String]] = [:]
    ) async throws -> ProviderAccountAssembly {
        let xdg = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let ycodingDir = xdg.appendingPathComponent("ycoding")
        try FileManager.default.createDirectory(at: ycodingDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: xdg) }
        let path = ycodingDir.appendingPathComponent("ycoding.db").path
        if let ycodingValue {
            let fixture = try fixtureDatabase(value: ycodingValue)
            try FileManager.default.copyItem(atPath: fixture, toPath: path)
            files.files[path] = ""
        }
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment(["XDG_DATA_HOME": xdg.path]),
            files: files,
            keychain: FakeKeychain(),
            homeDirectory: { Fixtures.home }
        )
        return await ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: ProviderAccountsStore(defaults: makeScratchDefaults()),
            families: ["codex"],
            listCodexHomeDirectories: { directories[$0] ?? [] }
        )
    }

    func testYCodingOnlyLoginYieldsAWorkingPlainCard() async throws {
        let token = Fixtures.token(accountID: "ACCT-YC", email: "yc@test")
        let assembly = try await assemble(
            files: FakeFiles(), ycodingValue: oauthValue(token: token, accountID: "ACCT-YC")
        )

        XCTAssertTrue(assembly.codexCards.isEmpty)
        XCTAssertEqual(assembly.codex.plainYCodingCredentialSources.count, 1)

        // Catalog wiring is asserted structurally: the catalog builds its store with production
        // defaults, so loading its candidates here would read this Mac's real Codex homes.
        let providers = ProviderCatalog.make(defaults: makeScratchDefaults(), codex: assembly.codex)
            .compactMap { $0 as? CodexProvider }
        XCTAssertEqual(providers.map(\.provider.id), ["codex"])
        XCTAssertEqual(providers[0].authStore.ycodingCredentialSources,
                       assembly.codex.plainYCodingCredentialSources)
        XCTAssertNil(providers[0].authStore.expectedIdentity)
    }

    func testSameAccountInHomeAndYCodingStaysOnThePlainCard() async throws {
        let files = FakeFiles([
            "/Users/dev/.codex/auth.json": Fixtures.codexAuth(accountID: "ACCT-YC", email: "yc@test"),
        ])
        let token = Fixtures.token(accountID: "ACCT-YC", email: "yc@test")

        let assembly = try await assemble(files: files, ycodingValue: oauthValue(token: token, accountID: "ACCT-YC"))

        XCTAssertTrue(assembly.codexCards.isEmpty)
        XCTAssertEqual(assembly.codex.plainYCodingCredentialSources.count, 1)
    }

    func testYCodingOnlyAccountGetsItsOwnCardBesideAHomeLogin() async throws {
        let files = FakeFiles([
            "/Users/dev/.codex/auth.json": Fixtures.codexAuth(accountID: "ACCT-WORK", email: "me@work.test"),
        ])
        let token = Fixtures.token(accountID: "ACCT-YC", email: "yc@test")

        let assembly = try await assemble(files: files, ycodingValue: oauthValue(token: token, accountID: "ACCT-YC"))

        XCTAssertEqual(assembly.codexCards.count, 2)
        let ycoding = try XCTUnwrap(assembly.codexCards.first { $0.identity.key == "acct-yc|yc@test" })
        XCTAssertTrue(ycoding.authHomes.isEmpty)
        XCTAssertEqual(ycoding.ycodingCredentialSources.count, 1)
        let work = try XCTUnwrap(assembly.codexCards.first { $0.identity.key == "acct-work|me@work.test" })
        XCTAssertTrue(work.ycodingCredentialSources.isEmpty)

        let cardStore = CodexAuthStore(
            files: files, keychain: FakeKeychain(), expectedIdentity: ycoding.identity,
            ycodingCredentialSources: ycoding.ycodingCredentialSources,
            ycodingCredentials: reader(databasePath: try XCTUnwrap(ycoding.ycodingCredentialSources.first?.databasePath))
        )
        let candidate = try XCTUnwrap(cardStore.loadAuthCandidates().first)
        XCTAssertTrue(candidate.readOnly)
        XCTAssertNil(candidate.auth.tokens?.refreshToken)
        XCTAssertEqual(candidate.auth.tokens?.accountID, "acct-yc")
    }
}
