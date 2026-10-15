import XCTest
@testable import OpenUsage

/// The read-only YCoding credential fallback: current-row selection and type filtering in the
/// reader, native-source precedence in the OpenRouter/Cursor auth stores, and the guarantee that
/// nothing is ever written back to YCoding's database. All databases are temp-dir fixtures.
final class YCodingCredentialReaderTests: XCTestCase {
    private func reader(databasePath: String) -> YCodingCredentialReader {
        YCodingCredentialReader(
            sqlite: SQLiteCLIAccessor(),
            files: LocalTextFileAccessor(),
            environment: FakeEnvironment(),
            databasePath: databasePath
        )
    }

    private func fixtureDatabase(rows: [String] = []) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("ycoding.db").path
        try SQLiteCLIAccessor().execute(path: path, sql: """
            CREATE TABLE credential (id TEXT PRIMARY KEY, integration_id TEXT, label TEXT NOT NULL,
              value TEXT NOT NULL, connector_id TEXT, method_id TEXT, active INTEGER,
              generation INTEGER DEFAULT 0 NOT NULL, account_generation INTEGER DEFAULT 0 NOT NULL,
              time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL);
            \(rows.joined(separator: "\n"))
            """)
        return path
    }

    private func row(_ id: String, _ integration: String, _ value: String, active: Int?, updated: Int) -> String {
        let activeSQL = active.map(String.init) ?? "NULL"
        return "INSERT INTO credential VALUES ('\(id)','\(integration)','default','\(value)',NULL,NULL,\(activeSQL),0,0,\(updated),\(updated));"
    }

    func testCurrentRowIsTheNewestActiveRow() throws {
        let path = try fixtureDatabase(rows: [
            row("c1", "openrouter", #"{"type":"key","key":"sk-or-inactive-newest"}"#, active: 0, updated: 300),
            row("c2", "openrouter", #"{"type":"key","key":"sk-or-active"}"#, active: 1, updated: 200),
            row("c3", "openrouter", #"{"type":"key","key":"sk-or-active-oldest"}"#, active: 1, updated: 100),
            row("c4", "openrouter", #"{"type":"key","key":"sk-or-imported"}"#, active: nil, updated: 400)
        ])
        XCTAssertEqual(try reader(databasePath: path).apiKey(integration: "openrouter"), "sk-or-active")
    }

    func testInactiveOnlyRowIsAbsent() throws {
        let path = try fixtureDatabase(rows: [
            row("c1", "openrouter", #"{"type":"key","key":"sk-or-off"}"#, active: 0, updated: 100)
        ])
        XCTAssertNil(try reader(databasePath: path).apiKey(integration: "openrouter"))
    }

    func testMissingDatabaseIsAbsent() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "/ycoding.db").path
        let reader = reader(databasePath: path)
        XCTAssertNil(try reader.apiKey(integration: "openrouter"))
        XCTAssertNil(try reader.oauthAccessToken(integration: "cursor"))
    }

    func testMissingCredentialTableIsAbsent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("ycoding.db").path
        try SQLiteCLIAccessor().execute(path: path, sql: "CREATE TABLE session (id TEXT PRIMARY KEY);")
        XCTAssertNil(try reader(databasePath: path).apiKey(integration: "openrouter"))
    }

    func testCorruptDatabaseThrowsInsteadOfReadingAsLoggedOut() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("ycoding.db").path
        try "this is not a sqlite database".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try reader(databasePath: path).apiKey(integration: "openrouter")) { error in
            guard case YCodingCredentialError.credentialsUnreadable = error else {
                return XCTFail("expected credentialsUnreadable, got \(error)")
            }
        }
    }

    func testMalformedCredentialValueThrows() throws {
        let path = try fixtureDatabase(rows: [
            row("c1", "openrouter", "not json", active: 1, updated: 100)
        ])
        XCTAssertThrowsError(try reader(databasePath: path).apiKey(integration: "openrouter")) { error in
            guard case YCodingCredentialError.credentialsUnreadable = error else {
                return XCTFail("expected credentialsUnreadable, got \(error)")
            }
        }
    }

    func testKeyAndOAuthRowsOnlyFeedTheirOwnAccessor() throws {
        let path = try fixtureDatabase(rows: [
            row("c1", "cursor", #"{"type":"oauth","access":"yc-access","refresh":"yc-refresh","expires":9999999999999}"#, active: 1, updated: 100),
            row("c2", "openrouter", #"{"type":"key","key":"sk-or-yc"}"#, active: 1, updated: 100)
        ])
        let reader = reader(databasePath: path)
        XCTAssertEqual(try reader.oauthAccessToken(integration: "cursor"), "yc-access")
        XCTAssertNil(try reader.apiKey(integration: "cursor"))
        XCTAssertEqual(try reader.apiKey(integration: "openrouter"), "sk-or-yc")
        XCTAssertNil(try reader.oauthAccessToken(integration: "openrouter"))
        XCTAssertNil(try reader.apiKey(integration: "anthropic"))
    }

    func testCurrentRowTypeWinsOverOlderRowOfTheOtherKind() throws {
        // The row is chosen before its type is checked, so an older API-key login is not
        // resurrected once the current credential became OAuth (and vice versa).
        let path = try fixtureDatabase(rows: [
            row("c1", "cursor", #"{"type":"key","key":"sk-old"}"#, active: 1, updated: 100),
            row("c2", "cursor", #"{"type":"oauth","access":"yc-access","refresh":"yc-refresh"}"#, active: 1, updated: 200)
        ])
        let reader = reader(databasePath: path)
        XCTAssertNil(try reader.apiKey(integration: "cursor"))
        XCTAssertEqual(try reader.oauthAccessToken(integration: "cursor"), "yc-access")
    }

    func testBlankSecretsAreAbsent() throws {
        let path = try fixtureDatabase(rows: [
            row("c1", "openrouter", #"{"type":"key","key":"   "}"#, active: 1, updated: 100),
            row("c2", "cursor", #"{"type":"oauth","access":"","refresh":"yc-refresh"}"#, active: 1, updated: 100)
        ])
        let reader = reader(databasePath: path)
        XCTAssertNil(try reader.apiKey(integration: "openrouter"))
        XCTAssertNil(try reader.oauthAccessToken(integration: "cursor"))
    }

    // MARK: - OpenRouter wiring

    private func openRouterFixture(key: String = "sk-or-ycoding") throws -> YCodingCredentialReader {
        let path = try fixtureDatabase(rows: [
            row("c1", "openrouter", "{\"type\":\"key\",\"key\":\"\(key)\"}", active: 1, updated: 100)
        ])
        return reader(databasePath: path)
    }

    func testOpenRouterFallsBackToYCodingKeyWhenNativeSourcesAreEmpty() throws {
        let store = OpenRouterAuthStore(
            files: FakeFiles(), environment: FakeEnvironment(),
            ycodingCredentials: try openRouterFixture()
        )
        XCTAssertEqual(store.loadAPIKey()?.apiKey, "sk-or-ycoding")
        // The editor status keeps its native-only meaning: a YCoding key is not a saved key.
        XCTAssertEqual(store.keyStatus(), .notSet)
        XCTAssertNil(store.currentAPIKey())
    }

    func testOpenRouterNativeKeyBeatsYCodingKey() throws {
        let reader = try openRouterFixture()
        let fromEnvironment = OpenRouterAuthStore(
            files: FakeFiles(), environment: FakeEnvironment(["OPENROUTER_API_KEY": "sk-or-env"]),
            ycodingCredentials: reader
        )
        XCTAssertEqual(fromEnvironment.loadAPIKey()?.apiKey, "sk-or-env")

        let fromConfig = OpenRouterAuthStore(
            files: FakeFiles([OpenRouterAuthStore.configPaths[0]: #"{"apiKey":"sk-or-file"}"#]),
            environment: FakeEnvironment(["OPENROUTER_API_KEY": "sk-or-env"]),
            ycodingCredentials: reader
        )
        XCTAssertEqual(fromConfig.loadAPIKey()?.apiKey, "sk-or-file")
    }

    // MARK: - Cursor wiring

    private func cursorFixture(accessToken: String) throws -> YCodingCredentialReader {
        let path = try fixtureDatabase(rows: [
            row("c1", "cursor",
                "{\"type\":\"oauth\",\"access\":\"\(accessToken)\",\"refresh\":\"yc-refresh\",\"expires\":9999999999999}",
                active: 1, updated: 100)
        ])
        return reader(databasePath: path)
    }

    func testCursorFallsBackToYCodingAccessTokenWithoutRefreshToken() throws {
        let token = makeCursorJWT(sub: "google-oauth2|ycoding-user")
        let store = CursorAuthStore(
            sqlite: KeyValueSQLite(), keychain: FakeKeychain(),
            ycodingCredentials: try cursorFixture(accessToken: token)
        )
        let state = store.loadAuthState()
        XCTAssertEqual(state?.source, .ycoding)
        XCTAssertEqual(state?.accessToken, token)
        XCTAssertNil(state?.refreshToken)
    }

    func testCursorNativeSourcesBeatYCoding() throws {
        let reader = try cursorFixture(accessToken: makeCursorJWT(sub: "google-oauth2|ycoding-user"))

        let sqliteToken = makeCursorJWT(sub: "google-oauth2|sqlite-user")
        let sqliteStore = CursorAuthStore(
            sqlite: KeyValueSQLite(values: [CursorAuthStore.accessTokenKey: sqliteToken]),
            keychain: FakeKeychain(), ycodingCredentials: reader
        )
        XCTAssertEqual(sqliteStore.loadAuthState()?.source, .sqlite)
        XCTAssertEqual(sqliteStore.loadAuthState()?.accessToken, sqliteToken)

        let keychainToken = makeCursorJWT(sub: "auth0|keychain-user")
        let keychainStore = CursorAuthStore(
            sqlite: KeyValueSQLite(),
            keychain: ServiceKeychain(values: [CursorAuthStore.keychainAccessTokenService: keychainToken]),
            ycodingCredentials: reader
        )
        XCTAssertEqual(keychainStore.loadAuthState()?.source, .keychain)
        XCTAssertEqual(keychainStore.loadAuthState()?.accessToken, keychainToken)
    }

    func testCursorSaveForYCodingSourceWritesNothingAnywhere() throws {
        let token = makeCursorJWT(sub: "google-oauth2|ycoding-user")
        let reader = try cursorFixture(accessToken: token)
        let sqlite = KeyValueSQLite()
        let keychain = FakeKeychain()
        let store = CursorAuthStore(sqlite: sqlite, keychain: keychain, ycodingCredentials: reader)

        XCTAssertThrowsError(try store.saveAccessToken("fresh-token", source: .ycoding)) { error in
            XCTAssertEqual(error as? CursorAuthError, .readOnlySource)
        }
        XCTAssertTrue(sqlite.writtenValues.isEmpty)
        XCTAssertNil(keychain.value)
        // The YCoding database still holds the original token, byte for byte.
        XCTAssertEqual(try reader.oauthAccessToken(integration: "cursor"), token)
    }
}
