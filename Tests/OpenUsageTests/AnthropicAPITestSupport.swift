import Foundation
@testable import OpenUsage

enum AnthropicAPIFixture {
    static let start = date("2026-10-01T00:00:00Z")
    static let end = date("2026-10-31T18:00:00Z")
    static let now = date("2026-10-31T18:43:12Z")
    static let watermark = "2026-10-31T18:00:00Z"

    static func date(_ value: String) -> Date {
        OpenUsageISO8601.date(from: value)!
    }

    static func response(_ object: [String: Any], status: Int = 200) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: [:], body: try! JSONSerialization.data(withJSONObject: object))
    }

    static func page(
        _ rows: [[String: Any]] = [],
        more: Bool = false,
        next: String? = nil,
        watermark: String? = AnthropicAPIFixture.watermark
    ) -> HTTPResponse {
        response([
            "data": rows,
            "has_more": more,
            "next_page": next as Any? ?? NSNull(),
            "data_refreshed_at": watermark as Any? ?? NSNull()
        ])
    }

    static func usage(_ tokens: Any = 150, hour: Int = 0) -> [String: Any] {
        [
            "starting_at": String(format: "2026-10-01T%02d:00:00Z", hour),
            "ending_at": String(format: "2026-10-01T%02d:00:00Z", hour + 1),
            "group": [:],
            "usage": [
                "uncached_input_tokens": 50,
                "output_tokens": 40,
                "cache_read_input_tokens": 30,
                "cache_creation": ["ephemeral_1h_input_tokens": 10, "ephemeral_5m_input_tokens": 20],
                "total_tokens": tokens
            ]
        ]
    }

    static func cost(_ amount: Any = "123.78912", currency: String = "USD", hour: Int = 0) -> [String: Any] {
        [
            "starting_at": String(format: "2026-10-01T%02d:00:00Z", hour),
            "ending_at": String(format: "2026-10-01T%02d:00:00Z", hour + 1),
            "group": [:],
            "cost": ["amount": amount, "list_amount": "99999.000000", "currency": currency]
        ]
    }

    static func auth(_ key: String? = "synthetic-admin-key") -> AnthropicAPIAuthStore {
        AnthropicAPIAuthStore(
            files: FakeFiles(),
            environment: FakeEnvironment(key.map { ["ANTHROPIC_ADMIN_API_KEY": $0] } ?? [:])
        )
    }

    static func query(_ request: HTTPRequest) -> [String: String] {
        Dictionary(uniqueKeysWithValues: URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
            .queryItems!.map { ($0.name, $0.value ?? "") })
    }
}

actor AnthropicAPIHTTP: HTTPClient {
    private var responses: [HTTPResponse]
    private(set) var requests: [HTTPRequest] = []

    init(_ responses: [HTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.cannotConnectToHost) }
        return responses.removeFirst()
    }
}
