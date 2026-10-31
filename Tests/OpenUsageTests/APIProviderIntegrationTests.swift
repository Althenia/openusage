import XCTest
@testable import OpenUsage

@MainActor
final class APIProviderIntegrationTests: XCTestCase {
    private let apiMetricIDs = [
        "anthropicAPI.usage", "anthropicAPI.cost", "openaiAPI.usage", "openaiAPI.cost"
    ]

    func testDefaultSeedsEnableUsageThenCostAlwaysVisibleAndUnpinned() {
        for id in apiMetricIDs {
            XCTAssertTrue(DefaultLayout.metricIDs.contains(id), id)
            XCTAssertFalse(DefaultLayout.expandedMetricIDs.contains(id), id)
            XCTAssertFalse(DefaultLayout.pinnedMetricIDs.contains(id), id)
            XCTAssertFalse(DefaultLayout.migrationBaselineMetricIDs.contains(id), id)
        }
        XCTAssertEqual(DefaultLayout.metricIDs.filter { $0.hasPrefix("anthropicAPI.") }, [
            "anthropicAPI.usage", "anthropicAPI.cost"
        ])
        XCTAssertEqual(DefaultLayout.metricIDs.filter { $0.hasPrefix("openaiAPI.") }, [
            "openaiAPI.usage", "openaiAPI.cost"
        ])
    }

    func testFreshLayoutPlacesBothAPIProvidersAboveTheFoldWithoutPins() {
        let store = LayoutStore(
            registry: WidgetRegistry.from(syntheticProviders()),
            defaults: makeDefaults("FreshAPIProviders"),
            storageKey: "layout"
        )

        XCTAssertEqual(store.placed.map(\.descriptorID), apiMetricIDs)
        XCTAssertTrue(store.pinnedMetricIDs.isEmpty)
        XCTAssertTrue(store.expandedMetricIDs.isEmpty)
        for providerID in ["anthropicAPI", "openaiAPI"] {
            let group = store.customizeGroups.first { $0.provider.id == providerID }
            XCTAssertEqual(group?.alwaysShownMetrics.map(\.id), ["\(providerID).usage", "\(providerID).cost"])
            XCTAssertEqual(group?.expandedMetrics.map(\.id), [])
        }
        XCTAssertTrue(store.spendCapableProviders.isEmpty)
    }

    func testAPIProvidersExposeKeyManagementAndStayOfflineWithoutKeys() async {
        let anthropic = syntheticProviders()[0]
        let openai = syntheticProviders()[1]
        for provider in [anthropic, openai] {
            XCTAssertTrue(provider is any APIKeyManaging, provider.provider.id)
            let detected = await provider.hasLocalCredentials()
            XCTAssertFalse(detected, provider.provider.id)
        }
        XCTAssertEqual([anthropic, openai].compactMap { $0 as? any APIKeyManaging }.map(\.provider.id), [
            "anthropicAPI", "openaiAPI"
        ])
    }

    private func syntheticProviders() -> [ProviderRuntime] {
        [
            AnthropicAPIProvider(
                authStore: AnthropicAPIFixture.auth(nil),
                usageClient: AnthropicAPIUsageClient(http: AnthropicAPIHTTP([]))
            ),
            OpenAIAPIProvider(
                authStore: OpenAIAPIFixture.auth(key: nil),
                usageClient: OpenAIAPIUsageClient(http: OpenAIAPIHTTPFixture([]))
            )
        ]
    }

    private func makeDefaults(_ name: String) -> AppPreferences {
        TestPreferences.make(name)
    }
}
