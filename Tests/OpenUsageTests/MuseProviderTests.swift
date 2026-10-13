import Foundation
import XCTest
@testable import OpenUsage

private let museSSE = #"""
event: response.created
data: {"type":"response.created"}

event: response.subscription_usage
data: {"subscription":{"tier":"27681527378179523","weekly":{"resets_at":1792368000,"used_percent":0},"window":{"resets_at":1791876076,"used_percent":0,"window_duration_mins":300}},"type":"response.subscription_usage"}

"""#

private func museData(_ value: String) -> Data { Data(value.utf8) }

private func museAuthFile(
    baseURL: String = "https://api.meta.ai/v1",
    subscriptionActive: Bool = true,
    storage: String = "keychain"
) -> String {
    #"{"schema_version":2,"providers":{"meta":{"mechanism":"oauth","storage":"\#(storage)","obtained_via":"device_code","api_base_url":"\#(baseURL)","subs_active":\#(subscriptionActive)}}}"#
}

private final class MuseKeychain: KeychainAccessing, @unchecked Sendable {
    var value: String?
    var reads = 0
    var serviceOnlyReads = 0
    var writes = 0

    init(_ value: String? = #"{"secret_schema_version":1,"api_key":"LLM|synthetic-key-for-tests-000000000000000000000000000000000000"}"#) {
        self.value = value
    }

    func readGenericPassword(service: String) throws -> String? {
        serviceOnlyReads += 1
        XCTFail("Muse credentials must select the verified Keychain account")
        return nil
    }

    func readGenericPassword(service: String, account: String) throws -> String? {
        reads += 1
        XCTAssertEqual(service, MuseAuthStore.keychainService)
        XCTAssertEqual(account, MuseAuthStore.keychainAccount)
        return value
    }

    func writeGenericPassword(service: String, value: String) throws {
        writes += 1
        XCTFail("Muse must never write to Keychain")
    }

    func writeGenericPassword(service: String, account: String, value: String) throws {
        writes += 1
        XCTFail("Muse must never write to Keychain")
    }
}

private struct MuseHTTPClient: HTTPClient {
    let statusCode: Int
    let body: Data
    let recorder: MuseRequestRecorder

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        recorder.requests.append(request)
        return HTTPResponse(statusCode: statusCode, headers: ["content-type": "text/event-stream"], body: body)
    }
}

private final class MuseRequestRecorder: @unchecked Sendable {
    var requests: [HTTPRequest] = []
}

private func museAuthStore(
    files: FakeFiles = FakeFiles(["~/.config/muse/auth.json": museAuthFile()]),
    keychain: MuseKeychain = MuseKeychain(),
    environment: FakeEnvironment = FakeEnvironment()
) -> MuseAuthStore {
    MuseAuthStore(files: files, keychain: keychain, environment: environment)
}

@MainActor
final class MuseProviderTests: XCTestCase {
    func testMapsSubscriptionEventAndResetEpochSecondsToSessionAndWeeklyMeters() throws {
        let mapped = try MuseUsageMapper.map(eventStreamBody: museData(museSSE))

        XCTAssertEqual(mapped, [
            .progress(
                label: "Session", used: 0, limit: 100, format: .percent,
                resetsAt: Date(timeIntervalSince1970: 1_791_876_076),
                periodDurationMs: 18_000_000
            ),
            .progress(
                label: "Weekly", used: 0, limit: 100, format: .percent,
                resetsAt: Date(timeIntervalSince1970: 1_792_368_000),
                periodDurationMs: 604_800_000
            )
        ])
    }

    func testPreservesProviderPercentagesAboveOneHundred() throws {
        let body = """
        event: response.subscription_usage
        data: {"type":"response.subscription_usage","subscription":{"tier":"27681527378179523","window":{"used_percent":123,"resets_at":1791876076,"window_duration_mins":300},"weekly":{"used_percent":101,"resets_at":1792368000}}}

        """

        let mapped = try MuseUsageMapper.map(eventStreamBody: museData(body))

        let percentages = mapped.compactMap { line -> Double? in
            guard case .progress(_, let used, _, _, _, _, _) = line else { return nil }
            return used
        }
        XCTAssertEqual(percentages, [123, 101])
    }

    func testMissingSubscriptionEventIsUsageUnavailable() {
        XCTAssertThrowsError(try MuseUsageMapper.map(eventStreamBody: museData("event: response.completed\ndata: {}\n\n"))) { error in
            XCTAssertEqual(error as? MuseUsageError, .usageUnavailable)
        }
    }

    func testMalformedSubscriptionEventIsUsageUnavailable() {
        let body = "event: response.subscription_usage\ndata: {\"type\":\"response.subscription_usage\",\"subscription\":{}}\n\n"
        XCTAssertThrowsError(try MuseUsageMapper.map(eventStreamBody: museData(body))) { error in
            XCTAssertEqual(error as? MuseUsageError, .usageUnavailable)
        }
    }

    func testReadsOnlyTheConfiguredAuthFileAndAccountScopedKeychainSecret() throws {
        let files = FakeFiles(["/custom/muse-auth.json": museAuthFile()])
        let keychain = MuseKeychain()
        let store = museAuthStore(
            files: files,
            keychain: keychain,
            environment: FakeEnvironment(["MUSE_AUTH_PATH": "/custom/muse-auth.json"])
        )

        let credentials = try XCTUnwrap(store.loadCredentials())

        XCTAssertEqual(credentials.apiBaseURL.absoluteString, "https://api.meta.ai/v1")
        XCTAssertEqual(keychain.reads, 1)
        XCTAssertEqual(keychain.serviceOnlyReads, 0)
        XCTAssertEqual(keychain.writes, 0)
        XCTAssertEqual(files.files.count, 1)
    }

    func testResolvesXDGConfigHomeAndDefaultAuthFilePaths() throws {
        let xdgFiles = FakeFiles(["/xdg/muse/auth.json": museAuthFile()])
        let xdgStore = MuseAuthStore(
            files: xdgFiles,
            keychain: MuseKeychain(),
            environment: FakeEnvironment(["XDG_CONFIG_HOME": "/xdg"])
        )
        XCTAssertNotNil(try xdgStore.loadCredentials())

        let defaultFiles = FakeFiles(["~/.config/muse/auth.json": museAuthFile()])
        let defaultStore = MuseAuthStore(
            files: defaultFiles,
            keychain: MuseKeychain(),
            environment: FakeEnvironment()
        )
        XCTAssertNotNil(try defaultStore.loadCredentials())
    }

    func testMissingAuthFileAndMissingKeychainCredentialAreNotLoggedIn() async {
        let emptyKeychain = MuseKeychain()
        let noAuthRecorder = MuseRequestRecorder()
        let missingFile = MuseProvider(
            authStore: museAuthStore(files: FakeFiles(), keychain: emptyKeychain),
            usageClient: MuseUsageClient(http: MuseHTTPClient(statusCode: 200, body: museData(museSSE), recorder: noAuthRecorder))
        )
        let missingFileSnapshot = await missingFile.refresh()
        XCTAssertEqual(missingFileSnapshot.errorCategory, .notLoggedIn)
        XCTAssertEqual(emptyKeychain.reads, 0)
        XCTAssertTrue(noAuthRecorder.requests.isEmpty)

        let missingKeychain = MuseProvider(
            authStore: museAuthStore(keychain: MuseKeychain(nil)),
            usageClient: MuseUsageClient(http: MuseHTTPClient(statusCode: 200, body: museData(museSSE), recorder: MuseRequestRecorder()))
        )
        let missingKeychainSnapshot = await missingKeychain.refresh()
        XCTAssertEqual(missingKeychainSnapshot.errorCategory, .notLoggedIn)
    }

    func testInactiveSubscriptionFailsBeforeMakingARequest() async {
        let recorder = MuseRequestRecorder()
        let keychain = MuseKeychain(nil)
        let provider = MuseProvider(
            authStore: museAuthStore(
                files: FakeFiles(["~/.config/muse/auth.json": museAuthFile(subscriptionActive: false)]),
                keychain: keychain
            ),
            usageClient: MuseUsageClient(http: MuseHTTPClient(statusCode: 200, body: museData(museSSE), recorder: recorder))
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notAvailable)
        XCTAssertEqual(errorMessage(snapshot), "Your Muse subscription is inactive.")
        XCTAssertEqual(keychain.reads, 0)
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testUnauthorizedResponseRequestsMuseLoginAgain() async {
        for statusCode in [401, 403] {
            let snapshot = await makeProvider(statusCode: statusCode, body: Data()).refresh()

            XCTAssertEqual(snapshot.errorCategory, .notLoggedIn, "HTTP \(statusCode)")
            XCTAssertEqual(errorMessage(snapshot), "Run muse login and try again.", "HTTP \(statusCode)")
        }
    }

    func testMissingUsageEventFailsLoudly() async {
        let provider = makeProvider(statusCode: 200, body: museData("event: response.completed\ndata: {}\n\n"))

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notAvailable)
        XCTAssertEqual(errorMessage(snapshot), "Muse subscription usage is unavailable.")
    }

    func testRequestUsesResponsesStreamingContractAndSnapshotMeters() async throws {
        let recorder = MuseRequestRecorder()
        let provider = MuseProvider(
            authStore: museAuthStore(),
            usageClient: MuseUsageClient(http: MuseHTTPClient(statusCode: 200, body: museData(museSSE), recorder: recorder)),
            now: { Date(timeIntervalSince1970: 1_791_800_000) }
        )

        let snapshot = await provider.refresh()
        let request = try XCTUnwrap(recorder.requests.first)
        let body = try XCTUnwrap(request.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let reasoning = try XCTUnwrap(json["reasoning"] as? [String: Any])

        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://api.meta.ai/v1/responses")
        XCTAssertEqual(request.headers["Authorization"], "Bearer LLM|synthetic-key-for-tests-000000000000000000000000000000000000")
        XCTAssertEqual(request.headers["x-client-id"], "tbh:exec")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        XCTAssertEqual(json["model"] as? String, "muse-spark-1.2")
        XCTAssertEqual(json["input"] as? String, "hi")
        XCTAssertEqual(json["max_output_tokens"] as? Int, 16)
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["store"] as? Bool, false)
        XCTAssertEqual(reasoning["effort"] as? String, "minimal")
        XCTAssertEqual(snapshot.providerID, "muse")
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly"])
    }

    func testUsageReadUsesOneResponsesRequestPerRefreshAndCredentialProbeIsLocal() async {
        let recorder = MuseRequestRecorder()
        let keychain = MuseKeychain()
        let provider = MuseProvider(
            authStore: museAuthStore(keychain: keychain),
            usageClient: MuseUsageClient(http: MuseHTTPClient(statusCode: 200, body: museData(museSSE), recorder: recorder))
        )

        let hasCredentials = await provider.hasLocalCredentials()
        XCTAssertTrue(hasCredentials)
        XCTAssertTrue(recorder.requests.isEmpty)
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(keychain.writes, 0)
    }

    func testBothMetersAreEnabledAlwaysVisiblePinnedAndSessionComesFirst() {
        let descriptors = MuseProvider().widgetDescriptors

        XCTAssertEqual(descriptors.map(\.id), ["muse.session", "muse.weekly"])
        XCTAssertTrue(DefaultLayout.metricIDs.contains("muse.session"))
        XCTAssertTrue(DefaultLayout.metricIDs.contains("muse.weekly"))
        XCTAssertFalse(DefaultLayout.expandedMetricIDs.contains("muse.session"))
        XCTAssertFalse(DefaultLayout.expandedMetricIDs.contains("muse.weekly"))
        XCTAssertEqual(
            DefaultLayout.pinnedMetricIDs.filter { $0 == "muse.session" || $0 == "muse.weekly" },
            ["muse.session", "muse.weekly"]
        )
    }

    private func makeProvider(statusCode: Int, body: Data) -> MuseProvider {
        MuseProvider(
            authStore: museAuthStore(),
            usageClient: MuseUsageClient(http: MuseHTTPClient(statusCode: statusCode, body: body, recorder: MuseRequestRecorder()))
        )
    }

    private func errorMessage(_ snapshot: ProviderSnapshot) -> String? {
        guard case .some(.badge(_, let text, _, _)) = snapshot.lines.first else { return nil }
        return text
    }
}
