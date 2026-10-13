import Foundation

struct MuseUsageClient: Sendable {
    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchUsage(credentials: MuseCredentials) async throws -> HTTPResponse {
        let url = credentials.apiBaseURL.appendingPathComponent("responses")
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "muse-spark-1.2",
            "input": "hi",
            "max_output_tokens": 16,
            "stream": true,
            "store": false,
            "reasoning": ["effort": "minimal"]
        ])
        return try await http.send(HTTPRequest(
            method: "POST",
            url: url,
            headers: [
                "Authorization": "Bearer \(credentials.apiKey)",
                "x-client-id": "tbh:exec",
                "Content-Type": "application/json"
            ],
            body: body,
            timeout: 30
        ))
    }
}

enum MuseUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case requestFailed(Int)
    case unauthorized
    case usageUnavailable

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        case .requestFailed(let status):
            return ProviderUsageErrorText.requestFailed(statusCode: status)
        case .unauthorized:
            return "Run muse login and try again."
        case .usageUnavailable:
            return "Muse subscription usage is unavailable."
        }
    }
}
