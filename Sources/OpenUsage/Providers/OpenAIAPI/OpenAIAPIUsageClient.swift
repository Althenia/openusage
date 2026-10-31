import Foundation

struct OpenAIAPIMonthReport: Sendable {
    let tokens: Double
    let costUSD: Double
}

struct OpenAIAPIUsageClient: Sendable {
    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchMonth(apiKey: String, now: Date) async throws -> OpenAIAPIMonthReport {
        let range = try OpenAIAPIReportRange(now: now)
        let tokens = try await total(
            path: "usage/completions", apiKey: apiKey, range: range,
            result: OpenAIAPICompletionResult.self
        ) { try $0.tokenCount() }
        let cost = try await total(
            path: "costs", apiKey: apiKey, range: range,
            result: OpenAIAPICostResult.self
        ) { try $0.dollars() }
        return OpenAIAPIMonthReport(tokens: tokens, costUSD: cost)
    }

    private func total<Result: Decodable & Sendable>(
        path: String,
        apiKey: String,
        range: OpenAIAPIReportRange,
        result: Result.Type,
        value: (Result) throws -> Double
    ) async throws -> Double {
        var cursor: String?
        var cursors = Set<String>()
        var intervals: [Range<Int>] = []
        var sum = 0.0

        repeat {
            try Task.checkCancellation()
            var components = URLComponents(string: "https://api.openai.com/v1/organization/\(path)")!
            components.queryItems = [
                URLQueryItem(name: "start_time", value: String(range.start)),
                URLQueryItem(name: "end_time", value: String(range.end)),
                URLQueryItem(name: "bucket_width", value: "1d"),
                URLQueryItem(name: "limit", value: "31")
            ]
            if let cursor {
                components.queryItems?.append(URLQueryItem(name: "page", value: cursor))
            }
            guard let url = components.url else { throw OpenAIAPIUsageError.invalidResponse }
            let response: HTTPResponse
            do {
                response = try await http.send(HTTPRequest(
                    method: "GET", url: url,
                    headers: ["Authorization": "Bearer \(apiKey)", "Accept": "application/json"],
                    timeout: 15
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw OpenAIAPIUsageError.connectionFailed
            }
            switch response.statusCode {
            case 200..<300: break
            case 401: throw OpenAIAPIUsageError.invalidKey
            case 403: throw OpenAIAPIUsageError.permissionDenied
            case 404, 405: throw OpenAIAPIUsageError.unsupported
            default: throw OpenAIAPIUsageError.requestFailed(response.statusCode)
            }

            let page: OpenAIAPIReportPage<Result>
            do {
                page = try JSONDecoder().decode(OpenAIAPIReportPage<Result>.self, from: response.body)
            } catch {
                throw OpenAIAPIUsageError.invalidResponse
            }
            guard page.object == "page" else { throw OpenAIAPIUsageError.invalidResponse }
            for bucket in page.data {
                guard bucket.object == "bucket",
                      bucket.start_time >= range.start, bucket.start_time < range.end,
                      bucket.end_time > bucket.start_time,
                      bucket.end_time <= range.lastBucketEnd,
                      bucket.end_time - bucket.start_time <= 86_400
                else { throw OpenAIAPIUsageError.invalidResponse }
                let interval = bucket.start_time..<bucket.end_time
                guard !intervals.contains(where: { $0.overlaps(interval) }) else {
                    throw OpenAIAPIUsageError.invalidResponse
                }
                intervals.append(interval)
                for item in bucket.results {
                    sum += try value(item)
                    guard sum.isFinite else { throw OpenAIAPIUsageError.invalidResponse }
                    if path == "usage/completions", sum > 9_007_199_254_740_991 {
                        throw OpenAIAPIUsageError.invalidResponse
                    }
                }
            }

            if page.has_more {
                guard !page.data.isEmpty,
                      let next = page.next_page, !next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      cursors.insert(next).inserted
                else { throw OpenAIAPIUsageError.invalidResponse }
                cursor = next
            } else {
                guard page.next_page == nil else { throw OpenAIAPIUsageError.invalidResponse }
                cursor = nil
            }
        } while cursor != nil
        return sum
    }
}

private struct OpenAIAPIReportRange: Sendable {
    let start: Int
    let end: Int
    let lastBucketEnd: Int

    init(now: Date) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard now.timeIntervalSince1970.isFinite,
              let month = calendar.dateInterval(of: .month, for: now),
              let day = calendar.dateInterval(of: .day, for: now),
              now.timeIntervalSince1970 > 0,
              now.timeIntervalSince1970 < Double(Int.max)
        else { throw OpenAIAPIUsageError.invalidResponse }
        start = Int(month.start.timeIntervalSince1970)
        end = Int(now.timeIntervalSince1970)
        lastBucketEnd = Int(day.end.timeIntervalSince1970)
    }
}

private struct OpenAIAPIReportPage<Result: Decodable & Sendable>: Decodable, Sendable {
    let object: String
    let data: [OpenAIAPIReportBucket<Result>]
    let has_more: Bool
    let next_page: String?

    private enum CodingKeys: String, CodingKey {
        case object, data, has_more, next_page
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        object = try container.decode(String.self, forKey: .object)
        data = try container.decode([OpenAIAPIReportBucket<Result>].self, forKey: .data)
        has_more = try container.decode(Bool.self, forKey: .has_more)
        guard container.contains(.next_page) else { throw OpenAIAPIUsageError.invalidResponse }
        next_page = try container.decodeIfPresent(String.self, forKey: .next_page)
    }
}

private struct OpenAIAPIReportBucket<Result: Decodable & Sendable>: Decodable, Sendable {
    let object: String
    let start_time: Int
    let end_time: Int
    let results: [Result]
}

private struct OpenAIAPICompletionResult: Decodable, Sendable {
    let object: String
    let input_tokens: Int
    let output_tokens: Int
    let num_model_requests: Int
    let input_cached_tokens: Int?

    func tokenCount() throws -> Double {
        guard object == "organization.usage.completions.result",
              input_tokens >= 0, output_tokens >= 0, num_model_requests >= 0,
              input_cached_tokens.map({ $0 >= 0 && $0 <= input_tokens }) ?? true
        else { throw OpenAIAPIUsageError.invalidResponse }
        let (tokens, overflow) = input_tokens.addingReportingOverflow(output_tokens)
        guard !overflow, tokens <= 9_007_199_254_740_991 else { throw OpenAIAPIUsageError.invalidResponse }
        return Double(tokens)
    }
}

private struct OpenAIAPICostResult: Decodable, Sendable {
    let object: String
    let amount: Amount

    struct Amount: Decodable, Sendable {
        let value: Double
        let currency: String
    }

    func dollars() throws -> Double {
        guard object == "organization.costs.result", amount.value.isFinite else {
            throw OpenAIAPIUsageError.invalidResponse
        }
        guard amount.currency == "usd" else { throw OpenAIAPIUsageError.unsupportedCurrency }
        return amount.value
    }
}
