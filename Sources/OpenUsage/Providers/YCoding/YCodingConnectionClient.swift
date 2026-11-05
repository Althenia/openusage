import Darwin
import Foundation

protocol YCodingConnectionReading: Sendable {
    func connections() async throws -> [YCodingConnection]
    func snapshots(refresh: Bool) async throws -> [YCodingQuotaSnapshot]
    func usage(from: Date, to: Date) async throws -> [YCodingProfileUsage]
    func dailyUsage(providerID: String, profile: String, from: Date, to: Date) async throws -> DailyUsageSeries
}

extension YCodingConnectionReading {
    func dailyUsage(providerID: String, profile: String, from: Date, to: Date) async throws -> DailyUsageSeries {
        DailyUsageSeries(daily: [])
    }
}

enum YCodingConnectionClientError: Error, LocalizedError, Equatable {
    case unavailable, requestFailed, malformedResponse, responseTooLarge, invalidRange, incompleteReport

    var errorDescription: String? {
        switch self {
        case .unavailable: "YCoding could not be started. Check that its CLI is installed."
        case .requestFailed: "YCoding could not provide connection usage. Open YCoding and try again."
        case .malformedResponse: "YCoding returned incompatible connection usage. Update YCoding and try again."
        case .responseTooLarge: "YCoding's usage response is too large to read safely."
        case .invalidRange: "The YCoding usage time range is invalid."
        case .incompleteReport: "YCoding could not provide a complete profile usage report."
        }
    }
}

/// Reads only the supported local CLI's non-secret API results. YCoding owns service authorization,
/// credential refresh, and provider requests; this client never reads its auth files or database.
/// `ycoding api` may start the managed service. `refresh: false` still allows cache-miss/expired
/// provider reads; it is not a promise to avoid provider requests. The public API has no cached-only
/// option. Ordinary OpenAI keys and Anthropic keys can have no quota even when local usage exists.
struct YCodingConnectionClient: YCodingConnectionReading {
    private let processRunner: any ProcessRunning
    private let http: any HTTPClient
    private let files: any TextFileAccessing
    private let executable: String
    private let environment: [String: String]
    private let locationDirectory: String?
    private let serviceFilePath: String?
    private let timeout: TimeInterval
    private let pricing: @Sendable () async -> ModelPricing

    init(
        processRunner: any ProcessRunning = SystemProcessRunner(),
        http: any HTTPClient = URLSessionHTTPClient(),
        files: any TextFileAccessing = LocalTextFileAccessor(),
        executable: String? = nil,
        environment: [String: String] = [:],
        locationDirectory: String? = nil,
        serviceFilePath: String? = nil,
        timeout: TimeInterval = 30,
        pricing: @escaping @Sendable () async -> ModelPricing = { await ModelPricingStore.shared.current() }
    ) {
        self.processRunner = processRunner
        self.http = http
        self.files = files
        self.executable = executable ?? Self.defaultExecutable()
        self.environment = environment
        self.locationDirectory = locationDirectory
        self.serviceFilePath = serviceFilePath
        self.timeout = timeout
        self.pricing = pricing
    }

