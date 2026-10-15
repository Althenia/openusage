import Foundation

/// How one card's YCoding scan claims rows. `all` is the single-card fold-in (every mapped row);
/// `claudeAccount` attributes each row to one Claude account identity key, with `nil` for a card
/// whose account identity is unavailable (it claims nothing).
enum YCodingAttribution: Equatable, Sendable {
    case all
    case claudeAccount(identityKey: String?)
}

/// The resolved YCoding anthropic credential set: which Claude account each credential (by id and
/// by profile label) belongs to, plus the currently active credential's account. Built without
/// ever reading credential secrets — only ids, labels, active flags, and profile directory names.
struct YCodingClaudeAttributionMap: Equatable, Sendable {
    var identityByCredentialID: [String: String] = [:]
    var identityByProfileLabel: [String: String] = [:]
    var activeIdentityKey: String?
    /// A credential, profile label, or profile file existed but could not be resolved to exactly
    /// one account, so rows naming it must stay unattributed rather than be guessed.
    var hadUnresolvable = false

    enum Resolution: Equatable, Sendable {
        case identity(String)
        case noProfile
        case unresolvable
    }

    /// The account a request group belongs to. A session binding's credential id wins over profile
    /// labels (YCoding's own recorded join), then the binding's profile label, then the request's
    /// `model.profile` label; no profile signal at all is `noProfile`.
    func resolve(bindingCredentialID: String?, bindingProfile: String?, modelProfile: String?) -> Resolution {
        if let credentialID = bindingCredentialID?.nilIfEmpty {
            if let identity = identityByCredentialID[credentialID] { return .identity(identity) }
            return resolve(label: bindingProfile) ?? resolve(label: modelProfile) ?? .unresolvable
        }
        return resolve(label: bindingProfile) ?? resolve(label: modelProfile) ?? .noProfile
    }

    private func resolve(label: String?) -> Resolution? {
        guard let label = label?.nilIfEmpty else { return nil }
        if let identity = identityByProfileLabel[label] { return .identity(identity) }
        return .unresolvable
    }
}

/// Resolves YCoding's anthropic credentials to Claude accounts. The chain is YCoding's own:
/// credential row (`label`, `metadata.source` naming its Claude Code profile directory under
/// `claude-code/profiles/`) → that directory's `.claude.json` `oauthAccount`, keyed exactly like
/// the app's own Claude identity (`DefaultAccountObserver.claudeIdentityKey`).
struct YCodingClaudeAttributionResolver: Sendable {
    private let sqlite: SQLiteAccessing
    private let files: TextFileAccessing
    private let profilesDirectory: @Sendable () -> String

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        profilesDirectory: @escaping @Sendable () -> String
    ) {
        self.sqlite = sqlite
        self.files = files
        self.profilesDirectory = profilesDirectory
    }

    /// Only ids, labels, and profile-directory names — never the credential's secret fields.
    /// Ordered like YCoding's own current-credential choice, so the first `active = 1` row in this
    /// order is the currently active one.
    static let credentialsSQL = """
    SELECT json_group_array(json_array(
             id, label, COALESCE(active,0), json_extract(value,'$.metadata.source')))
    FROM (
      SELECT id, label, active, value FROM credential
      WHERE integration_id = 'anthropic' AND json_valid(value)
      ORDER BY active DESC, time_updated DESC, id DESC
    );
    """

    static let credentialTableSQL =
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='credential';"

    /// `nil` when the database or its `credential` table is absent (no YCoding logins to resolve).
    /// Throws on a genuine read failure so the caller reports it instead of scanning unattributed.
    func load(databasePath path: String) throws -> YCodingClaudeAttributionMap? {
        guard try sqlite.queryValue(path: path, sql: Self.credentialTableSQL) != nil else { return nil }
        let json = try sqlite.queryValue(path: path, sql: Self.credentialsSQL)
        var map = YCodingClaudeAttributionMap()
        var ambiguousLabels: Set<String> = []
        for row in Self.parseCredentialRows(json ?? "[]") {
            guard let identity = identity(forSource: row.source) else {
                map.hadUnresolvable = true
                continue
            }
            if let id = row.id?.nilIfEmpty { map.identityByCredentialID[id] = identity }
            if let label = row.label?.nilIfEmpty {
                if let existing = map.identityByProfileLabel[label], existing != identity {
                    ambiguousLabels.insert(label)
                    map.hadUnresolvable = true
                } else {
                    map.identityByProfileLabel[label] = identity
                }
            }
            if row.active, map.activeIdentityKey == nil {
                map.activeIdentityKey = identity
            }
        }
        for label in ambiguousLabels { map.identityByProfileLabel.removeValue(forKey: label) }
        return map
    }

    private struct CredentialRow {
        var id: String?
        var label: String?
        var active: Bool
        var source: String?
    }

    private static func parseCredentialRows(_ json: String) -> [CredentialRow] {
        guard let data = json.data(using: .utf8),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return [] }
        return payload.compactMap { element in
            guard let values = element as? [Any], values.count >= 4 else { return nil }
            return CredentialRow(
                id: values[0] as? String,
                label: values[1] as? String,
                active: (ProviderParse.number(values[2]) ?? 0) == 1,
                source: values[3] as? String
            )
        }
    }

    /// The Claude identity a profile `source` names, or nil when it cannot be resolved. The source
    /// must reduce to one UUID directory name, so a database value can never steer the read outside
    /// the profiles directory.
    func identity(forSource source: String?) -> String? {
        guard let raw = source?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return nil }
        let directoryName = (raw as NSString).lastPathComponent
        guard UUID(uuidString: directoryName) != nil else { return nil }
        let path = profilesDirectory().trimmingTrailingSlashes + "/" + directoryName + "/.claude.json"
        let text: String?
        do {
            text = try files.readTextIfPresent(path)
        } catch {
            return nil
        }
        guard let text else { return nil }
        return Self.identityKey(fromClaudeStateJSON: text)
    }

    static func identityKey(fromClaudeStateJSON text: String) -> String? {
        guard let parsed = try? JSONDecoder().decode(DefaultAccountObserver.ClaudeStateFile.self, from: Data(text.utf8)),
              let account = parsed.oauthAccount
        else { return nil }
        return DefaultAccountObserver.claudeIdentityKey(account)
    }
}
