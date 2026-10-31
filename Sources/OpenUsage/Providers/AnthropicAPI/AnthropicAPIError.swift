import Foundation

enum AnthropicAPIError: Error, LocalizedError, Equatable, CategorizedError {
    case missingKey
    case invalidKey
    case permissionDenied
    case unsupported
    case missingData
    case invalidResponse
    case unsupportedCurrency
    case connectionFailed
    case requestFailed(Int)
    case paginationExpired
    case saveFailed
    case deleteFailed

    var errorDescription: String? {
        switch self {
        case .missingKey:
            "No Anthropic Admin API key. Use ANTHROPIC_ADMIN_API_KEY or ~/.config/openusage/anthropic-api.json."
        case .invalidKey:
            "Anthropic rejected the configured Admin API key."
        case .permissionDenied:
            "Anthropic reporting permission denied. An organization Admin API key with reporting access is required."
        case .unsupported:
            "Anthropic organization reporting is unsupported for this account or endpoint."
        case .missingData:
            "Anthropic has no exported data for a completed UTC hour this month. Try again after reporting refreshes."
        case .invalidResponse:
            "Anthropic returned invalid or incomplete reporting data. No total is available."
        case .unsupportedCurrency:
            "Anthropic reported an unsupported cost currency. Only USD is supported."
        case .connectionFailed:
            "Couldn't reach Anthropic reporting. Check your connection."
        case .requestFailed(let status):
            "Anthropic reporting request failed (HTTP \(status))."
        case .paginationExpired:
            "Anthropic reporting pagination expired during refresh. No partial total is shown; refresh again."
        case .saveFailed:
            "Couldn't save the Anthropic Admin API key."
        case .deleteFailed:
            "Couldn't remove the saved Anthropic Admin API key."
        }
    }

    var errorCategory: ErrorCategory {
        switch self {
        case .missingKey: .notLoggedIn
        case .invalidKey: .authInvalid
        case .permissionDenied: .http4xx
        case .unsupported, .missingData, .unsupportedCurrency: .notAvailable
        case .invalidResponse: .decoding
        case .connectionFailed: .network
        case .requestFailed(let status): ErrorCategory.http(status)
        case .paginationExpired: .http4xx
        case .saveFailed, .deleteFailed: .credentialAccess
        }
    }
}
