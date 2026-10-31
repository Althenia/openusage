import XCTest
@testable import OpenUsage

final class OpenAIAPIUsageClientTests: XCTestCase {
    func testBothReportsPaginateWithUTCMonthRangeAndOpaqueCursors() async throws {
        let cursor = "next+page/=synthetic"
        let http = OpenAIAPIHTTPFixture([
            OpenAIAPIFixture.response(OpenAIAPIFixture.page([OpenAIAPIFixture.bucket([OpenAIAPIFixture.completion()])], more: true, next: cursor)),
            OpenAIAPIFixture.response(OpenAIAPIFixture.page([OpenAIAPIFixture.bucket([OpenAIAPIFixture.completion(input: 50, output: 5, cached: 10)], start: OpenAIAPIFixture.monthStart + OpenAIAPIFixture.day)])),
            OpenAIAPIFixture.response(OpenAIAPIFixture.page([OpenAIAPIFixture.bucket([OpenAIAPIFixture.cost()])], more: true, next: cursor)),
            OpenAIAPIFixture.response(OpenAIAPIFixture.page([OpenAIAPIFixture.bucket([OpenAIAPIFixture.cost(value: 2.5)], start: OpenAIAPIFixture.monthStart + OpenAIAPIFixture.day)]))
        ])
        let report = try await OpenAIAPIUsageClient(http: http).fetchMonth(apiKey: "synthetic-admin", now: OpenAIAPIFixture.now)
        XCTAssertEqual(report.tokens, 180)
        XCTAssertEqual(report.costUSD, 3.75)
        let requests = await http.recordedRequests()
        XCTAssertEqual(requests.count, 4)
        for (index, request) in requests.enumerated() {
            XCTAssertEqual(request.method, "GET")
            XCTAssertEqual(request.url.scheme, "https")
            XCTAssertEqual(request.url.host, "api.openai.com")
            XCTAssertEqual(request.url.path, index < 2 ? "/v1/organization/usage/completions" : "/v1/organization/costs")
            XCTAssertEqual(request.headers["Authorization"], "Bearer synthetic-admin")
            let query = Dictionary(uniqueKeysWithValues: try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query["start_time"], String(OpenAIAPIFixture.monthStart))
            XCTAssertEqual(query["end_time"], "1741003200")
            XCTAssertEqual(query["bucket_width"], "1d")
            XCTAssertEqual(query["limit"], "31")
            XCTAssertEqual(query["page"], index % 2 == 0 ? nil : cursor)
            XCTAssertEqual(query.count, index % 2 == 0 ? 4 : 5)
        }
    }

