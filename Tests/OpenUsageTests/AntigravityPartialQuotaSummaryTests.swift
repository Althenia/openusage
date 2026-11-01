import XCTest
@testable import OpenUsage

/// Covers handling of partial quota summaries from the Antigravity backend, where the quota-summary
/// RPC returns groups for third-party models (`3p-5h`, `3p-weekly`) but omits the Gemini groups.
///
/// Ensures:
/// 1. Authoritative 3p summary lines are strictly preserved.
/// 2. Missing Gemini 5h session pool is supplemented from live model configurations.
/// 3. Weekly limits are not fabricated from 5h model quota (Gemini weekly truthfully remains absent).
/// 4. If GetUserStatus returns only 3p configs, the language-server probe falls back to GetCommandModelConfigs.
/// 5. If the supplemental model source fails, authoritative summary lines survive intact.
final class AntigravityPartialQuotaSummaryTests: XCTestCase {

    // MARK: - Helpers

    private func used(_ line: MetricLine?) -> Double? {
        guard case .progress(_, let used, _, _, _, _, _)? = line else { return nil }
        return used
    }

    private func resetsAt(_ line: MetricLine?) -> Date? {
        guard case .progress(_, _, _, _, let resetsAt, _, _)? = line else { return nil }
        return resetsAt
    }

    private func periodMs(_ line: MetricLine?) -> Int? {
        guard case .progress(_, _, _, _, _, let periodMs, _)? = line else { return nil }
        return periodMs
    }

    private let partial3pOnlyGroupsJSON = """
    "groups":[
      {"displayName":"Claude and GPT models","buckets":[
        {"bucketId":"3p-weekly","displayName":"Weekly Limit Remaining","window":"weekly","remainingFraction":0.05,"resetTime":"2026-11-05T05:05:07Z"},
        {"bucketId":"3p-5h","displayName":"Five Hour Limit Remaining","window":"5h","remainingFraction":0.98,"resetTime":"2026-11-01T09:42:41Z"}
      ]}
    ]
    """

    @MainActor
    private func makeCloudCodeProvider(routing: RoutingHTTPClient) -> AntigravityProvider {
        let inner = #"{"token":{"access_token":"ya29.kc","refresh_token":"1//r","expiry":"2099-01-01T00:00:00Z"}}"#
        let wrapped = "go-keyring-base64:" + Data(inner.utf8).base64EncodedString()
        return AntigravityProvider(
            authStore: AntigravityAuthStore(keychain: FakeKeychain(wrapped), files: FakeFiles()),
            usageClient: AntigravityUsageClient(lsHTTP: routing, http: routing),
            discovery: LanguageServerDiscovery(processRunner: NoProcessRunner()),
            dbUsageScanner: AntigravityDbUsageScanner(conversationsDirectories: { ["/nonexistent-antigravity-tests"] })
        )
    }

    @MainActor
    private func makeLSProvider(routing: RoutingHTTPClient) -> AntigravityProvider {
        AntigravityProvider(
            authStore: AntigravityAuthStore(keychain: FakeKeychain(nil), files: FakeFiles()),
            usageClient: AntigravityUsageClient(lsHTTP: routing, http: routing),
            discovery: LanguageServerDiscovery(processRunner: FakeLSProcessRunner()),
            dbUsageScanner: AntigravityDbUsageScanner(conversationsDirectories: { ["/nonexistent-antigravity-tests"] })
        )
    }

    // MARK: - Cloud Code partial summary