    static func defaultExecutable(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String {
        // Finder's PATH does not normally include the YCoding install directory. Resolve a known
        // binary directly without sourcing shell profiles or evaluating a command string.
        let paths = [homeDirectory.appendingPathComponent(".local/bin/ycoding").path,
                     "/opt/homebrew/bin/ycoding", "/usr/local/bin/ycoding"]
        return paths.first(where: isExecutable) ?? "ycoding"
    }

    func connections() async throws -> [YCodingConnection] {
        let response: Envelope<[Integration]> = try await request("integration.list", locationScoped: true)
        var connections: [YCodingConnection] = []
        var identities = Set<String>()
        var profiles = Set<[String]>()
        for integration in response.data where YCodingConnection.supportedIntegrations.contains(integration.id) {
            for connection in integration.connections where connection.type == "credential" {
                guard let id = connection.id, !id.isEmpty,
                      let profile = connection.label, !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let active = connection.active,
                      identities.insert(id).inserted,
                      profiles.insert([integration.id, profile]).inserted else {
                    throw failure(.malformedResponse)
                }
                connections.append(.init(integrationID: integration.id, id: id, profile: profile, active: active,
                    authentication: connection.kind.flatMap(YCodingConnection.Authentication.init(rawValue:)) ?? .unknown))
            }
        }
        return connections.sorted { ($0.integrationID, $0.profile, $0.id) < ($1.integrationID, $1.profile, $1.id) }
    }

    func snapshots(refresh: Bool = false) async throws -> [YCodingQuotaSnapshot] {
        let response: Envelope<[YCodingQuotaSnapshot]> = try await request(
            "providerUsage.list", parameters: ["refresh=\(refresh)"], locationScoped: true
        )
        let snapshots = response.data.filter { YCodingConnection.supportedIntegrations.contains($0.providerID) }
        guard snapshots.allSatisfy({ snapshot in
            !snapshot.label.isEmpty && snapshot.profile?.isEmpty != true &&
            snapshot.updatedAt.isFinite && snapshot.updatedAt >= 0 &&
            Set(snapshot.windows.map(\.id)).count == snapshot.windows.count &&
            snapshot.windows.allSatisfy { window in
                !window.id.isEmpty && !window.label.isEmpty &&
                [window.used, window.limit, window.remaining, window.resetAt, window.periodSeconds]
                    .compactMap { $0 }.allSatisfy { $0.isFinite && $0 >= 0 }
            }
        }) else { throw failure(.malformedResponse) }
        return snapshots
    }

    func usage(from: Date, to: Date) async throws -> [YCodingProfileUsage] {
        let start = from.timeIntervalSince1970 * 1000
        let end = to.timeIntervalSince1970 * 1000
        guard start.isFinite, end.isFinite, start >= 0, start < end,
              end < Double(Int64.max) else { throw failure(.invalidRange) }
        var result: [YCodingModelUsage] = []
        var offset = 0
        var identities = Set<[String]>()
        // The API caps pages at 200 rows. An explicit bound rejects an incomplete or cycling report
        // instead of silently displaying a partial subtotal as complete usage.
        for _ in 0..<100 {
            let response: Envelope<UsageReport> = try await request("usage.report", parameters: [
                "group=provider-profile-model", "from=\(Int64(start))", "to=\(Int64(end))", "offset=\(offset)",
                "limit=200", "sort=key", "order=asc"
            ])
            let report = response.data
            guard report.group == "provider-profile-model", report.rowCount >= 0, report.rows.count <= 200 else {
                throw failure(.malformedResponse)
            }
            for row in report.rows {
                guard let dimensions = row.dimensions, dimensions.group == "provider-profile-model",
                      ["recorded", "provider-default"].contains(dimensions.profileState),
                      (dimensions.profileState == "recorded") == (dimensions.profile != nil) else {
                    throw failure(.malformedResponse)
                }
                guard YCodingConnection.supportedIntegrations.contains(dimensions.providerID),
                      dimensions.profileState == "recorded", let profile = dimensions.profile else { continue }
                guard !profile.isEmpty, identities.insert([dimensions.providerID, profile, dimensions.modelID ?? ""]).inserted,
                      row.physical >= 0, row.cost?.isFinite != false,
                      (row.cost == nil) == (row.costProvenance == nil),
                      row.costProvenance.map({ ["recorded", "current_catalog"].contains($0) }) != false,
                      [row.tokens.input, row.tokens.output, row.tokens.reasoning,
                       row.tokens.cache.read, row.tokens.cache.write].allSatisfy(\.isFinite),
                      row.costCoverage.map({ $0.pricedRequests >= 0 && $0.unpricedRequests >= 0 }) != false else {
                    throw failure(.malformedResponse)
                }
                let usage = YCodingProfileUsage(providerID: dimensions.providerID, profile: profile, cost: row.cost,
                                    costProvenance: row.costProvenance, costCoverage: row.costCoverage,
                                    tokens: row.tokens, physical: row.physical)
                result.append(.init(modelID: dimensions.modelID, cacheReadReported: row.cacheReadReported, usage: usage))
            }
            guard let next = report.nextOffset else {
                guard offset + report.rows.count == report.rowCount else { throw failure(.incompleteReport) }
                let rates = YCodingUsagePricing.needsPricing(result) ? await pricing() : .empty
                do { return try YCodingUsagePricing.aggregate(result, pricing: rates) }
                catch { throw failure(.malformedResponse) }
            }
            guard next == offset + report.rows.count, next > offset, next < report.rowCount else {
                throw failure(.incompleteReport)
            }
            offset = next
        }
        throw failure(.incompleteReport)
    }

    func dailyUsage(providerID: String, profile: String, from: Date, to: Date) async throws -> DailyUsageSeries {
        guard YCodingConnection.supportedIntegrations.contains(providerID), !profile.isEmpty else {
            throw failure(.malformedResponse)
        }
        let start = from.timeIntervalSince1970 * 1000
        let end = to.timeIntervalSince1970 * 1000
        guard start.isFinite, end.isFinite, start >= 0, start < end,
              end < Double(Int64.max) else { throw failure(.invalidRange) }

        var entries: [DailyUsageEntry] = []
        var offset = 0
        var seenDays = Set<String>()

        for _ in 0..<100 {
            let response: Envelope<UsageReport> = try await request("usage.report", parameters: [
                "group=day", "providerID=\(providerID)", "profile=\(profile)",
                "from=\(Int64(start))", "to=\(Int64(end))", "offset=\(offset)",
                "limit=200", "sort=key", "order=asc"
            ])
            let report = response.data
            guard report.group == "day", report.rowCount >= 0, report.rows.count <= 200 else {
                throw failure(.malformedResponse)
            }
            for row in report.rows {
                guard let key = row.key,
                      key.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
                      seenDays.insert(key).inserted,
                      row.physical >= 0,
                      row.cost?.isFinite != false,
                      [row.tokens.input, row.tokens.output, row.tokens.reasoning,
                       row.tokens.cache.read, row.tokens.cache.write].allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                    throw failure(.malformedResponse)
                }
                if row.physical > 0 {
                    let totalTokens = row.tokens.input + row.tokens.output + row.tokens.reasoning +
                        row.tokens.cache.read + row.tokens.cache.write
                    let clampedTokens = Int(min(max(totalTokens.rounded(), 0), 1_000_000_000_000_000))
                    entries.append(DailyUsageEntry(date: key, totalTokens: clampedTokens, costUSD: row.cost))
                }
            }
            guard let next = report.nextOffset else {
                guard offset + report.rows.count == report.rowCount else { throw failure(.incompleteReport) }
                return DailyUsageSeries(daily: entries.sorted { $0.date > $1.date })
            }
            guard next == offset + report.rows.count, next > offset, next < report.rowCount else {
                throw failure(.incompleteReport)
            }
            offset = next
        }
        throw failure(.incompleteReport)
    }

