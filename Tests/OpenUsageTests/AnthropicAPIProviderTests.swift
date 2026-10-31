import XCTest
@testable import OpenUsage

@MainActor
final class AnthropicAPIProviderTests: XCTestCase {
    func testIdentityDescriptorsAndAPIKeyManagement() throws {
        let provider = makeProvider(AnthropicAPIHTTP([]))
        XCTAssertEqual(provider.provider.id, "anthropicAPI")
        XCTAssertEqual(provider.provider.displayName, "Anthropic API")
        XCTAssertEqual(provider.widgetDescriptors.map(\.id), ["anthropicAPI.usage", "anthropicAPI.cost"])
        XCTAssertEqual(provider.widgetDescriptors.map(\.metricLabel), ["Usage", "Cost"])
        let managing: any APIKeyManaging = provider
        XCTAssertEqual(managing.apiKeyStatus, .fromEnvironment)
        try managing.saveAPIKey("saved-key")
        XCTAssertEqual(managing.currentAPIKey(), "saved-key")
        try managing.deleteAPIKey()
        XCTAssertEqual(managing.currentAPIKey(), "synthetic-admin-key")
    }

    func testRefreshUsesOfficialRequestsAndCountsCachedTokensOnce() async throws {
        let http = AnthropicAPIHTTP([
            AnthropicAPIFixture.page([AnthropicAPIFixture.usage()]),
            AnthropicAPIFixture.page([AnthropicAPIFixture.cost()])
        ])
        let snapshot = await makeProvider(http).refresh()
        XCTAssertEqual(number(snapshot, "Usage"), 150)
        XCTAssertEqual(try XCTUnwrap(number(snapshot, "Cost")), 1.2378912, accuracy: 0.00000001)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Usage", "Cost"])
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.refreshedAt, AnthropicAPIFixture.now)
        XCTAssertTrue(snapshot.warning?.contains("commitment") == true)
        XCTAssertTrue(snapshot.warning?.contains("not final") == true)
        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.method, "GET")
            XCTAssertEqual(request.url.host, "api.anthropic.com")
            XCTAssertEqual(request.headers["x-api-key"], "synthetic-admin-key")
            XCTAssertEqual(request.headers["anthropic-version"], "2023-06-01")
            XCTAssertEqual(request.headers["anthropic-beta"], "analytics-usage-cost-2026-08-24")
            XCTAssertNil(request.headers["Authorization"])
            let query = AnthropicAPIFixture.query(request)
            XCTAssertEqual(OpenUsageISO8601.date(from: try XCTUnwrap(query["starting_at"])), AnthropicAPIFixture.start)
            XCTAssertEqual(OpenUsageISO8601.date(from: try XCTUnwrap(query["ending_at"])), AnthropicAPIFixture.end)
            XCTAssertEqual(query["time_bucket_width"], "1h")
            XCTAssertEqual(query["limit"], "1000")
            XCTAssertNil(query["group_by[]"])
        }
        XCTAssertEqual(requests[0].url.path, "/v1/organizations/analytics/usage")
        XCTAssertEqual(AnthropicAPIFixture.query(requests[0])["products[]"], "messages_api")
        XCTAssertEqual(requests[1].url.path, "/v1/organizations/analytics/cost")
        XCTAssertNil(AnthropicAPIFixture.query(requests[1])["products[]"])
        guard case .values(_, let values, _, _, _, _) = snapshot.line(label: "Cost") else {
            return XCTFail("Expected actual USD values")
        }
        XCTAssertEqual(values.first?.kind, .dollars)
        XCTAssertEqual(values.first?.estimated, false)
    }

    func testBothReportsFollowOpaquePaginationWithoutChangingRange() async {
        let http = AnthropicAPIHTTP([
            AnthropicAPIFixture.page([AnthropicAPIFixture.usage()], more: true, next: "usage+/= cursor"),
            AnthropicAPIFixture.page([AnthropicAPIFixture.usage(25, hour: 1)]),
            AnthropicAPIFixture.page([AnthropicAPIFixture.cost("100.125")], more: true, next: "cost+/= cursor"),
            AnthropicAPIFixture.page([AnthropicAPIFixture.cost("200.375", hour: 1)])
        ])
        let snapshot = await makeProvider(http).refresh()
        XCTAssertEqual(number(snapshot, "Usage"), 175)
        XCTAssertEqual(number(snapshot, "Cost"), 3.005)
        let requests = await http.requests
        XCTAssertEqual(requests.count, 4)
        guard requests.count == 4 else { return }
        XCTAssertEqual(AnthropicAPIFixture.query(requests[1])["page"], "usage+/= cursor")
        XCTAssertEqual(AnthropicAPIFixture.query(requests[3])["page"], "cost+/= cursor")
        for (first, next) in [(requests[0], requests[1]), (requests[2], requests[3])] {
            var query = AnthropicAPIFixture.query(next)
            query.removeValue(forKey: "page")
            XCTAssertEqual(query, AnthropicAPIFixture.query(first))
        }
    }

    func testWellFormedEmptyReportsAreZero() async {
        let snapshot = await makeProvider(AnthropicAPIHTTP([
            AnthropicAPIFixture.page(), AnthropicAPIFixture.page()
        ])).refresh()
        XCTAssertEqual(number(snapshot, "Usage"), 0)
        XCTAssertEqual(number(snapshot, "Cost"), 0)
        XCTAssertNil(snapshot.errorCategory)
    }

    func testMissingKeyProbeAndRefreshStayOffline() async {
        let http = AnthropicAPIHTTP([])
        let provider = AnthropicAPIProvider(
            authStore: AnthropicAPIFixture.auth(nil), usageClient: AnthropicAPIUsageClient(http: http)
        )
        let detected = await provider.hasLocalCredentials()
        XCTAssertFalse(detected)
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testConfiguredProbeNeverUsesHTTP() async {
        let http = AnthropicAPIHTTP([])
        let detected = await makeProvider(http).hasLocalCredentials()
        XCTAssertTrue(detected)
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testPartialFailureKeepsOnlyCompleteMetricAndNamesMissingMetric() async {
        for failedUsage in [true, false] {
            let success = failedUsage
                ? AnthropicAPIFixture.page([AnthropicAPIFixture.cost()])
                : AnthropicAPIFixture.page([AnthropicAPIFixture.usage()])
            let denied = AnthropicAPIFixture.response([:], status: 403)
            let snapshot = await makeProvider(AnthropicAPIHTTP(failedUsage ? [denied, success] : [success, denied])).refresh()
            XCTAssertNil(number(snapshot, failedUsage ? "Usage" : "Cost"))
            XCTAssertNotNil(number(snapshot, failedUsage ? "Cost" : "Usage"))
            XCTAssertTrue(snapshot.warning?.contains(failedUsage ? "Usage" : "Cost") == true)
            XCTAssertTrue(snapshot.warning?.contains("permission") == true)
        }
    }

    func testLatePageFailureDiscardsEndpointSubtotal() async {
        let snapshot = await makeProvider(AnthropicAPIHTTP([
            AnthropicAPIFixture.page([AnthropicAPIFixture.usage()], more: true, next: "next"),
            AnthropicAPIFixture.response([:], status: 500),
            AnthropicAPIFixture.page([AnthropicAPIFixture.cost()])
        ])).refresh()
        XCTAssertNil(number(snapshot, "Usage"))
        XCTAssertNotNil(number(snapshot, "Cost"))
        XCTAssertTrue(snapshot.warning?.contains("Usage") == true)
    }

    func testTransportFailureNeverBecomesZero() async {
        let snapshot = await makeProvider(AnthropicAPIHTTP([])).refresh()
        XCTAssertNil(number(snapshot, "Usage"))
        XCTAssertNil(number(snapshot, "Cost"))
        XCTAssertEqual(snapshot.errorCategory, .network)
    }

    func testUTCMonthAndYearRollover() async {
        for (instant, expectedStart, expectedEnd) in [
            ("2027-01-01T02:15:00+02:00", "2027-01-01T00:00:00Z", "2027-01-01T00:00:00Z"),
            ("2026-11-01T00:30:00+02:00", "2026-10-01T00:00:00Z", "2026-10-31T22:00:00Z"),
            ("2027-01-01T03:15:00Z", "2027-01-01T00:00:00Z", "2027-01-01T03:00:00Z")
        ] {
            let http = AnthropicAPIHTTP([AnthropicAPIFixture.page(), AnthropicAPIFixture.page()])
            let snapshot = await makeProvider(http, now: AnthropicAPIFixture.date(instant)).refresh()
            let requests = await http.requests
            if expectedStart == expectedEnd {
                XCTAssertTrue(requests.isEmpty)
                XCTAssertEqual(snapshot.errorCategory, .notAvailable)
            } else if let request = requests.first {
                let query = AnthropicAPIFixture.query(request)
                XCTAssertEqual(query["starting_at"].flatMap(OpenUsageISO8601.date(from:)), AnthropicAPIFixture.date(expectedStart))
                XCTAssertEqual(query["ending_at"].flatMap(OpenUsageISO8601.date(from:)), AnthropicAPIFixture.date(expectedEnd))
            } else {
                XCTFail("Expected report request")
            }
        }
    }

    func testLaggingWatermarkIsVisible() async {
        let http = AnthropicAPIHTTP([
            AnthropicAPIFixture.page(watermark: "2026-10-31T12:00:00Z"),
            AnthropicAPIFixture.page(watermark: "2026-10-31T13:00:00Z")
        ])
        let snapshot = await makeProvider(http).refresh()
        XCTAssertTrue(snapshot.warning?.contains("2026-10-31T12:00:00") == true)
        XCTAssertTrue(snapshot.warning?.contains("2026-10-31T13:00:00") == true)
        XCTAssertTrue(snapshot.warning?.contains("incomplete") == true)
    }

    private func makeProvider(_ http: AnthropicAPIHTTP, now: Date = AnthropicAPIFixture.now) -> AnthropicAPIProvider {
        AnthropicAPIProvider(
            authStore: AnthropicAPIFixture.auth(),
            usageClient: AnthropicAPIUsageClient(http: http),
            now: { now }
        )
    }

    private func number(_ snapshot: ProviderSnapshot, _ label: String) -> Double? {
        guard case .values(_, let values, _, _, _, _) = snapshot.line(label: label) else { return nil }
        return values.first?.number
    }
}
