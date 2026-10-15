import Foundation

/// Maps a YCoding request's `model.providerID` to the OpenUsage provider whose card its usage
/// belongs on. YCoding drives other providers' models, so its usage is attributed back to the
/// underlying provider (a Claude subscription used inside YCoding lands on the Claude card), the
/// same fold-in rule pi gets. Provider IDs with no spend-card equivalent (`muse`, `custom-openai`,
/// local gateways, …) are intentionally absent and excluded.
enum YCodingProviderMapping {
    static let providerToCard: [String: String] = [
        "anthropic": "claude",
        "openai": "codex",
        "openai-codex": "codex"
    ]

    static func cardID(forYCodingProvider provider: String) -> String? {
        providerToCard[provider]
    }

    static func providerIDs(forCard cardID: String) -> [String] {
        providerToCard.filter { $0.value == cardID }.map(\.key).sorted()
    }
}
