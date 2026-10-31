import XCTest
@testable import OpenUsage

@MainActor
final class AnthropicAPIUsageClientTests: XCTestCase {
    func testHTTPFailuresHaveExplicitCapabilityAndAuthErrors() async {
        for (status, expected) in [
            (401, AnthropicAPIError.invalidKey), (403, .permissionDenied),
            (404, .unsupported), (405, .unsupported), (501, .unsupported),
            (429, .requestFailed(429)), (500, .requestFailed(500))
        ] {
            await assertUsageFailure([AnthropicAPIFixture.response([:], status: status)], expected)
        }
    }

    func testMissingNullAndMalformedReportFieldsNeverBecomeZero() async {
        for body in [
            "{}", "null", "[]", "not json",
            #"{"data":null,"has_more":false,"next_page":null,"data_refreshed_at":"2026-10-31T18:00:00Z"}"#,
            #"{"data":[],"has_more":false,"next_page":null}"#,
            #"{"data":[],"next_page":null,"data_refreshed_at":"2026-10-31T18:00:00Z"}"#,
            #"{"data":[],"has_more":false,"data_refreshed_at":"2026-10-31T18:00:00Z"}"#,
            #"{"data":[],"has_more":false,"next_page":null,"data_refreshed_at":"invalid"}"#
        ] {
            await assertUsageFailure([HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))], .invalidResponse)
        }
        await assertUsageFailure([AnthropicAPIFixture.page(watermark: nil)], .missingData)
        await assertUsageFailure([AnthropicAPIFixture.page(watermark: "2026-09-30T00:00:00Z")], .missingData)
        await assertUsageFailure([AnthropicAPIFixture.page(watermark: "2026-10-01T00:00:00Z")], .missingData)
    }

    func testInvalidTokenCountsAndMissingTotalAreRejected() async {
        let invalidCounts: [Any] = [-1, 1.5, true, "150", NSNull()]
        for tokens in invalidCounts {
            await assertUsageFailure([AnthropicAPIFixture.page([AnthropicAPIFixture.usage(tokens)])], .invalidResponse)
        }
        var row = AnthropicAPIFixture.usage()
        row["usage"] = ["uncached_input_tokens": 150]
        await assertUsageFailure([AnthropicAPIFixture.page([row])], .invalidResponse)
    }

    func testMalformedMoneyAndUnsupportedCurrencyAreRejected() async {
        let invalidAmounts: [Any] = ["", "NaN", "Infinity", "12oops", "1,000", "1e10", 12, NSNull()]
        for amount in invalidAmounts {
            await assertCostFailure(AnthropicAPIFixture.page([AnthropicAPIFixture.cost(amount)]), .invalidResponse)
        }
        await assertCostFailure(AnthropicAPIFixture.page([AnthropicAPIFixture.cost(currency: "EUR")]), .unsupportedCurrency)
        var row = AnthropicAPIFixture.cost()
        row["cost"] = ["currency": "USD"]
        await assertCostFailure(AnthropicAPIFixture.page([row]), .invalidResponse)
        row["cost"] = ["amount": "123"]
        await assertCostFailure(AnthropicAPIFixture.page([row]), .invalidResponse)
    }

    func testMissingRepeatedAndContradictoryCursorsAreRejected() async {
        await assertUsageFailure([AnthropicAPIFixture.page(more: true)], .invalidResponse)
        await assertUsageFailure([AnthropicAPIFixture.page(more: true, next: "")], .invalidResponse)
        await assertUsageFailure([AnthropicAPIFixture.page(next: "unexpected")], .invalidResponse)
        await assertUsageFailure([AnthropicAPIFixture.page(more: true, next: "empty-page")], .invalidResponse)
        await assertUsageFailure([
            AnthropicAPIFixture.page([AnthropicAPIFixture.usage()], more: true, next: "repeat"),
            AnthropicAPIFixture.page([AnthropicAPIFixture.usage(25, hour: 1)], more: true, next: "repeat")
        ], .invalidResponse)
    }

    func testChangedSnapshotDuringPaginationIsRejected() async {
        await assertUsageFailure([
            AnthropicAPIFixture.page([AnthropicAPIFixture.usage()], more: true, next: "next"),
            AnthropicAPIFixture.page(watermark: "2026-10-31T17:00:00Z")
        ], .invalidResponse)
    }

    func testDuplicateOverlappingAndOutOfRangeBucketsAreRejected() async {
        let row = AnthropicAPIFixture.usage()
        await assertUsageFailure([AnthropicAPIFixture.page([row, row])], .invalidResponse)
        for (start, end) in [
            ("2026-09-30T23:00:00Z", "2026-10-01T00:00:00Z"),
            ("2026-10-31T18:00:00Z", "2026-10-31T19:00:00Z"),
            ("2026-10-01T00:00:00Z", "2026-10-01T00:00:00Z"),
            ("invalid", "2026-10-01T01:00:00Z"),
            ("2026-10-01T00:30:00Z", "2026-10-01T01:30:00Z")
        ] {
            var invalid = row
            invalid["starting_at"] = start
            invalid["ending_at"] = end
            await assertUsageFailure([AnthropicAPIFixture.page([invalid])], .invalidResponse)
        }
    }

    func testExpiredCursorRestartsFromFirstPageAndDiscardsOldSubtotal() async throws {
        let http = AnthropicAPIHTTP([
            AnthropicAPIFixture.page([AnthropicAPIFixture.usage(999)], more: true, next: "expired"),
            AnthropicAPIFixture.response([:], status: 410),
            AnthropicAPIFixture.page([AnthropicAPIFixture.usage(25)])
        ])
        let report = try await AnthropicAPIUsageClient(http: http).fetchUsage(
            apiKey: "synthetic-admin-key", startingAt: AnthropicAPIFixture.start, endingAt: AnthropicAPIFixture.end
        )
        XCTAssertEqual(report.value, 25)
        let requests = await http.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertNil(AnthropicAPIFixture.query(requests[2])["page"])
    }

    func testRepeatedCursorExpiryFailsWithoutInfiniteRestart() async {
        await assertUsageFailure([
            AnthropicAPIFixture.page([AnthropicAPIFixture.usage()], more: true, next: "first"),
            AnthropicAPIFixture.response([:], status: 410),
            AnthropicAPIFixture.page([AnthropicAPIFixture.usage()], more: true, next: "second"),
            AnthropicAPIFixture.response([:], status: 410)
        ], .paginationExpired)
    }

    private func assertUsageFailure(_ responses: [HTTPResponse], _ expected: AnthropicAPIError) async {
        do {
            _ = try await AnthropicAPIUsageClient(http: AnthropicAPIHTTP(responses)).fetchUsage(
                apiKey: "synthetic-admin-key", startingAt: AnthropicAPIFixture.start, endingAt: AnthropicAPIFixture.end
            )
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? AnthropicAPIError, expected)
        }
    }

    private func assertCostFailure(_ response: HTTPResponse, _ expected: AnthropicAPIError) async {
        do {
            _ = try await AnthropicAPIUsageClient(http: AnthropicAPIHTTP([response])).fetchCost(
                apiKey: "synthetic-admin-key", startingAt: AnthropicAPIFixture.start, endingAt: AnthropicAPIFixture.end
            )
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? AnthropicAPIError, expected)
        }
    }
}
