import Foundation

/// The `openai` OAuth login in YCoding's credential database.
struct YCodingCodexLogin: Equatable, Sendable {
    let identity: CodexAccountIdentity
    let source: CodexYCodingCredentialSource
}

struct YCodingCodexLoginScan: Equatable, Sendable {
    let logins: [YCodingCodexLogin]

    static let empty = YCodingCodexLoginScan(logins: [])
}

/// Reads YCoding's Codex login. Never writes: YCoding rotates its own tokens in its database, so
/// the refresh token is dropped and the access token is re-read live on every use (pi's rule).
struct YCodingCodexLoginScanner: Sendable {
    static let integration = "openai"

    var credentials: YCodingCredentialReader

    init(credentials: YCodingCredentialReader) {
        self.credentials = credentials
    }

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    ) {
        self.credentials = YCodingCredentialReader(
            sqlite: sqlite, files: files, environment: environment, homeDirectory: homeDirectory
        )
    }

    func scan() -> YCodingCodexLoginScan {
        let source = CodexYCodingCredentialSource(databasePath: credentials.databasePath)
        let auth: CodexAuth?
        do {
            auth = try Self.auth(reader: credentials, source: source)
        } catch {
            AppLog.error(.config, "accounts: YCoding credential database could not be read; YCoding Codex login skipped")
            return .empty
        }
        guard let auth,
              let identity = CodexAccountIdentity(auth: auth),
              CodexAccountIdentity.isComplete(key: identity.key)
        else { return .empty }
        return YCodingCodexLoginScan(logins: [YCodingCodexLogin(identity: identity, source: source)])
    }

    /// The live credential for the YCoding login — re-read on every use, never cached.
    static func loadAuth(reader: YCodingCredentialReader, source: CodexYCodingCredentialSource) -> CodexAuth? {
        do {
            return try auth(reader: reader, source: source)
        } catch {
            AppLog.error(LogTag.auth("codex"), "YCoding credential database could not be read; YCoding login skipped for this refresh")
            return nil
        }
    }

    private static func auth(reader: YCodingCredentialReader, source: CodexYCodingCredentialSource) throws -> CodexAuth? {
        var reader = reader
        reader.databasePathOverride = source.databasePath
        guard case .oauth(let accessToken, let accountID) = try reader.credential(integration: integration) else {
            return nil
        }
        return CodexAuth(tokens: CodexTokens(
            accessToken: accessToken,
            refreshToken: nil,
            idToken: nil,
            accountID: accountID
        ), lastRefresh: nil, apiKey: nil)
    }
}
