import Foundation

@MainActor
final class OpenAIAPIProvider: ProviderRuntime, APIKeyManaging {
    let provider = Provider(
        id: "openaiAPI",
        displayName: "OpenAI API",
        icon: .providerMark("codex"),
        links: [
            ProviderLink(label: "Usage", url: "https://platform.openai.com/usage"),
            ProviderLink(label: "Status", url: "https://status.openai.com")
        ]
    )

    let authStore: OpenAIAPIAuthStore
    let usageClient: OpenAIAPIUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: OpenAIAPIAuthStore = OpenAIAPIAuthStore(),
        usageClient: OpenAIAPIUsageClient = OpenAIAPIUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .values(id: "openaiAPI.usage", provider: provider, title: "Completions Tokens",
                    selection: .kind(.count), isUsagePeriod: true),
            .values(id: "openaiAPI.cost", provider: provider, title: "Cost",
                    selection: .kind(.dollars), isUsagePeriod: true)
        ]
    }

    func hasLocalCredentials() async -> Bool {
        await loadOffMainActor { [authStore] in authStore.loadAPIKey() } != nil
    }

    func refresh() async -> ProviderSnapshot {
        guard let key = await loadOffMainActor({ [authStore] in authStore.loadAPIKey() }) else {
            return .error(provider: provider, error: OpenAIAPIAuthError.missingKey)
        }
        let refreshedAt = now()
        do {
            let report = try await usageClient.fetchMonth(apiKey: key, now: refreshedAt)
            return .make(
                provider: provider, plan: nil, lines: OpenAIAPIUsageMapper.lines(from: report),
                refreshedAt: refreshedAt
            )
        } catch {
            AppLog.error(LogTag.plugin("openaiAPI"), "Organization usage refresh failed (\((error as? CategorizedError)?.errorCategory.rawValue ?? "other"))")
            return .error(provider: provider, error: error)
        }
    }

    var apiKeyStatus: APIKeyStatus { authStore.keyStatus() }
    func currentAPIKey() -> String? { authStore.currentAPIKey() }
    func saveAPIKey(_ key: String) throws { try authStore.saveAPIKey(key) }
    func deleteAPIKey() throws { try authStore.deleteAPIKey() }
}
