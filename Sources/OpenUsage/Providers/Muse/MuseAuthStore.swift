import Foundation

struct MuseCredentials: Sendable {
    let apiKey: String
    let apiBaseURL: URL
}

enum MuseAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case credentialsUnreadable
    case invalidCredentials
    case subscriptionInactive

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Run muse login and try again."
        case .credentialsUnreadable:
            return "Couldn't read Muse credentials. Check the Muse auth file and macOS Keychain access."
        case .invalidCredentials:
            return "Muse credentials are invalid. Run muse login and try again."
        case .subscriptionInactive:
            return "Your Muse subscription is inactive."
        }
    }
}

struct MuseAuthStore: Sendable {
    static let keychainService = "ai.meta.dev.credentials"
    static let keychainAccount = "meta"

    private let files: any TextFileAccessing
    private let keychain: any KeychainAccessing
    private let environment: any EnvironmentReading

    init(
        files: any TextFileAccessing = LocalTextFileAccessor(),
        keychain: any KeychainAccessing = SecurityKeychainAccessor(),
        environment: any EnvironmentReading = ProcessEnvironmentReader()
    ) {
        self.files = files
        self.keychain = keychain
        self.environment = environment
    }

    var authFilePath: String {
        Self.authFilePath(environment: environment)
    }

    static func authFilePath(environment: EnvironmentReading) -> String {
        if let override = environment.value(for: "MUSE_AUTH_PATH")?.nilIfEmpty {
            return override
        }
        if let configHome = environment.value(for: "XDG_CONFIG_HOME")?.nilIfEmpty {
            return configHome.trimmingTrailingSlashes + "/muse/auth.json"
        }
        return "~/.config/muse/auth.json"
    }

    func loadCredentials() throws -> MuseCredentials? {
        let authText: String
        do {
            guard let text = try files.readTextIfPresent(authFilePath) else { return nil }
            authText = text
        } catch {
            AppLog.error(LogTag.auth("muse"), "auth file read failed")
            throw MuseAuthError.credentialsUnreadable
        }

        guard let data = authText.data(using: .utf8),
              let authFile = try? JSONDecoder().decode(MuseAuthFile.self, from: data),
              authFile.schemaVersion == 2,
              let provider = authFile.providers.meta,
              provider.mechanism == "oauth",
              provider.storage == "keychain",
              let apiBaseURL = Self.validatedAPIBaseURL(provider.apiBaseURL)
        else {
            AppLog.error(LogTag.auth("muse"), "auth file is invalid or does not reference Muse Keychain storage")
            throw MuseAuthError.invalidCredentials
        }
        guard provider.subsActive != false else { throw MuseAuthError.subscriptionInactive }

        let raw: String?
        do {
            raw = try keychain.readGenericPassword(
                service: Self.keychainService,
                account: Self.keychainAccount
            )
        } catch {
            AppLog.error(LogTag.auth("muse"), "Keychain credential read failed")
            throw MuseAuthError.credentialsUnreadable
        }
        guard let raw else { return nil }
        guard let secretData = raw.data(using: .utf8),
              let secret = try? JSONDecoder().decode(MuseKeychainSecret.self, from: secretData),
              secret.secretSchemaVersion == 1,
              let apiKey = secret.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        else {
            AppLog.error(LogTag.auth("muse"), "Keychain credential is malformed")
            throw MuseAuthError.invalidCredentials
        }
        return MuseCredentials(apiKey: apiKey, apiBaseURL: apiBaseURL)
    }

    private static func validatedAPIBaseURL(_ string: String) -> URL? {
        guard let components = URLComponents(string: string),
              components.scheme == "https",
              components.host == "api.meta.ai",
              components.path == "/v1",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else { return nil }
        return components.url
    }
}

private struct MuseAuthFile: Decodable {
    let schemaVersion: Int
    let providers: Providers

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case providers
    }

    struct Providers: Decodable {
        let meta: MetaProvider?
    }

    struct MetaProvider: Decodable {
        let mechanism: String
        let storage: String
        let apiBaseURL: String
        let subsActive: Bool?

        enum CodingKeys: String, CodingKey {
            case mechanism
            case storage
            case apiBaseURL = "api_base_url"
            case subsActive = "subs_active"
        }
    }
}

private struct MuseKeychainSecret: Decodable {
    let secretSchemaVersion: Int
    let apiKey: String?

    enum CodingKeys: String, CodingKey {
        case secretSchemaVersion = "secret_schema_version"
        case apiKey = "api_key"
    }
}
