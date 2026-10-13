import Foundation

@MainActor
final class MuseProvider: ProviderRuntime {
    let provider = Provider(id: "muse", displayName: "Muse", icon: .providerMark("muse"))

    let authStore: MuseAuthStore
    let usageClient: MuseUsageClient
    let now: @Sendable () -> Date

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
        do {
            guard try await loadOffMainActor({ [authStore] in
                try authStore.loadCredentials()
            }) != nil else { return false }
            return true
        } catch {
            return false
        }
    }

    func refresh() async -> ProviderSnapshot {
        let credentials: MuseCredentials
        do {
            guard let loaded = try await loadOffMainActor({ [authStore] in
                try authStore.loadCredentials()
            }) else {
                return ProviderSnapshot.error(provider: provider, error: MuseAuthError.notLoggedIn)
            }
            credentials = loaded
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }

        let response: HTTPResponse
        do {
            response = try await usageClient.fetchUsage(credentials: credentials)
        } catch {
            return ProviderSnapshot.error(provider: provider, error: MuseUsageError.connectionFailed)
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            return ProviderSnapshot.error(provider: provider, error: MuseUsageError.unauthorized)
        }
        guard (200..<300).contains(response.statusCode) else {
            return ProviderSnapshot.error(provider: provider, error: MuseUsageError.requestFailed(response.statusCode))
        }

        do {
            let lines = try MuseUsageMapper.map(eventStreamBody: response.body)
            return ProviderSnapshot.make(provider: provider, plan: nil, lines: lines, refreshedAt: now())
        } catch {
            AppLog.error(.refresh, "muse subscription usage response unavailable")
            return ProviderSnapshot.error(provider: provider, error: MuseUsageError.usageUnavailable)
        }
    }
}
