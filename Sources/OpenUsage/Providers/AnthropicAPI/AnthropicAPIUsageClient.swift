import Foundation

struct AnthropicAPIReport: Sendable {
    let value: Double
    let dataRefreshedAt: Date
}

struct AnthropicAPIUsageClient: Sendable {
    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchUsage(apiKey: String, startingAt: Date, endingAt: Date) async throws -> AnthropicAPIReport {
        try await fetch(
            AnthropicAPIUsageRow.self, path: "usage", apiKey: apiKey,
            startingAt: startingAt, endingAt: endingAt, divisor: 1,
            filters: [URLQueryItem(name: "products[]", value: "messages_api")]
        )
    }

    func fetchCost(apiKey: String, startingAt: Date, endingAt: Date) async throws -> AnthropicAPIReport {
        try await fetch(
            AnthropicAPICostRow.self, path: "cost", apiKey: apiKey,
            startingAt: startingAt, endingAt: endingAt, divisor: 100, filters: []
        )
    }

    private func fetch<Row: AnthropicAPIReportRow>(
        _ row: Row.Type, path: String, apiKey: String,
        startingAt: Date, endingAt: Date, divisor: Decimal, filters: [URLQueryItem]
    ) async throws -> AnthropicAPIReport {
        do {
            return try await fetchPages(
                row, path: path, apiKey: apiKey, startingAt: startingAt,
                endingAt: endingAt, divisor: divisor, filters: filters
            )
        } catch AnthropicAPIError.paginationExpired {
            return try await fetchPages(
                row, path: path, apiKey: apiKey, startingAt: startingAt,
                endingAt: endingAt, divisor: divisor, filters: filters
            )
        }
    }

    private func fetchPages<Row: AnthropicAPIReportRow>(
        _ row: Row.Type, path: String, apiKey: String,
        startingAt: Date, endingAt: Date, divisor: Decimal, filters: [URLQueryItem]
    ) async throws -> AnthropicAPIReport {
        var total: Decimal = 0
        var cursor: String?
        var cursors = Set<String>()
        var bucketStarts = Set<Date>()
        var watermark: Date?

        repeat {
            try Task.checkCancellation()
            var components = URLComponents(string: "https://api.anthropic.com/v1/organizations/analytics/\(path)")
            var query = [
                URLQueryItem(name: "starting_at", value: OpenUsageISO8601.string(from: startingAt)),
                URLQueryItem(name: "ending_at", value: OpenUsageISO8601.string(from: endingAt)),
                URLQueryItem(name: "time_bucket_width", value: "1h"),
                URLQueryItem(name: "limit", value: "1000")
            ] + filters
            if let cursor { query.append(URLQueryItem(name: "page", value: cursor)) }
            components?.queryItems = query
            guard let url = components?.url else { throw AnthropicAPIError.invalidResponse }

            let response: HTTPResponse
            do {
                response = try await http.send(HTTPRequest(
                    method: "GET", url: url,
                    headers: [
                        "x-api-key": apiKey,
                        "anthropic-version": "2023-06-01",
                        "anthropic-beta": "analytics-usage-cost-2026-08-24",
                        "Accept": "application/json"
                    ]
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AnthropicAPIError.connectionFailed
            }
            switch response.statusCode {
            case 200..<300: break
            case 401: throw AnthropicAPIError.invalidKey
            case 403: throw AnthropicAPIError.permissionDenied
            case 404, 405, 501: throw AnthropicAPIError.unsupported
            case 410: throw AnthropicAPIError.paginationExpired
            default: throw AnthropicAPIError.requestFailed(response.statusCode)
            }

            let page: AnthropicAPIPage<Row>
            do {
                page = try JSONDecoder().decode(AnthropicAPIPage<Row>.self, from: response.body)
            } catch {
                throw AnthropicAPIError.invalidResponse
            }
            guard let rawWatermark = page.dataRefreshedAt else { throw AnthropicAPIError.missingData }
            guard let refreshed = OpenUsageISO8601.date(from: rawWatermark) else {
                throw AnthropicAPIError.invalidResponse
            }
            guard refreshed > startingAt else { throw AnthropicAPIError.missingData }
            if let watermark, watermark != refreshed { throw AnthropicAPIError.invalidResponse }
            watermark = refreshed

            for item in page.data {
                guard let start = OpenUsageISO8601.date(from: item.startingAt),
                      let end = OpenUsageISO8601.date(from: item.endingAt),
                      start >= startingAt, end <= endingAt,
                      start.timeIntervalSince1970.truncatingRemainder(dividingBy: 3600) == 0,
                      end.timeIntervalSince(start) == 3600,
                      bucketStarts.insert(start).inserted else {
                    throw AnthropicAPIError.invalidResponse
                }
                total += try item.amount()
                guard !total.isNaN else { throw AnthropicAPIError.invalidResponse }
            }
            if page.hasMore {
                guard !page.data.isEmpty, let next = page.nextPage, !next.isEmpty,
                      cursors.insert(next).inserted else { throw AnthropicAPIError.invalidResponse }
                cursor = next
            } else {
                guard page.nextPage == nil else { throw AnthropicAPIError.invalidResponse }
                cursor = nil
            }
        } while cursor != nil

        guard let watermark else { throw AnthropicAPIError.missingData }
        let value = NSDecimalNumber(decimal: total / divisor).doubleValue
        guard value.isFinite else { throw AnthropicAPIError.invalidResponse }
        return AnthropicAPIReport(value: value, dataRefreshedAt: watermark)
    }
}

private struct AnthropicAPIPage<Row: Decodable>: Decodable {
    let data: [Row]
    let hasMore: Bool
    let nextPage: String?
    let dataRefreshedAt: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
        case dataRefreshedAt = "data_refreshed_at"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.nextPage), container.contains(.dataRefreshedAt) else {
            throw AnthropicAPIError.invalidResponse
        }
        data = try container.decode([Row].self, forKey: .data)
        hasMore = try container.decode(Bool.self, forKey: .hasMore)
        nextPage = try container.decodeIfPresent(String.self, forKey: .nextPage)
        dataRefreshedAt = try container.decodeIfPresent(String.self, forKey: .dataRefreshedAt)
    }
}

private protocol AnthropicAPIReportRow: Decodable {
    var startingAt: String { get }
    var endingAt: String { get }
    func amount() throws -> Decimal
}

private struct AnthropicAPIUsageRow: AnthropicAPIReportRow {
    let startingAt: String
    let endingAt: String
    let usage: Usage

    struct Usage: Decodable {
        let totalTokens: UInt64
        enum CodingKeys: String, CodingKey { case totalTokens = "total_tokens" }
    }

    enum CodingKeys: String, CodingKey {
        case startingAt = "starting_at"
        case endingAt = "ending_at"
        case usage
    }

    func amount() throws -> Decimal { Decimal(usage.totalTokens) }
}

private struct AnthropicAPICostRow: AnthropicAPIReportRow {
    let startingAt: String
    let endingAt: String
    let cost: Cost

    struct Cost: Decodable {
        let amount: String
        let currency: String
    }

    enum CodingKeys: String, CodingKey {
        case startingAt = "starting_at"
        case endingAt = "ending_at"
        case cost
    }

    func amount() throws -> Decimal {
        guard cost.currency == "USD" else { throw AnthropicAPIError.unsupportedCurrency }
        guard cost.amount.range(of: #"^-?[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let amount = Decimal(string: cost.amount, locale: Locale(identifier: "en_US_POSIX")),
              !amount.isNaN else { throw AnthropicAPIError.invalidResponse }
        return amount
    }
}
