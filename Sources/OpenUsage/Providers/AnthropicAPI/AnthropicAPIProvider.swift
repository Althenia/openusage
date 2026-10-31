import Foundation

@MainActor
final class AnthropicAPIProvider: ProviderRuntime, APIKeyManaging {
    let provider = Provider(
        id: "anthropicAPI", displayName: "Anthropic API", icon: .providerMark("claude"),
        links: [
            ProviderLink(label: "Usage", url: "https://platform.claude.com/usage")
        ]
    )

    let authStore: AnthropicAPIAuthStore
    let usageClient: AnthropicAPIUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: AnthropicAPIAuthStore = AnthropicAPIAuthStore(),
        usageClient: AnthropicAPIUsageClient = AnthropicAPIUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .values(id: "anthropicAPI.usage", provider: provider, title: "Usage",
                    selection: .kind(.count), isUsagePeriod: true),
            .values(id: "anthropicAPI.cost", provider: provider, title: "Cost",
                    selection: .kind(.dollars), isUsagePeriod: true)
        ]
    }

    var apiKeyStatus: APIKeyStatus { authStore.keyStatus() }
    func currentAPIKey() -> String? { authStore.currentAPIKey() }
    func saveAPIKey(_ key: String) throws { try authStore.saveAPIKey(key) }
    func deleteAPIKey() throws { try authStore.deleteAPIKey() }

    func hasLocalCredentials() async -> Bool {
        await loadOffMainActor { [authStore] in authStore.loadAPIKey() } != nil
    }

    func refresh() async -> ProviderSnapshot {
        guard let key = await loadOffMainActor({ [authStore] in authStore.loadAPIKey() }) else {
            return ProviderSnapshot.error(provider: provider, error: AnthropicAPIError.missingKey)
        }
        let refreshedAt = now()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let startingAt = calendar.date(from: calendar.dateComponents([.year, .month], from: refreshedAt))!
        let endingAt = Date(timeIntervalSince1970: floor(refreshedAt.timeIntervalSince1970 / 3600) * 3600)
        guard endingAt > startingAt else {
            return ProviderSnapshot.error(provider: provider, error: AnthropicAPIError.missingData)
        }

        let usage = await load {
            try await usageClient.fetchUsage(apiKey: key, startingAt: startingAt, endingAt: endingAt)
        }
        let cost = await load {
            try await usageClient.fetchCost(apiKey: key, startingAt: startingAt, endingAt: endingAt)
        }
        var lines: [MetricLine] = []
        var notices = [
            "Current UTC month through \(OpenUsageISO8601.string(from: endingAt)); reports are not final.",
            "Cost is after discounts, before credits, and excludes separately billed Priority Tier commitment fees."
        ]
        var failures: [String] = []
        var firstError: AnthropicAPIError?
        for (label, result) in [("Usage", usage), ("Cost", cost)] {
            switch result {
            case .success(let report):
                lines.append(label == "Usage"
                    ? AnthropicAPIUsageMapper.usageLine(report)
                    : AnthropicAPIUsageMapper.costLine(report))
                if report.dataRefreshedAt < endingAt {
                    notices.append("\(label) incomplete after \(OpenUsageISO8601.string(from: report.dataRefreshedAt)).")
                }
            case .failure(let error):
                let message = "\(label) unavailable: \(error.localizedDescription)"
                failures.append(message)
                firstError = firstError ?? error
                AppLog.error(LogTag.plugin(provider.id), message)
            }
        }
        if let firstError, lines.isEmpty {
            return ProviderSnapshot.error(
                provider: provider, message: failures.joined(separator: " "), category: firstError.errorCategory
            )
        }
        return ProviderSnapshot.make(
            provider: provider, plan: nil, lines: lines, refreshedAt: refreshedAt,
            warning: (failures + notices).joined(separator: " ")
        )
    }

    private func load(
        _ call: () async throws -> AnthropicAPIReport
    ) async -> Result<AnthropicAPIReport, AnthropicAPIError> {
        do {
            return .success(try await call())
        } catch {
            return .failure(error as? AnthropicAPIError ?? .connectionFailed)
        }
    }
}
