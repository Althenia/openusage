import Foundation
import XCTest
@testable import OpenUsage

enum OpenAIAPIFixture {
    static let now = Date(timeIntervalSince1970: 1_741_003_200)
    static let monthStart = 1_740_787_200
    static let day = 86_400

    static func auth(key: String? = "synthetic-admin") -> OpenAIAPIAuthStore {
        OpenAIAPIAuthStore(
            files: FakeFiles(),
            environment: FakeEnvironment(key.map { ["OPENAI_ADMIN_KEY": $0] } ?? [:])
        )
    }

    static func completion(input: Any = 100, output: Any = 25, cached: Any = 60) -> [String: Any] {
        [
            "object": "organization.usage.completions.result",
            "input_tokens": input, "output_tokens": output,
            "input_cached_tokens": cached, "num_model_requests": 2
        ]
    }

    static func cost(value: Any = 1.25, currency: Any = "usd") -> [String: Any] {
        ["object": "organization.costs.result", "amount": ["value": value, "currency": currency]]
    }

    static func bucket(_ results: [[String: Any]], start: Int = monthStart) -> [String: Any] {
        ["object": "bucket", "start_time": start, "end_time": start + day, "results": results]
    }

    static func page(_ buckets: [[String: Any]] = [], more: Bool = false, next: Any = NSNull()) -> [String: Any] {
        ["object": "page", "data": buckets, "has_more": more, "next_page": next]
    }

    static func response(_ object: [String: Any], status: Int = 200) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: [:], body: try! JSONSerialization.data(withJSONObject: object))
    }

    static func number(_ snapshot: ProviderSnapshot, label: String, kind: MetricKind) -> Double? {
        guard case .values(_, let values, _, _, _, _) = snapshot.line(label: label) else { return nil }
        return values.first { $0.kind == kind }?.number
    }
}

actor OpenAIAPIHTTPFixture: HTTPClient {
    private var requests: [HTTPRequest] = []
    private var responses: [HTTPResponse]

    init(_ responses: [HTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return responses.removeFirst()
    }

    func recordedRequests() -> [HTTPRequest] { requests }
}

struct OpenAIAPIThrowingHTTP: HTTPClient {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw URLError(.notConnectedToInternet)
    }
}