    func testLeapYearAndYearBoundaryUseUTCCalendarMonths() async throws {
        for (timestamp, start) in [(1_709_164_800, 1_706_745_600), (1_735_689_601, 1_735_689_600)] {
            let http = OpenAIAPIHTTPFixture([OpenAIAPIFixture.response(OpenAIAPIFixture.page()), OpenAIAPIFixture.response(OpenAIAPIFixture.page())])
            _ = try await OpenAIAPIUsageClient(http: http).fetchMonth(apiKey: "synthetic", now: Date(timeIntervalSince1970: Double(timestamp)))
            let requests = await http.recordedRequests()
            for request in requests {
                XCTAssertEqual(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "start_time" }?.value, String(start))
            }
        }
    }

    func testMalformedPageBucketAndUsageFieldsFailInsteadOfZero() async {
        var missingData = OpenAIAPIFixture.page()
        missingData.removeValue(forKey: "data")
        var missingCursor = OpenAIAPIFixture.page()
        missingCursor.removeValue(forKey: "next_page")
        var missingTokens = OpenAIAPIFixture.completion()
        missingTokens.removeValue(forKey: "input_tokens")
        var badBucket = OpenAIAPIFixture.bucket([])
        badBucket["end_time"] = OpenAIAPIFixture.monthStart
        var wrongResult = OpenAIAPIFixture.completion()
        wrongResult["object"] = "organization.usage.embeddings.result"
        let pages: [[String: Any]] = [
            [:], missingData, missingCursor,
            ["object": "list", "data": [], "has_more": false, "next_page": NSNull()],
            OpenAIAPIFixture.page([badBucket]),
            OpenAIAPIFixture.page([OpenAIAPIFixture.bucket([], start: OpenAIAPIFixture.monthStart - OpenAIAPIFixture.day)]),
            OpenAIAPIFixture.page([OpenAIAPIFixture.bucket([missingTokens])]),
            OpenAIAPIFixture.page([OpenAIAPIFixture.bucket([wrongResult])]),
            OpenAIAPIFixture.page([OpenAIAPIFixture.bucket([OpenAIAPIFixture.completion(input: -1)])]),
            OpenAIAPIFixture.page([OpenAIAPIFixture.bucket([OpenAIAPIFixture.completion(input: true)])]),
            OpenAIAPIFixture.page([OpenAIAPIFixture.bucket([OpenAIAPIFixture.completion(input: "100")])]),
            OpenAIAPIFixture.page([OpenAIAPIFixture.bucket([OpenAIAPIFixture.completion(input: NSNull())])]),
            OpenAIAPIFixture.page([OpenAIAPIFixture.bucket([OpenAIAPIFixture.completion(input: Int.max)])]),
            OpenAIAPIFixture.page([OpenAIAPIFixture.bucket([OpenAIAPIFixture.completion(output: 1.5)])]),
            OpenAIAPIFixture.page([OpenAIAPIFixture.bucket([OpenAIAPIFixture.completion(cached: 101)])])
        ]
        for page in pages {
            await assertFailure([OpenAIAPIFixture.response(page)], expected: .invalidResponse)
        }
    }

    func testIncompleteRepeatedAndOverlappingPagesFail() async {
        let bucket = OpenAIAPIFixture.bucket([OpenAIAPIFixture.completion()])
        await assertFailure([OpenAIAPIFixture.response(OpenAIAPIFixture.page([bucket], more: true))], expected: .invalidResponse)
        await assertFailure([OpenAIAPIFixture.response(OpenAIAPIFixture.page(more: true, next: "next"))], expected: .invalidResponse)
        await assertFailure([OpenAIAPIFixture.response(OpenAIAPIFixture.page(next: "unexpected"))], expected: .invalidResponse)
        await assertFailure([
            OpenAIAPIFixture.response(OpenAIAPIFixture.page([bucket], more: true, next: "repeat")),
            OpenAIAPIFixture.response(OpenAIAPIFixture.page([OpenAIAPIFixture.bucket([], start: OpenAIAPIFixture.monthStart + OpenAIAPIFixture.day)], more: true, next: "repeat"))
        ], expected: .invalidResponse)
        await assertFailure([
            OpenAIAPIFixture.response(OpenAIAPIFixture.page([bucket], more: true, next: "next")),
            OpenAIAPIFixture.response(OpenAIAPIFixture.page([bucket]))
        ], expected: .invalidResponse)
        await assertFailure([
            OpenAIAPIFixture.response(OpenAIAPIFixture.page([bucket], more: true, next: "next")),
            OpenAIAPIFixture.response([:], status: 500)
        ], expected: .requestFailed(500))
    }

    func testMissingMalformedOrUnsupportedCostNeverBecomesZero() async {
        let validUsage = OpenAIAPIFixture.response(OpenAIAPIFixture.page())
        for result in [
            ["object": "organization.costs.result"],
            ["object": "organization.costs.result", "amount": NSNull()],
            OpenAIAPIFixture.cost(value: "1.25"),
            OpenAIAPIFixture.cost(value: true),
            OpenAIAPIFixture.cost(currency: NSNull()),
            ["object": "organization.costs.result", "amount": ["currency": "usd"]]
        ] {
            await assertFailure([validUsage, OpenAIAPIFixture.response(OpenAIAPIFixture.page([OpenAIAPIFixture.bucket([result])]))], expected: .invalidResponse)
        }
        await assertFailure([validUsage, OpenAIAPIFixture.response(OpenAIAPIFixture.page([OpenAIAPIFixture.bucket([OpenAIAPIFixture.cost(currency: "eur")])]))], expected: .unsupportedCurrency)
        await assertFailure([validUsage, OpenAIAPIFixture.response(OpenAIAPIFixture.page([OpenAIAPIFixture.bucket([OpenAIAPIFixture.cost(value: 1e308), OpenAIAPIFixture.cost(value: 1e308)])]))], expected: .invalidResponse)
    }

    func testMalformedJSONFailsAndSignedCostAdjustmentsArePreserved() async throws {
        await assertFailure([HTTPResponse(statusCode: 200, headers: [:], body: Data("{".utf8))], expected: .invalidResponse)
        let http = OpenAIAPIHTTPFixture([
            OpenAIAPIFixture.response(OpenAIAPIFixture.page()),
            OpenAIAPIFixture.response(OpenAIAPIFixture.page([OpenAIAPIFixture.bucket([OpenAIAPIFixture.cost(value: -0.25)])]))
        ])
        let report = try await OpenAIAPIUsageClient(http: http).fetchMonth(apiKey: "synthetic", now: OpenAIAPIFixture.now)
        XCTAssertEqual(report.costUSD, -0.25)
    }

    private func assertFailure(_ responses: [HTTPResponse], expected: OpenAIAPIUsageError) async {
        do {
            _ = try await OpenAIAPIUsageClient(http: OpenAIAPIHTTPFixture(responses)).fetchMonth(apiKey: "synthetic", now: OpenAIAPIFixture.now)
            XCTFail("Expected explicit report failure")
        } catch {
            XCTAssertEqual(error as? OpenAIAPIUsageError, expected)
        }
    }
}
