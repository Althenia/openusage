import Foundation

enum OpenAIAPIUsageError: Error, LocalizedError, CategorizedError, Equatable {
    case invalidKey
    case permissionDenied
    case unsupported
    case unsupportedCurrency
    case invalidResponse
    case connectionFailed
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .invalidKey:
            "OpenAI rejected this key. An existing API Platform organization Admin key is required; ordinary inference keys are not supported."
        case .permissionDenied:
            "OpenAI denied access. This Admin key needs permission to read organization usage and costs. Contact your API Platform organization owner."
        case .unsupported:
            "OpenAI organization usage or costs reporting is unavailable for this account."
        case .unsupportedCurrency:
            "OpenAI returned a non-USD cost report. Only reported USD costs are supported."
        case .invalidResponse:
            "OpenAI returned an incomplete or malformed usage or cost report. Try again later."
        case .connectionFailed:
            "Couldn't reach OpenAI. Check your connection."
        case .requestFailed(let status):
            "OpenAI usage request failed (HTTP \(status))."
        }
    }

    var errorCategory: ErrorCategory {
        switch self {
        case .invalidKey: .authInvalid
        case .permissionDenied: .http4xx
        case .unsupported, .unsupportedCurrency: .notAvailable
        case .invalidResponse: .decoding
        case .connectionFailed: .network
        case .requestFailed(let status): .http(status)
        }
    }
}
