import Darwin
import XCTest
@testable import OpenUsage

@MainActor
final class YCodingConnectionClientTests: XCTestCase {
    func testConnectionsKeepEveryProfileAndNeverGuessAuthentication() async throws {
        let runner = StubRunner([#"{"data":[{"id":"openai","methods":[{"type":"key"},{"type":"oauth"}],"connections":[{"type":"credential","id":"cred_a","label":"Personal # / Ω","active":false,"value":{"access":"synthetic-not-a-secret"}},{"type":"credential","id":"cred_b","label":"Work","active":true},{"type":"env","name":"OPENAI_API_KEY"}]},{"id":"cursor","connections":[{"type":"credential","id":"cred_c","label":"Work","active":true}]},{"id":"unrelated","connections":[{"type":"credential","id":"cred_other","label":"Other","active":true}]}]}"#])
        let client = YCodingConnectionClient(processRunner: runner, executable: "/fixture/ycoding", locationDirectory: "/fixture/project with spaces")
        let connections = try await client.connections()

        XCTAssertEqual(connections.map(\.id), ["cred_c", "cred_a", "cred_b"])
        XCTAssertEqual(connections[1].profile, "Personal # / Ω")
        XCTAssertFalse(connections[1].active)
        XCTAssertTrue(connections.allSatisfy { $0.authentication == .unknown })
        XCTAssertEqual(runner.calls[0].executable, "/fixture/ycoding")
        XCTAssertEqual(runner.calls[0].arguments, ["api", "integration.list", "--param", "location[directory]=/fixture/project with spaces"])
        XCTAssertTrue(runner.calls[0].environment.isEmpty)
    }

    func testDuplicateProfileOrIdentityFailsClosed() async {
        for connections in [
            #"{"type":"credential","id":"a","label":"same","active":true},{"type":"credential","id":"b","label":"same","active":false}"#,
            #"{"type":"credential","id":"a","label":"first","active":true},{"type":"credential","id":"a","label":"second","active":false}"#
        ] {
            let client = YCodingConnectionClient(processRunner: StubRunner(["{\"data\":[{\"id\":\"openai\",\"connections\":[\(connections)]}]}" ]))
            do { _ = try await client.connections(); XCTFail("Expected duplicate rejection") }
            catch { XCTAssertEqual(error as? YCodingConnectionClientError, .malformedResponse) }
        }
    }

    func testExplicitNonSecretKindClassifiesBothProviderAuthTypesAndUnknown() async throws {
        for providerID in ["openai", "anthropic"] {
            let response = """
            {"data":[{"id":"\(providerID)","connections":[
              {"type":"credential","id":"account","label":"A","active":true,"kind":"oauth"},
              {"type":"credential","id":"key","label":"B","active":false,"kind":"key"},
              {"type":"credential","id":"missing","label":"C","active":false},
              {"type":"credential","id":"future","label":"D","active":false,"kind":"future-kind"}
            ]}]}
            """
            let values = try await YCodingConnectionClient(processRunner: StubRunner([response])).connections()
            XCTAssertEqual(values.map(\.authentication), [.account, .apiKey, .unknown, .unknown])
        }
    }

    func testSnapshotPreservesOmittedValuesStatusesAndUnits() async throws {
        let runner = StubRunner([#"{"data":[{"providerID":"muse","label":"Muse","profile":"Personal","status":"stale","source":"response_stream","stability":"observed","updatedAt":123456,"message":"Quota refresh failed","windows":[{"id":"window","label":"Window","unit":"percent","resetAt":456789},{"id":"weekly","label":"Weekly","unit":"percent","used":0,"periodSeconds":604800}]}]}"#])
        let snapshots = try await YCodingConnectionClient(processRunner: runner).snapshots(refresh: true)
        XCTAssertEqual(snapshots.first?.status, .stale)
        XCTAssertNil(snapshots.first?.windows[0].used)
        XCTAssertNil(snapshots.first?.windows[0].limit)
        XCTAssertEqual(snapshots.first?.windows[1].used, 0)
        XCTAssertEqual(snapshots.first?.windows[0].resetAt, 456789)
        XCTAssertEqual(runner.calls[0].arguments, ["api", "providerUsage.list", "--param", "refresh=true"])
    }

    func testProfileMatcherNeverFallsBackToAnotherAccountOrAggregates() {
        let work = connection(id: "work", profile: "Work")
        let personal = connection(id: "personal", profile: "Personal")
        let selected = snapshot(profile: "Work", used: 10)
        XCTAssertEqual(YCodingQuotaSnapshot.matching(work, connections: [work, personal], snapshots: [selected, snapshot(profile: "Personal", used: 90)]), selected)
        XCTAssertNil(YCodingQuotaSnapshot.matching(work, connections: [work, personal], snapshots: [snapshot(profile: "Personal")]))
        XCTAssertNil(YCodingQuotaSnapshot.matching(work, connections: [work, personal], snapshots: [snapshot()]))
        XCTAssertNil(YCodingQuotaSnapshot.matching(work, connections: [work], snapshots: [snapshot(profile: "Work", source: .localSession)]))
        XCTAssertNil(YCodingQuotaSnapshot.matching(work, connections: [work], snapshots: [snapshot(profile: "Work", source: .localClientRPC)]))
        XCTAssertNil(YCodingQuotaSnapshot.matching(work, connections: [work], snapshots: [snapshot(source: .responseHeaders)]))
        XCTAssertNil(YCodingQuotaSnapshot.matching(work, connections: [work], snapshots: [snapshot(source: .responseStream)]))
    }

    func testSoleProfileMatchesOnlyOneUnnamedAdapterSnapshot() {
        let work = connection(id: "work", profile: "Work")
        let adapter = snapshot()
        XCTAssertEqual(YCodingQuotaSnapshot.matching(work, connections: [work], snapshots: [adapter]), adapter)
        let inactive = YCodingConnection(integrationID: work.integrationID, id: work.id, profile: work.profile, active: false)
        XCTAssertEqual(YCodingQuotaSnapshot.matching(work, connections: [inactive], snapshots: [adapter]), adapter)
        XCTAssertNil(YCodingQuotaSnapshot.matching(work, connections: [work], snapshots: [adapter, adapter]))
        XCTAssertNil(YCodingQuotaSnapshot.matching(work, connections: [work], snapshots: [snapshot(profile: "Work"), snapshot(profile: "Work")]))
        XCTAssertNil(YCodingQuotaSnapshot.matching(work, connections: [connection(id: "replacement", profile: "Work")], snapshots: [adapter]))
    }

    func testSoleMuseResponseIsBoundByYCodingButAmbiguousSnapshotsRemainRejected() {
        let muse = YCodingConnection(integrationID: "muse", id: "muse-one", profile: "Personal", active: true)
        let quota = YCodingQuotaSnapshot(providerID: "muse", label: "Muse", profile: nil, status: .available,
                                         source: .responseStream, stability: .observed, updatedAt: 123,
                                         windows: [], message: nil)
        XCTAssertEqual(YCodingQuotaSnapshot.matching(muse, connections: [muse], snapshots: [quota]), quota)
        XCTAssertNil(YCodingQuotaSnapshot.matching(muse, connections: [muse], snapshots: [quota, quota]))
        let other = YCodingConnection(integrationID: "muse", id: "muse-two", profile: "Work", active: false)
        XCTAssertNil(YCodingQuotaSnapshot.matching(muse, connections: [muse, other], snapshots: [quota]))
    }

    func testUsagePagesAndExcludesHistoricalDefaultWithoutChangingExactProfile() async throws {
        let runner = StubRunner([
            report(rows: [row(profile: nil), row(profile: "Work # / Ω", cost: 1.25)], rowCount: 3, next: 2),
            report(rows: [row(profile: "Other", providerID: "anthropic", cost: nil)], rowCount: 3)
        ])
        let usage = try await YCodingConnectionClient(processRunner: runner).usage(
            from: Date(timeIntervalSince1970: 10), to: Date(timeIntervalSince1970: 20)
        )
        XCTAssertEqual(usage.map(\.profile), ["Work # / Ω", "Other"])
        XCTAssertEqual(usage.first?.cost, 1.25)
        XCTAssertNil(usage.last?.cost)
        XCTAssertEqual(usage.last?.costCoverage?.unpricedRequests, 1)
        XCTAssertEqual(usage.first?.tokens.cache.read, 3)
        XCTAssertEqual(usage.first?.tokens.input, 1)
        XCTAssertEqual(runner.calls.count, 2)
        XCTAssertEqual(runner.calls[0].arguments, ["api", "usage.report", "--param", "group=provider-profile-model", "--param", "from=10000", "--param", "to=20000", "--param", "offset=0", "--param", "limit=200", "--param", "sort=key", "--param", "order=asc"])
        XCTAssertTrue(runner.calls[1].arguments.contains("offset=2"))
    }

    func testUsageRejectsPaginationCyclesTruncationAndDuplicates() async {
        let cases = [
            [report(rows: [row(profile: "Work")], rowCount: 2, next: 0)],
            [report(rows: [row(profile: "Work")], rowCount: 2)],
            [report(rows: [row(profile: "Work")], rowCount: 2, next: 1), report(rows: [row(profile: "Work")], rowCount: 2)]
        ]
        for responses in cases {
            let client = YCodingConnectionClient(processRunner: StubRunner(responses))
            do {
                _ = try await client.usage(from: Date(timeIntervalSince1970: 1), to: Date(timeIntervalSince1970: 2))
                XCTFail("Expected unsafe report rejection")
            } catch {
                XCTAssertTrue([YCodingConnectionClientError.incompleteReport, .malformedResponse].contains(error as? YCodingConnectionClientError ?? .unavailable))
            }
        }
    }

    func testModelPagesAggregatePerProfileUsingInjectedPricing() async throws {
        let runner = StubRunner([
            report(rows: [row(profile: "Work", model: "recorded", cost: 3)], rowCount: 4, next: 1),
            report(rows: [row(profile: "Work", cost: nil, write: 0, cacheReported: true),
                          row(profile: "Personal", cost: 8),
                          row(profile: "Work", providerID: "anthropic", cost: 9)], rowCount: 4)
        ])
        let pricing = ModelPricing(supplement: .init(), primary: .init(entries: ["fixture-model":
            .init(inputPerMillion: 2, outputPerMillion: 10, cacheWritePerMillion: 2.5, cacheReadPerMillion: 0.2)]), secondary: .init())
        let result = try await YCodingConnectionClient(processRunner: runner, pricing: { pricing }).usage(
            from: Date(timeIntervalSince1970: 1), to: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(try XCTUnwrap(result[0].cost), 3.0000226, accuracy: 1e-12)
        XCTAssertTrue(result[0].usesOpenUsagePricing)
        XCTAssertFalse(result[0].hasIncompleteCost)
        XCTAssertEqual(result[0].physical, 2)
        XCTAssertEqual(result[1].cost, 8)
        XCTAssertEqual(result[2].cost, 9)
    }

    func testInvalidRangeDoesNotStartProcess() async {
        let runner = StubRunner([])
        let client = YCodingConnectionClient(processRunner: runner)
        do { _ = try await client.usage(from: Date(timeIntervalSince1970: 2), to: Date(timeIntervalSince1970: 1)); XCTFail("Expected invalid range") }
        catch { XCTAssertEqual(error as? YCodingConnectionClientError, .invalidRange) }
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testFailuresDoNotSurfaceProcessOrDecoderPayloads() async {
        let marker = "fixture-value-must-not-be-returned"
        let runners = [
            StubRunner(results: [.init(exitCode: 1, stdout: marker, stderr: marker)]),
            StubRunner(["{\"data\":\"\(marker)\"}"])
        ]
        for runner in runners {
            do { _ = try await YCodingConnectionClient(processRunner: runner).connections(); XCTFail("Expected safe error") }
            catch { XCTAssertFalse(error.localizedDescription.contains(marker)) }
        }
    }

    func testFinderExecutableDiscoveryDoesNotUseShell() {
        let home = URL(fileURLWithPath: "/fixture/home")
        XCTAssertEqual(YCodingConnectionClient.defaultExecutable(homeDirectory: home, isExecutable: { $0 == "/fixture/home/.local/bin/ycoding" }), "/fixture/home/.local/bin/ycoding")
        XCTAssertEqual(YCodingConnectionClient.defaultExecutable(homeDirectory: home, isExecutable: { _ in false }), "ycoding")
    }

    func testRealProcessBoundaryWithSyntheticCLI() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("fixture ycoding")
        try """
        #!/bin/sh
        test "$1" = api && test "$2" = integration.list || exit 1
        printf '%s\\n' '{"data":[{"id":"cursor","connections":[{"type":"credential","id":"fixture-cursor","label":"Fixture Profile","active":false}]}]}'
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let connections = try await YCodingConnectionClient(executable: binary.path).connections()
        XCTAssertEqual(connections, [.init(integrationID: "cursor", id: "fixture-cursor", profile: "Fixture Profile", active: false)])
    }

    func testServiceAutoDiscoveryQueriesLocalServerWithBasicAuthAndFallsBackToCLIOnTransportFailure() async throws {
        let files = FakeFiles([
            "/fixture/state/ycoding/service.json": #"{"url":"http://127.0.0.1:42188","password":"synthetic-password","pid":\#(getpid())}"#
        ])
        let responseBody = Data(#"{"data":[{"id":"openai","connections":[{"type":"credential","id":"cred_a","label":"Work","active":true}]}]}"#.utf8)
        let stubHTTP = StubHTTPClient([.success(HTTPResponse(statusCode: 200, headers: [:], body: responseBody))])
        let runner = StubRunner([])
        let client = YCodingConnectionClient(
            processRunner: runner,
            http: stubHTTP,
            files: files,
            locationDirectory: "/fixture/home",
            serviceFilePath: "/fixture/state/ycoding/service.json"
        )
        let connections = try await client.connections()

        XCTAssertEqual(connections.map(\.id), ["cred_a"])
        XCTAssertEqual(stubHTTP.calls.count, 1)
        let call = stubHTTP.calls[0]
        XCTAssertEqual(call.url.path, "/api/integration")
        XCTAssertEqual(
            URLComponents(url: call.url, resolvingAgainstBaseURL: false)?.queryItems,
            [URLQueryItem(name: "location[directory]", value: "/fixture/home")]
        )
        XCTAssertEqual(call.headers["Authorization"], "Basic " + Data("ycoding:synthetic-password".utf8).base64EncodedString())
        XCTAssertTrue(runner.calls.isEmpty)

        let transportFailHTTP = StubHTTPClient([.failure(URLError(.cannotConnectToHost))])
        let fallbackRunner = StubRunner([#"{"data":[{"id":"openai","connections":[{"type":"credential","id":"cred_fallback","label":"Work","active":true}]}]}"#])
        let fallbackClient = YCodingConnectionClient(
            processRunner: fallbackRunner,
            http: transportFailHTTP,
            files: files,
            locationDirectory: "/fixture/home",
            serviceFilePath: "/fixture/state/ycoding/service.json"
        )
        let fallbackConnections = try await fallbackClient.connections()
        XCTAssertEqual(fallbackConnections.map(\.id), ["cred_fallback"])
        XCTAssertEqual(fallbackRunner.calls.count, 1)

        let deadPidFiles = FakeFiles([
            "/fixture/state/ycoding/service.json": #"{"url":"http://127.0.0.1:42188","password":"synthetic-password","pid":\#(Int32.max)}"#
        ])
        let deadPidRunner = StubRunner([#"{"data":[{"id":"openai","connections":[{"type":"credential","id":"cred_dead_pid","label":"Work","active":true}]}]}"#])
        let deadPidHTTP = StubHTTPClient([])
        let deadPidClient = YCodingConnectionClient(
            processRunner: deadPidRunner,
            http: deadPidHTTP,
            files: deadPidFiles,
            locationDirectory: "/fixture/home",
            serviceFilePath: "/fixture/state/ycoding/service.json"
        )
        let deadPidConnections = try await deadPidClient.connections()
        XCTAssertEqual(deadPidConnections.map(\.id), ["cred_dead_pid"])
        XCTAssertEqual(deadPidRunner.calls.count, 1)
        XCTAssertTrue(deadPidHTTP.calls.isEmpty)
    }

    func testDailyUsagePaginatesAndValidatesDayReport() async throws {
        let page1 = #"{"data":{"group":"day","rows":[{"key":"2026-11-04","physical":1,"cost":1.25,"tokens":{"input":10,"output":20,"reasoning":5,"cache":{"read":30,"write":40}}}],"rowCount":2,"nextOffset":1}}"#
        let page2 = #"{"data":{"group":"day","rows":[{"key":"2026-11-05","physical":1,"cost":2.5,"tokens":{"input":1,"output":2,"reasoning":3,"cache":{"read":4,"write":5}}}],"rowCount":2}}"#
        let runner = StubRunner([page1, page2])
        let client = YCodingConnectionClient(processRunner: runner)
        let series = try await client.dailyUsage(
            providerID: "anthropic",
            profile: "Work",
            from: Date(timeIntervalSince1970: 10),
            to: Date(timeIntervalSince1970: 20)
        )

        XCTAssertEqual(series.daily.map(\.date), ["2026-11-05", "2026-11-04"])
        XCTAssertEqual(series.daily, [
            DailyUsageEntry(date: "2026-11-05", totalTokens: 15, costUSD: 2.5),
            DailyUsageEntry(date: "2026-11-04", totalTokens: 105, costUSD: 1.25)
        ])
        XCTAssertEqual(runner.calls.count, 2)
        XCTAssertEqual(runner.calls[0].arguments, [
            "api", "usage.report", "--param", "group=day", "--param", "providerID=anthropic",
            "--param", "profile=Work", "--param", "from=10000", "--param", "to=20000",
            "--param", "offset=0", "--param", "limit=200", "--param", "sort=key", "--param", "order=asc"
        ])
        XCTAssertTrue(runner.calls[1].arguments.contains("offset=1"))
    }

    private func connection(id: String, profile: String) -> YCodingConnection {
        .init(integrationID: "openai", id: id, profile: profile, active: true)
    }

    private func snapshot(profile: String? = nil, source: YCodingQuotaSnapshot.Source = .providerInternalAPI, used: Double = 10) -> YCodingQuotaSnapshot {
        .init(providerID: "openai", label: "Codex", profile: profile, status: .available, source: source,
              stability: .bestEffort, updatedAt: 123, windows: [.init(id: "weekly", label: "Weekly", group: nil, unit: .percent, used: used, limit: nil, remaining: nil, unlimited: nil, resetAt: nil, periodSeconds: nil)], message: nil)
    }

    private func row(profile: String?, providerID: String = "openai", model: String = "fixture-model",
                     cost: Double? = 1, write: Int = 4, cacheReported: Bool? = nil) -> String {
        let dimensions: [String: Any] = ["group": "provider-profile-model", "providerID": providerID, "modelID": model,
                                       "profileState": profile == nil ? "provider-default" : "recorded"]
            .merging(profile.map { ["profile": $0] } ?? [:]) { _, new in new }
        var value: [String: Any] = ["dimensions": dimensions, "physical": 1,
                                   "tokens": ["input": 1, "output": 2, "reasoning": 0, "cache": ["read": 3, "write": write]],
                                   "costCoverage": ["pricedRequests": cost == nil ? 0 : 1, "unpricedRequests": cost == nil ? 1 : 0]]
        if let cost { value["cost"] = cost; value["costProvenance"] = "recorded" }
        if let cacheReported { value["cacheReadReported"] = cacheReported }
        return String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
    }

    private func report(rows: [String], rowCount: Int, next: Int? = nil) -> String {
        "{\"data\":{\"group\":\"provider-profile-model\",\"rows\":[\(rows.joined(separator: ","))],\"rowCount\":\(rowCount)\(next.map { ",\"nextOffset\":\($0)" } ?? "")}}"
    }
}

private final class StubRunner: ProcessRunning, @unchecked Sendable {
    struct Call { let executable: String; let arguments: [String]; let environment: [String: String] }
    private let lock = NSLock()
    private var results: [ProcessResult]
    private var recorded: [Call] = []
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return recorded }

    init(_ responses: [String]) { results = responses.map { .init(exitCode: 0, stdout: $0, stderr: "") } }
    init(results: [ProcessResult]) { self.results = results }

    func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> ProcessResult {
        lock.lock(); defer { lock.unlock() }
        recorded.append(.init(executable: executable, arguments: arguments, environment: environment))
        guard !results.isEmpty else { throw YCodingConnectionClientError.unavailable }
        return results.removeFirst()
    }
}

private final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Result<HTTPResponse, Error>]
    private var recorded: [HTTPRequest] = []
    var calls: [HTTPRequest] { lock.withLock { recorded } }

    init(_ responses: [Result<HTTPResponse, Error>] = []) {
        self.responses = responses
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try lock.withLock {
            recorded.append(request)
            guard !responses.isEmpty else {
                throw URLError(.cannotConnectToHost)
            }
            return try responses.removeFirst().get()
        }
    }
}
