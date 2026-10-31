import XCTest
@testable import OpenUsage

@MainActor
final class OpenAIAPIProviderTests: XCTestCase {
    func testIdentityDescriptorsAndAPIKeyManagement() throws {
        let files = FakeFiles()
        let provider = OpenAIAPIProvider(authStore: OpenAIAPIAuthStore(files: files, environment: FakeEnvironment()))
        XCTAssertEqual(provider.provider.id, "openaiAPI")
        XCTAssertEqual(provider.provider.displayName, "OpenAI API")
        XCTAssertEqual(provider.widgetDescriptors.map(\.id), ["openaiAPI.usage", "openaiAPI.cost"])
        XCTAssertEqual(provider.widgetDescriptors.map(\.sample.title), ["Completions Tokens", "Cost"])
        let manager: any APIKeyManaging = provider
        XCTAssertEqual(manager.apiKeyStatus, .notSet)
        try manager.saveAPIKey("synthetic-managed")
        XCTAssertEqual(manager.currentAPIKey(), "synthetic-managed")
        try manager.deleteAPIKey()
        XCTAssertNil(manager.currentAPIKey())
    }

    func testRefreshMapsCompleteMultimodalTokensOnceAndActualCost() async {
        var completion = OpenAIAPIFixture.completion()
        completion["input_audio_tokens"] = 10
        completion["output_audio_tokens"] = 5
        completion["input_cache_write_tokens"] = 15
        let http = OpenAIAPIHTTPFixture([
            OpenAIAPIFixture.response(OpenAIAPIFixture.page([OpenAIAPIFixture.bucket([completion])])),
            OpenAIAPIFixture.response(OpenAIAPIFixture.page([OpenAIAPIFixture.bucket([OpenAIAPIFixture.cost()])]))
        ])
        let provider = makeProvider(http)
        let hasCredentials = await provider.hasLocalCredentials()
        XCTAssertTrue(hasCredentials)
        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.refreshedAt, OpenAIAPIFixture.now)
        XCTAssertEqual(OpenAIAPIFixture.number(snapshot, label: "Completions Tokens", kind: .count), 125)
        XCTAssertEqual(OpenAIAPIFixture.number(snapshot, label: "Cost", kind: .dollars), 1.25)
        XCTAssertNil(snapshot.usageHistory)
    }

    func testValidEmptyReportsProduceMeasuredZeros() async {
        let http = OpenAIAPIHTTPFixture([
            OpenAIAPIFixture.response(OpenAIAPIFixture.page()),
            OpenAIAPIFixture.response(OpenAIAPIFixture.page([OpenAIAPIFixture.bucket([])]))
        ])
        let snapshot = await makeProvider(http).refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(OpenAIAPIFixture.number(snapshot, label: "Completions Tokens", kind: .count), 0)
        XCTAssertEqual(OpenAIAPIFixture.number(snapshot, label: "Cost", kind: .dollars), 0)
    }

    func testMissingAdminKeyDoesNotRequestAnything() async {
        let http = OpenAIAPIHTTPFixture([])
        let provider = OpenAIAPIProvider(authStore: OpenAIAPIFixture.auth(key: nil), usageClient: OpenAIAPIUsageClient(http: http))
        let hasCredentials = await provider.hasLocalCredentials()
        XCTAssertFalse(hasCredentials)
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        let requests = await http.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testHTTPFailuresRemainExplicitWithoutNumericRows() async {
        for (status, category) in [(401, ErrorCategory.authInvalid), (403, .http4xx), (404, .notAvailable), (429, .rateLimited), (500, .http5xx)] {
            let http = OpenAIAPIHTTPFixture([OpenAIAPIFixture.response([:], status: status)])
            let snapshot = await makeProvider(http).refresh()
            XCTAssertEqual(snapshot.errorCategory, category, "HTTP \(status)")
            XCTAssertTrue(snapshot.lines.contains(where: \.isError))
            XCTAssertNil(OpenAIAPIFixture.number(snapshot, label: "Completions Tokens", kind: .count))
            if status == 403 {
                guard case .badge(_, let text, _, _) = snapshot.lines.first else { return XCTFail("Missing error") }
                XCTAssertTrue(text.contains("Admin"))
                XCTAssertTrue(text.contains("permission"))
            }
        }
    }

    func testCostFailureDoesNotTurnIntoZeroOrSuccessfulPartialReport() async {
        let http = OpenAIAPIHTTPFixture([
            OpenAIAPIFixture.response(OpenAIAPIFixture.page([OpenAIAPIFixture.bucket([OpenAIAPIFixture.completion()])])),
            OpenAIAPIFixture.response([:], status: 403)
        ])
        let snapshot = await makeProvider(http).refresh()
        XCTAssertEqual(snapshot.errorCategory, .http4xx)
        XCTAssertTrue(snapshot.lines.contains(where: \.isError))
        XCTAssertNil(OpenAIAPIFixture.number(snapshot, label: "Cost", kind: .dollars))
    }

    func testTransportFailureIsNetworkError() async {
        let snapshot = await makeProvider(OpenAIAPIThrowingHTTP()).refresh()
        XCTAssertEqual(snapshot.errorCategory, .network)
    }

    private func makeProvider(_ http: any HTTPClient) -> OpenAIAPIProvider {
        OpenAIAPIProvider(
            authStore: OpenAIAPIFixture.auth(), usageClient: OpenAIAPIUsageClient(http: http),
            now: { OpenAIAPIFixture.now }
        )
    }
}