    private struct ServiceDescriptor: Decodable, Sendable {
        let url: String
        let password: String
        let pid: Int32?
    }

    private func discoverService() -> (baseURL: URL, authorization: String)? {
        guard let serviceFilePath,
              let text = try? files.readTextIfPresent(serviceFilePath),
              let data = text.data(using: .utf8),
              let service = try? JSONDecoder().decode(ServiceDescriptor.self, from: data) else {
            return nil
        }
        guard let baseURL = URL(string: service.url),
              let scheme = baseURL.scheme,
              scheme == "http" || scheme == "https",
              let host = baseURL.host,
              host == "127.0.0.1" || host == "localhost",
              baseURL.port != nil,
              !service.password.isEmpty else {
            return nil
        }
        if let pid = service.pid {
            errno = 0
            guard pid > 0, Darwin.kill(pid, 0) == 0 || errno == EPERM else {
                return nil
            }
        }
        let authorization = "Basic " + Data("ycoding:\(service.password)".utf8).base64EncodedString()
        return (baseURL: baseURL, authorization: authorization)
    }

    private static func httpPath(for operation: String) -> String? {
        switch operation {
        case "integration.list": "/api/integration"
        case "providerUsage.list": "/api/provider/usage"
        case "usage.report": "/api/usage/report"
        default: nil
        }
    }