    @MainActor
    func testCloudCodeSendsAntigravityHubUserAgentAndParsesFullSummaryWithWeekly() async {
        let fullGroupsJSON = """
        "groups":[
          {"displayName":"Gemini Models","buckets":[
            {"bucketId":"gemini-weekly","displayName":"Weekly Limit Remaining","window":"weekly","remainingFraction":0.23,"resetTime":"2026-11-05T02:47:09Z"},
            {"bucketId":"gemini-5h","displayName":"Five Hour Limit Remaining","window":"5h","remainingFraction":0.78,"resetTime":"2026-11-01T09:20:37Z"}
          ]},
          {"displayName":"Claude and GPT models","buckets":[
            {"bucketId":"3p-weekly","displayName":"Weekly Limit Remaining","window":"weekly","remainingFraction":0.05,"resetTime":"2026-11-05T05:05:07Z"},
            {"bucketId":"3p-5h","displayName":"Five Hour Limit Remaining","window":"5h","remainingFraction":0.98,"resetTime":"2026-11-01T09:42:41Z"}
          ]}
        ]
        """
        let routing = RoutingHTTPClient { request in
            let path = request.url.path
            if path.contains("retrieveUserQuotaSummary") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("{\(fullGroupsJSON)}".utf8))
            }
            if path.contains("loadCodeAssist") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"paidTier":{"name":"Google AI Pro"}}"#.utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let provider = makeCloudCodeProvider(routing: routing)

        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.plan, "Pro")
        let request = routing.requests.first { $0.url.path.contains("retrieveUserQuotaSummary") }
        let userAgent = request?.headers["User-Agent"]
        XCTAssertNotNil(userAgent)
        XCTAssertTrue(userAgent?.hasPrefix("antigravity/hub/2.26.0") == true)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Claude", "Claude Weekly"])
        XCTAssertEqual(snapshot.lines.map { self.used($0) }, [22, 77, 2, 95])
        let weekly = snapshot.lines.first { $0.label == "Weekly" }
        XCTAssertEqual(self.resetsAt(weekly), OpenUsageISO8601.date(from: "2026-11-05T02:47:09Z"))
        XCTAssertEqual(self.periodMs(weekly), MetricPeriod.weekMs)
    }

    @MainActor
    func testCloudCodePartialSummarySupplementsGeminiSessionFromFetchAvailableModels() async {
        let groupsJSON = partial3pOnlyGroupsJSON
        let modelsJSON = """
        {"models":{
          "gemini-2.5-pro":{"displayName":"Gemini 2.5 Pro","quotaInfo":{"remainingFraction":0.96,"resetTime":"2026-11-01T09:20:37Z"}},
          "gemini-3-flash":{"displayName":"Gemini 3 Flash","quotaInfo":{"remainingFraction":0.99,"resetTime":"2026-11-01T09:20:37Z"}}
        }}
        """
        let routing = RoutingHTTPClient { request in
            let path = request.url.path
            if path.contains("retrieveUserQuotaSummary") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("{\(groupsJSON)}".utf8))
            }
            if path.contains("fetchAvailableModels") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(modelsJSON.utf8))
            }
            if path.contains("loadCodeAssist") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"paidTier":{"name":"Google AI Pro"}}"#.utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let provider = makeCloudCodeProvider(routing: routing)

        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.plan, "Pro")
        // Preserves 3p buckets, supplements Session from worst Gemini model (0.96 -> 4% used), leaves Weekly absent.
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Claude", "Claude Weekly"])
        XCTAssertEqual(snapshot.lines.map { self.used($0) }, [4, 2, 95])
        let session = snapshot.lines.first { $0.label == "Session" }
        XCTAssertEqual(self.resetsAt(session), OpenUsageISO8601.date(from: "2026-11-01T09:20:37Z"))
        XCTAssertEqual(self.periodMs(session), MetricPeriod.sessionMs)
    }

    @MainActor
    func testCloudCodePartialSummarySupplementalFailurePreservesAuthoritative3p() async {
        let groupsJSON = partial3pOnlyGroupsJSON
        let routing = RoutingHTTPClient { request in
            let path = request.url.path
            if path.contains("retrieveUserQuotaSummary") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("{\(groupsJSON)}".utf8))
            }
            if path.contains("fetchAvailableModels") {
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            }
            if path.contains("loadCodeAssist") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"paidTier":{"name":"Google AI Pro"}}"#.utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let provider = makeCloudCodeProvider(routing: routing)

        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Pro")
        // 3p summary lines survive even if supplemental model call failed
        XCTAssertEqual(snapshot.lines.map(\.label), ["Claude", "Claude Weekly"])
        XCTAssertEqual(snapshot.lines.map { self.used($0) }, [2, 95])
    }

    // MARK: - Language Server partial summary

    @MainActor
    func testLSPartialSummarySupplementsGeminiSessionFromGetUserStatus() async {
        let groupsJSON = partial3pOnlyGroupsJSON
        let statusJSON = """
        {"userStatus":{"userTier":{"name":"Google AI Pro"},
        "cascadeModelConfigData":{"clientModelConfigs":[
          {"label":"Gemini 2.5 Pro","quotaInfo":{"remainingFraction":0.96,"resetTime":"2026-11-01T09:20:37Z"}}
        ]}}}
        """
        let routing = RoutingHTTPClient { request in
            let path = request.url.path
            if path.hasSuffix("/RetrieveUserQuotaSummary") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("{\"response\":{\(groupsJSON)}}".utf8))
            }
            if path.hasSuffix("/GetUserStatus") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(statusJSON.utf8))
            }
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let provider = makeLSProvider(routing: routing)

        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Claude", "Claude Weekly"])
        XCTAssertEqual(snapshot.lines.map { self.used($0) }, [4, 2, 95])
        let session = snapshot.lines.first { $0.label == "Session" }
        XCTAssertEqual(self.resetsAt(session), OpenUsageISO8601.date(from: "2026-11-01T09:20:37Z"))
        XCTAssertEqual(self.periodMs(session), MetricPeriod.sessionMs)
    }

    @MainActor
    func testLSPartialSummaryWithOnly3pConfigsFallsBackToCommandModelConfigs() async {
        let groupsJSON = partial3pOnlyGroupsJSON
        // GetUserStatus has configs, but only 3p (no Gemini)
        let statusJSON = """
        {"userStatus":{"userTier":{"name":"Google AI Pro"},
        "cascadeModelConfigData":{"clientModelConfigs":[
          {"label":"Claude 3.7 Sonnet","quotaInfo":{"remainingFraction":0.95}}
        ]}}}
        """
        // GetCommandModelConfigs provides the Gemini config
        let commandConfigsJSON = """
        {"clientModelConfigs":[
          {"label":"Gemini 2.5 Pro","quotaInfo":{"remainingFraction":0.94,"resetTime":"2026-11-01T09:20:37Z"}}
        ]}
        """
        let routing = RoutingHTTPClient { request in
            let path = request.url.path
            if path.hasSuffix("/RetrieveUserQuotaSummary") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("{\"response\":{\(groupsJSON)}}".utf8))
            }
            if path.hasSuffix("/GetUserStatus") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(statusJSON.utf8))
            }
            if path.hasSuffix("/GetCommandModelConfigs") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(commandConfigsJSON.utf8))
            }
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let provider = makeLSProvider(routing: routing)

        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Claude", "Claude Weekly"])
        XCTAssertEqual(snapshot.lines.map { self.used($0) }, [6, 2, 95])
        let session = snapshot.lines.first { $0.label == "Session" }
        XCTAssertEqual(self.resetsAt(session), OpenUsageISO8601.date(from: "2026-11-01T09:20:37Z"))
        XCTAssertEqual(self.periodMs(session), MetricPeriod.sessionMs)
    }

    @MainActor
    func testLSPartialSummarySupplementalFailurePreservesAuthoritative3p() async {
        let groupsJSON = partial3pOnlyGroupsJSON
        let routing = RoutingHTTPClient { request in
            let path = request.url.path
            if path.hasSuffix("/RetrieveUserQuotaSummary") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("{\"response\":{\(groupsJSON)}}".utf8))
            }
            if path.hasSuffix("/GetUserStatus") {
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            }
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let provider = makeLSProvider(routing: routing)

        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Claude", "Claude Weekly"])
        XCTAssertEqual(snapshot.lines.map { self.used($0) }, [2, 95])
    }

    // MARK: - AntigravityUsageMapper.supplementMissingSession unit tests

    func testSupplementMissingSessionPreservesCompleteSummary() {
        let completeLines = [
            MetricLine.progress(label: "Session", used: 10, limit: 100, format: .percent),
            MetricLine.progress(label: "Claude", used: 20, limit: 100, format: .percent)
        ]
        let configs = [
            AntigravityModelConfig(label: "Gemini 2.5 Pro", modelID: "a", remainingFraction: 0.5, resetTime: nil)
        ]
        let result = AntigravityUsageMapper.supplementMissingSession(in: completeLines, from: configs)
        XCTAssertEqual(result, completeLines, "Complete summary is authoritative and must not be altered")
    }

    func testSupplementMissingSessionIgnoresEmptySummary() {
        let emptyLines: [MetricLine] = []
        let configs = [
            AntigravityModelConfig(label: "Gemini 2.5 Pro", modelID: "a", remainingFraction: 0.5, resetTime: nil)
        ]
        let result = AntigravityUsageMapper.supplementMissingSession(in: emptyLines, from: configs)
        XCTAssertTrue(result.isEmpty, "Authoritative empty summary must not be supplemented")
    }

    func testSupplementMissingSessionReturnsSummaryWhenNoGeminiConfigs() {
        let partialLines = [
            MetricLine.progress(label: "Claude", used: 20, limit: 100, format: .percent)
        ]
        let configs = [
            AntigravityModelConfig(label: "Claude Sonnet", modelID: "c", remainingFraction: 0.5, resetTime: nil)
        ]
        let result = AntigravityUsageMapper.supplementMissingSession(in: partialLines, from: configs)
        XCTAssertEqual(result, partialLines, "Summary remains unchanged when no Gemini configs exist")
    }

    func testSupplementMissingSessionTakesWorstRemainingFractionAndSorts() {
        let partialLines = [
            MetricLine.progress(label: "Claude", used: 10, limit: 100, format: .percent),
            MetricLine.progress(label: "Claude Weekly", used: 5, limit: 100, format: .percent)
        ]
        let configs = [
            AntigravityModelConfig(label: "Gemini 3 Flash", modelID: "f", remainingFraction: 0.9, resetTime: OpenUsageISO8601.date(from: "2026-11-01T10:00:00Z")),
            AntigravityModelConfig(label: "Gemini 2.5 Pro", modelID: "p", remainingFraction: 0.7, resetTime: OpenUsageISO8601.date(from: "2026-11-01T11:00:00Z"))
        ]
        let result = AntigravityUsageMapper.supplementMissingSession(in: partialLines, from: configs)
        XCTAssertEqual(result.map(\.label), ["Session", "Claude", "Claude Weekly"])
        XCTAssertEqual(result.map { used($0) }, [30, 10, 5])
        XCTAssertEqual(resetsAt(result[0]), OpenUsageISO8601.date(from: "2026-11-01T11:00:00Z"))
        XCTAssertEqual(periodMs(result[0]), MetricPeriod.sessionMs)
    }

    func testHasGeminiModelDetectsGeminiAndIgnoresBlacklist() {
        let onlyClaude = [
            AntigravityModelConfig(label: "Claude Sonnet 4.6", modelID: "claude-sonnet", remainingFraction: 0.8, resetTime: nil)
        ]
        XCTAssertFalse(AntigravityUsageMapper.hasGeminiModel(onlyClaude))

        let withGemini = [
            AntigravityModelConfig(label: "Claude Sonnet 4.6", modelID: "claude-sonnet", remainingFraction: 0.8, resetTime: nil),
            AntigravityModelConfig(label: "Gemini 2.5 Pro", modelID: "gemini-pro", remainingFraction: 0.9, resetTime: nil)
        ]
        XCTAssertTrue(AntigravityUsageMapper.hasGeminiModel(withGemini))

        let blacklistedGemini = [
            AntigravityModelConfig(label: "Gemini 2.5 Pro", modelID: "MODEL_GOOGLE_GEMINI_2_5_PRO", remainingFraction: 0.9, resetTime: nil)
        ]
        XCTAssertFalse(AntigravityUsageMapper.hasGeminiModel(blacklistedGemini))
    }
}

private struct NoProcessRunner: ProcessRunning {
    func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }
}

private struct FakeLSProcessRunner: ProcessRunning {
    func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> ProcessResult {
        if executable.hasSuffix("/ps") {
            let ps = "4276 /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone --override_ide_name antigravity --csrf_token tok --app_data_dir antigravity\n"
            return ProcessResult(exitCode: 0, stdout: ps, stderr: "")
        }
        let lsof = "language_ 4276 user 6u IPv4 0x0 0t0 TCP 127.0.0.1:52168 (LISTEN)\n"
        return ProcessResult(exitCode: 0, stdout: lsof, stderr: "")
    }
}
