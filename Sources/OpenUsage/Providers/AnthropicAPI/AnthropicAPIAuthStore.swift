import Foundation

struct AnthropicAPIAuthStore: Sendable {
    static let configPaths = ["~/.config/openusage/anthropic-api.json"]
    static let environmentNames = ["ANTHROPIC_ADMIN_API_KEY"]

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
                case .missingKey: AnthropicAPIError.missingKey
                case .saveFailed: AnthropicAPIError.saveFailed
                case .deleteFailed: AnthropicAPIError.deleteFailed
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
