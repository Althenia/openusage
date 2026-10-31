import Foundation

struct OpenAIAPIAuthStore: Sendable {
    static let configPaths = ["~/.config/openusage/openai-api.json"]
    static let environmentNames = ["OPENAI_ADMIN_KEY"]

    private let store: UserAPIKeyStore

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader()
    ) {
        store = UserAPIKeyStore(
            configPaths: Self.configPaths,
            environmentNames: Self.environmentNames,
            files: files,
            environment: environment,
            makeError: { failure in
                switch failure {
                case .missingKey: OpenAIAPIAuthError.missingKey
                case .saveFailed: OpenAIAPIAuthError.saveFailed
                case .deleteFailed: OpenAIAPIAuthError.deleteFailed
                }
            }
        )
    }

    func loadAPIKey() -> String? { store.loadKey() }
    func currentAPIKey() -> String? { store.loadKey() }
    func keyStatus() -> APIKeyStatus { store.keyStatus() }
    func saveAPIKey(_ key: String) throws { try store.saveKey(key) }
    func deleteAPIKey() throws { try store.deleteKey() }
}

enum OpenAIAPIAuthError: Error, LocalizedError, CategorizedError {
    case missingKey
    case saveFailed
    case deleteFailed

    var errorDescription: String? {
        switch self {
        case .missingKey:
            "No OpenAI Admin API key. Add an existing organization Admin key in Settings → API Keys, or supply OPENAI_ADMIN_KEY. Ordinary OpenAI API keys are not supported."
        case .saveFailed:
            "Couldn't save the OpenAI Admin API key."
        case .deleteFailed:
            "Couldn't remove the saved OpenAI Admin API key."
        }
    }

    var errorCategory: ErrorCategory {
        switch self {
        case .missingKey: .notLoggedIn
        case .saveFailed, .deleteFailed: .other
        }
    }
}
