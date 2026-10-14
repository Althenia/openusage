import Foundation
import LocalAuthentication
import Security

struct MuseCredentials: Sendable {
    let apiKey: String
    let apiBaseURL: URL
}

enum MuseAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case keychainPermissionRequired
    case credentialsUnreadable
    case invalidCredentials
    case subscriptionInactive

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Run muse login and try again."
        case .keychainPermissionRequired:
            return "Muse login found. Refresh once and choose Always Allow to connect it."
        case .credentialsUnreadable:
            return "Couldn't read Muse credentials. Check the Muse auth file and macOS Keychain access."
        case .invalidCredentials:
            return "Muse credentials are invalid. Run muse login and try again."
        case .subscriptionInactive:
            return "Your Muse subscription is inactive."
        }
    }
}

protocol MuseKeychainReading: Sendable {
    func readItem(allowInteraction: Bool) -> (status: OSStatus, data: Data?)
    func itemExists() -> Bool?
}

struct MuseKeychainReader: MuseKeychainReading {
    func readItem(allowInteraction: Bool) -> (status: OSStatus, data: Data?) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: MuseAuthStore.keychainService,
            kSecAttrAccount as String: MuseAuthStore.keychainAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        if !allowInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        return KeychainAccessGuard.read(service: MuseAuthStore.keychainService) {
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        }
    }

    func itemExists() -> Bool? {
        SecurityKeychainAccessor().genericPasswordExists(service: MuseAuthStore.keychainService)
    }
}

struct MuseAuthStore: Sendable {
    static let keychainService = "ai.meta.dev.credentials"
    static let keychainAccount = "meta"

    private let files: any TextFileAccessing
    private let keychain: any MuseKeychainReading
    private let environment: any EnvironmentReading

    init(
        files: any TextFileAccessing = LocalTextFileAccessor(),
        keychain: any MuseKeychainReading = MuseKeychainReader(),
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

    func loadAPIBaseURL() throws -> URL? {
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
        return apiBaseURL
    }

    func readAPIKey(allowInteraction: Bool) throws -> String? {
        let result = keychain.readItem(allowInteraction: allowInteraction)
        switch result.status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            AppLog.warn(LogTag.auth("muse"), "Keychain access not granted (\(result.status))")
            throw MuseAuthError.keychainPermissionRequired
        default:
            AppLog.error(LogTag.auth("muse"), "Keychain credential read failed (\(result.status))")
            throw MuseAuthError.credentialsUnreadable
        }
        guard let secretData = result.data,
              let secret = try? JSONDecoder().decode(MuseKeychainSecret.self, from: secretData),
              secret.secretSchemaVersion == 1,
              let apiKey = secret.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        else {
            AppLog.error(LogTag.auth("muse"), "Keychain credential is malformed")
            throw MuseAuthError.invalidCredentials
        }
        return apiKey
    }

    func hasKeychainItem() -> Bool {
        keychain.itemExists() == true
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