    private func request<Value: Decodable & Sendable>(
        _ operation: String, parameters: [String] = [], locationScoped: Bool = false
    ) async throws -> Value {
        try Task.checkCancellation()
        if let service = discoverService(), let endpoint = Self.httpPath(for: operation) {
            var components = URLComponents(url: service.baseURL, resolvingAgainstBaseURL: false)
            components?.path = endpoint
            var queryItems: [URLQueryItem] = parameters.map { parameter in
                guard let equalIndex = parameter.firstIndex(of: "=") else {
                    return URLQueryItem(name: parameter, value: nil)
                }
                let name = String(parameter[..<equalIndex])
                let value = String(parameter[parameter.index(after: equalIndex)...])
                return URLQueryItem(name: name, value: value)
            }
            if locationScoped, let locationDirectory {
                queryItems.append(URLQueryItem(name: "location[directory]", value: locationDirectory))
            }
            if !queryItems.isEmpty {
                components?.queryItems = queryItems
            }
            if let requestURL = components?.url {
                let request = HTTPRequest(
                    method: "GET",
                    url: requestURL,
                    headers: ["Authorization": service.authorization, "Accept": "application/json"],
                    timeout: timeout
                )
                do {
                    let response = try await http.send(request)
                    try Task.checkCancellation()
                    if (200..<300).contains(response.statusCode) {
                        guard response.body.count <= 4 * 1024 * 1024 else { throw failure(.responseTooLarge) }
                        do {
                            return try JSONDecoder().decode(Value.self, from: response.body)
                        } catch {
                            throw failure(.malformedResponse)
                        }
                    }
                } catch let error as YCodingConnectionClientError {
                    throw error
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                }
            }
        }
        var arguments = ["api", operation]
        for parameter in parameters { arguments += ["--param", parameter] }
        if locationScoped, let locationDirectory {
            arguments += ["--param", "location[directory]=\(locationDirectory)"]
        }
        let runner = processRunner, executable = executable, environment = environment, timeout = timeout
        let result: ProcessResult
        do {
            result = try await Task.detached(priority: .utility) {
                try runner.run(executable: executable, arguments: arguments, environment: environment, timeout: timeout)
            }.value
        } catch {
            // Process errors, stderr, stdout, decoder paths, and payloads may contain credentials or
            // user paths. The only externally visible diagnostic is a fixed, actionable sentence.
            throw failure(.unavailable)
        }
        try Task.checkCancellation()
        guard result.succeeded else { throw failure(.requestFailed) }
        guard result.stdout.utf8.count <= 4 * 1024 * 1024 else { throw failure(.responseTooLarge) }
        do { return try JSONDecoder().decode(Value.self, from: Data(result.stdout.utf8)) }
        catch { throw failure(.malformedResponse) }
    }

    private func failure(_ error: YCodingConnectionClientError) -> YCodingConnectionClientError {
        AppLog.error("plugin:ycoding", error.localizedDescription)
        return error
    }

    private struct Envelope<Value: Decodable & Sendable>: Decodable, Sendable { let data: Value }
    private struct Integration: Decodable, Sendable { let id: String; let connections: [Connection] }
    private struct Connection: Decodable, Sendable {
        let type: String
        let id: String?
        let label: String?
        let active: Bool?
        let kind: String?
    }
    private struct UsageReport: Decodable, Sendable {
        let group: String
        let rows: [UsageRow]
        let rowCount: Int
        let nextOffset: Int?
    }
    private struct UsageRow: Decodable, Sendable {
        let key: String?
        let dimensions: Dimensions?
        let cost: Double?
        let costProvenance: String?
        let costCoverage: YCodingCostCoverage?
        let tokens: YCodingTokenUsage
        let physical: Int
        let cacheReadReported: Bool?
    }
    private struct Dimensions: Decodable, Sendable {
        let group: String
        let providerID: String
        let profile: String?
        let profileState: String
        let modelID: String?
    }
}
