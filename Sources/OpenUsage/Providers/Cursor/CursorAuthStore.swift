import Foundation

struct CursorAuthState: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case sqlite
        case keychain
        /// YCoding's own Cursor login, read-only: no refresh token is carried and nothing is ever
        /// written back — YCoding rotates the credential and each refresh re-reads it.
        case ycoding
    }

    var accessToken: String?
    var refreshToken: String?
    var source: Source
}

enum CursorAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case sessionExpired
    case tokenExpired
    case readOnlySource

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in. Sign in via Cursor app or run `agent login`."
        case .sessionExpired:
            return "Session expired. Sign in via Cursor app or run `agent login`."
        case .tokenExpired:
            return "Token expired. Sign in via Cursor app or run `agent login`."
        case .readOnlySource:
            return "This Cursor login is managed by another app and can't be updated here."
        }
    }
}

struct CursorAuthStore: Sendable {
    static let stateDBPath = "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    static let accessTokenKey = "cursorAuth/accessToken"
    static let refreshTokenKey = "cursorAuth/refreshToken"
    static let membershipTypeKey = "cursorAuth/stripeMembershipType"
    static let keychainAccessTokenService = "cursor-access-token"
    static let keychainRefreshTokenService = "cursor-refresh-token"
    static let refreshBufferSeconds: TimeInterval = 5 * 60

    var sqlite: SQLiteAccessing
    var keychain: KeychainAccessing
    var now: @Sendable () -> Date
    var ycodingCredentials: YCodingCredentialReader

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        now: @escaping @Sendable () -> Date = Date.init,
        ycodingCredentials: YCodingCredentialReader? = nil
    ) {
        self.sqlite = sqlite
        self.keychain = keychain
        self.now = now
        self.ycodingCredentials = ycodingCredentials ?? YCodingCredentialReader(sqlite: sqlite)
    }

    func loadAuthState() -> CursorAuthState? {
        let sqliteAccessToken = readStateValue(Self.accessTokenKey)
        let sqliteRefreshToken = readStateValue(Self.refreshTokenKey)
        let sqliteMembershipType = readStateValue(Self.membershipTypeKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let keychainAccessToken = readKeychainValue(Self.keychainAccessTokenService)
        let keychainRefreshToken = readKeychainValue(Self.keychainRefreshTokenService)

        let hasSQLiteAuth = sqliteAccessToken != nil || sqliteRefreshToken != nil
        let hasKeychainAuth = keychainAccessToken != nil || keychainRefreshToken != nil

        if hasSQLiteAuth {
            let sqliteSubject = Self.tokenSubject(sqliteAccessToken)
            let keychainSubject = Self.tokenSubject(keychainAccessToken)
            let subjectsDiffer = sqliteSubject != nil && keychainSubject != nil && sqliteSubject != keychainSubject
            if hasKeychainAuth, sqliteMembershipType == "free", subjectsDiffer {
                return CursorAuthState(
                    accessToken: keychainAccessToken,
                    refreshToken: keychainRefreshToken,
                    source: .keychain
                )
            }

            return CursorAuthState(
                accessToken: sqliteAccessToken,
                refreshToken: sqliteRefreshToken,
                source: .sqlite
            )
        }

        if hasKeychainAuth {
            return CursorAuthState(
                accessToken: keychainAccessToken,
                refreshToken: keychainRefreshToken,
                source: .keychain
            )
        }

        do {
            if let accessToken = try ycodingCredentials.oauthAccessToken(integration: "cursor") {
                return CursorAuthState(accessToken: accessToken, refreshToken: nil, source: .ycoding)
            }
        } catch {
            AppLog.error(LogTag.auth("cursor"), "YCoding credential database could not be read; YCoding fallback skipped")
        }

        return nil
    }

    func needsRefresh(_ accessToken: String?) -> Bool {
        guard let accessToken,
              let expiresAt = Self.tokenExpiration(accessToken)
        else {
            return true
        }
        return expiresAt.timeIntervalSince(now()) <= Self.refreshBufferSeconds
    }

    func saveAccessToken(_ accessToken: String, source: CursorAuthState.Source) throws {
        switch source {
        case .sqlite:
            try writeStateValue(Self.accessTokenKey, accessToken)
        case .keychain:
            try keychain.writeGenericPassword(service: Self.keychainAccessTokenService, value: accessToken)
        case .ycoding:
            throw CursorAuthError.readOnlySource
        }
    }

    private func readStateValue(_ key: String) -> String? {
        let sql = "SELECT value FROM ItemTable WHERE key = '\(Self.sqlEscaped(key))' LIMIT 1;"
        guard let value = try? sqlite.queryValue(path: Self.stateDBPath, sql: sql) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func writeStateValue(_ key: String, _ value: String) throws {
        let sql = """
        INSERT OR REPLACE INTO ItemTable (key, value) VALUES ('\(Self.sqlEscaped(key))', '\(Self.sqlEscaped(value))');
        """
        try sqlite.execute(path: Self.stateDBPath, sql: sql)
    }

    private func readKeychainValue(_ service: String) -> String? {
        guard let value = try? keychain.readGenericPassword(service: service) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func tokenExpiration(_ token: String) -> Date? {
        guard let exp = ProviderParse.jwtPayload(token)?["exp"].flatMap(ProviderParse.number) else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    static func tokenSubject(_ token: String?) -> String? {
        guard let token,
              let subject = ProviderParse.jwtPayload(token)?["sub"] as? String
        else {
            return nil
        }
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func sqlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}
