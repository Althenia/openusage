import Foundation

@MainActor
final class MuseProvider: ProviderRuntime {
    let provider = Provider(id: "muse", displayName: "Muse", icon: .providerMark("muse"))

    let authStore: MuseAuthStore
    let usageClient: MuseUsageClient
    let now: @Sendable () -> Date
    private var cachedAPIKey: String?
    private var lastManualSnapshot: ProviderSnapshot?
    private static let manualRefreshNotice =
        "Refresh Muse manually to check subscription usage. This sends a small model request that may consume usage."

    init(
        authStore: MuseAuthStore = MuseAuthStore(),
        usageClient: MuseUsageClient = MuseUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "muse.session", provider: provider, title: "Session")
                .exportingLimit("session", unit: "percent"),
            .percent(id: "muse.weekly", provider: provider, title: "Weekly")
                .exportingLimit("weekly", unit: "percent")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        await loadOffMainActor { [authStore] in
            guard (try? authStore.loadAPIBaseURL()) != nil else { return false }
            return authStore.hasKeychainItem()
        }
    }

    func refresh() async -> ProviderSnapshot {
        // Muse reports quotas inside an inference response. Startup and polling must never spend
        // usage or access credentials; only an explicit refresh authorizes that model request.
        guard ProviderRefreshContext.isManual else {
            guard var snapshot = lastManualSnapshot else {
                return .error(provider: provider, message: Self.manualRefreshNotice, category: .notAvailable)
            }
            snapshot.warning = "Showing the last manual result. " + Self.manualRefreshNotice
            return snapshot
        }
        do {
            let lines = try await loadUsage(allowInteraction: true)
            let snapshot = ProviderSnapshot.make(provider: provider, plan: nil, lines: lines, refreshedAt: now())
            lastManualSnapshot = snapshot
            return snapshot
        } catch {
            // A failed login or account change must not revive another account's retained quota.
            lastManualSnapshot = nil
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    private func loadUsage(allowInteraction: Bool) async throws -> [MetricLine] {
        let apiBaseURL: URL?
        do {
            apiBaseURL = try await loadOffMainActor { [authStore] in try authStore.loadAPIBaseURL() }
        } catch {
            cachedAPIKey = nil
            throw error
        }
        guard let apiBaseURL else {
            cachedAPIKey = nil
            throw MuseAuthError.notLoggedIn
        }

        if let cachedAPIKey {
            let response = try await fetch(apiKey: cachedAPIKey, apiBaseURL: apiBaseURL)
            if !ProviderAuthRetry.isAuthFailure(response) { return try Self.lines(from: response) }
            self.cachedAPIKey = nil
        }

        guard let apiKey = try await loadOffMainActor({ [authStore] in
            try authStore.readAPIKey(allowInteraction: allowInteraction)
        }) else {
            throw MuseAuthError.notLoggedIn
        }
        let response = try await fetch(apiKey: apiKey, apiBaseURL: apiBaseURL)
        guard !ProviderAuthRetry.isAuthFailure(response) else { throw MuseUsageError.unauthorized }
        cachedAPIKey = apiKey
        return try Self.lines(from: response)
    }

    private func fetch(apiKey: String, apiBaseURL: URL) async throws -> HTTPResponse {
        do {
            return try await usageClient.fetchUsage(credentials: MuseCredentials(apiKey: apiKey, apiBaseURL: apiBaseURL))
        } catch {
            throw MuseUsageError.connectionFailed
        }
    }

    private static func lines(from response: HTTPResponse) throws -> [MetricLine] {
        guard (200..<300).contains(response.statusCode) else {
            throw MuseUsageError.requestFailed(response.statusCode)
        }
        do {
            return try MuseUsageMapper.map(eventStreamBody: response.body)
        } catch {
            AppLog.error(.refresh, "muse subscription usage response unavailable")
            throw MuseUsageError.usageUnavailable
        }
    }
}
