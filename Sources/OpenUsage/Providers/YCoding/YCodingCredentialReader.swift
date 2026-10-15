import Foundation

/// A YCoding login a provider may fall back to when its own login is missing. Refresh tokens are
/// never surfaced: YCoding rotates its own credentials, so consumers get the live access token (or
/// API key) re-read on every use and nothing to refresh or write back — the same rule pi's Codex
/// logins follow.
enum YCodingCredential: Equatable, Sendable {
    case apiKey(String)
    /// The stored account id (top level or `metadata`), when the row carries one — Codex account
    /// matching cross-checks it against the access token's own claims.
    case oauth(accessToken: String, accountID: String?)
}

enum YCodingCredentialError: Error, LocalizedError, Equatable {
    case credentialsUnreadable(detail: String)

    var errorDescription: String? {
        switch self {
        case .credentialsUnreadable(let detail):
            return "YCoding credentials couldn't be read: \(detail)"
        }
    }
}

/// Reads the current credential row for one integration from YCoding's `ycoding.db` (`credential`
/// table, the OpenCode-family shape OpenCodeAuthStore already reads). Read-only: it only ever
/// calls `queryValue`, which opens the database `-readonly`. A missing database or a database
/// with no `credential` table is "no YCoding login"; any other read failure throws so broken
/// storage is never mistaken for logged-out.
struct YCodingCredentialReader: Sendable {
    var sqlite: SQLiteAccessing
    var files: TextFileAccessing
    var environment: EnvironmentReading
    var homeDirectory: @Sendable () -> URL
    var databasePathOverride: String?

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        databasePath: String? = nil
    ) {
        self.sqlite = sqlite
        self.files = files
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.databasePathOverride = databasePath
    }

    var databasePath: String {
        databasePathOverride ?? YCodingPaths.databasePath(
            dataDirectory: YCodingPaths.dataDirectory(environment: environment, homeDirectory: homeDirectory())
        )
    }

    /// The current row for `integration`, chosen before its type is checked — type-first filtering
    /// would resurrect an older login after the user switched credential kinds (mirrors
    /// `OpenCodeAuthStore.credentialSQLCurrentOpenAI` ordering and active handling).
    static func credentialSQL(integration: String) -> String {
        """
        SELECT json(value)
        FROM credential
        WHERE integration_id = '\(sqlEscaped(integration))' AND (active IS NULL OR active = 1)
        ORDER BY active DESC, time_updated DESC, id DESC
        LIMIT 1;
        """
    }

    func credential(integration: String) throws -> YCodingCredential? {
        let path = databasePath
        guard files.exists(path) else { return nil }
        let json: String?
        do {
            json = try sqlite.queryValue(path: path, sql: Self.credentialSQL(integration: integration))
        } catch where Self.isMissingTable(error) {
            return nil
        } catch {
            throw YCodingCredentialError.credentialsUnreadable(detail: "credential query failed")
        }
        guard let json = json?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return nil }
        guard let entry = Self.parseEntry(json) else {
            throw YCodingCredentialError.credentialsUnreadable(detail: "credential row is malformed")
        }
        switch entry["type"] as? String {
        case "key":
            guard let key = (entry["key"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return nil }
            return .apiKey(key)
        case "oauth":
            guard let access = (entry["access"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return nil }
            return .oauth(accessToken: access, accountID: Self.accountID(in: entry))
        default:
            return nil
        }
    }

    func apiKey(integration: String) throws -> String? {
        guard case .apiKey(let key) = try credential(integration: integration) else { return nil }
        return key
    }

    func oauthAccessToken(integration: String) throws -> String? {
        guard case .oauth(let token, _) = try credential(integration: integration) else { return nil }
        return token
    }

    private static func accountID(in entry: [String: Any]) -> String? {
        let metadata = entry["metadata"] as? [String: Any]
        for candidate in [entry["accountId"], entry["accountID"], metadata?["accountID"], metadata?["accountId"]] {
            if let value = (candidate as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                return value
            }
        }
        return nil
    }

    private static func parseEntry(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return object
    }

    private static func isMissingTable(_ error: Error) -> Bool {
        error.localizedDescription.localizedCaseInsensitiveContains("no such table")
    }

    private static func sqlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}
