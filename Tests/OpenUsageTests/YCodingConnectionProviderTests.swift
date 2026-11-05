import XCTest
@testable import OpenUsage

@MainActor
final class YCodingConnectionProviderTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    func testCardIdentityPreservesProviderAndExactCredentialIDAcrossRename() {
        let original = connection("openai", id: "Credential-A", profile: "Work")
        let renamed = connection("openai", id: "Credential-A", profile: "Renamed", active: false)
        let sameLabel = connection("openai", id: "Credential-B", profile: "Work")
        let lowercased = connection("openai", id: "credential-a", profile: "Work")
        let differentProvider = connection("anthropic", id: "Credential-A", profile: "Work")

        XCTAssertEqual(original.cardID, renamed.cardID)
        XCTAssertNotEqual(original.provider.displayName, renamed.provider.displayName)
        XCTAssertEqual(Set([original, sameLabel, lowercased, differentProvider].map(\.cardID)).count, 4)
        XCTAssertEqual(ProviderAccountID.family(of: original.cardID), "codex")
        XCTAssertEqual(ProviderAccountID.family(of: differentProvider.cardID), "claude")
        XCTAssertFalse(original.cardID.contains(original.profile))
    }

    func testQuotaAndRecordedUsageStayWithExactProviderAndProfile() throws {
        let work = connection("openai", id: "work", profile: "Work")
        let personal = connection("openai", id: "personal", profile: "Personal")
        let anthropic = connection("anthropic", id: "claude", profile: "Work")
        let rows = [usage(work, cost: 2), usage(personal, cost: 9), usage(anthropic, cost: 42)]
        let read = fixtureRead(connections: [work, personal, anthropic], quotas: [
            quota(work, used: 10), quota(personal, used: 90), quota(anthropic, window: "five-hour", used: 70)
        ], rows: rows)

        let workSnapshot = YCodingConnectionMapper.snapshot(for: work, read: read)
        let personalSnapshot = YCodingConnectionMapper.snapshot(for: personal, read: read)
        let anthropicSnapshot = YCodingConnectionMapper.snapshot(for: anthropic, read: read)

        XCTAssertEqual(progress(workSnapshot, "Session")?.used, 10)
        XCTAssertEqual(progress(personalSnapshot, "Session")?.used, 90)
        XCTAssertEqual(progress(anthropicSnapshot, "Session")?.used, 70)
        XCTAssertEqual(values(workSnapshot, "Today").first?.number, 2)
        XCTAssertEqual(values(personalSnapshot, "Today").first?.number, 9)
        XCTAssertEqual(values(anthropicSnapshot, "Today").first?.number, 42)
        XCTAssertEqual(workSnapshot.providerID, work.cardID)
        XCTAssertNil(workSnapshot.errorCategory)
    }

    func testUnavailableQuotaPreservesOrdinaryKeyUsageWithoutInferringAuthKind() {
        for providerID in ["openai", "anthropic"] {
            let profile = connection(providerID, id: "key-fixture", profile: "API Profile")
            let read = fixtureRead(connections: [profile], quotas: [quota(profile, status: .unsupported)],
                                   rows: [usage(profile, cost: 4.25)])
            let snapshot = YCodingConnectionMapper.snapshot(for: profile, read: read)

            XCTAssertEqual(profile.authentication, .unknown)
            XCTAssertNil(snapshot.errorCategory)
            XCTAssertEqual(values(snapshot, "Today").first?.number, 4.25)
            XCTAssertNil(progress(snapshot, "Session"))
            XCTAssertTrue(snapshot.warning?.contains("no profile-bound quotas") == true)
            XCTAssertFalse(snapshot.displayName.contains("Admin"))
        }
    }

    func testQuotaTimestampsUseMillisecondsAndPeriodsUseSeconds() {
        let profile = connection("muse", id: "muse", profile: "Personal")
        let read = fixtureRead(connections: [profile], quotas: [quota(profile, window: "window", used: 110)])
        let snapshot = YCodingConnectionMapper.snapshot(for: profile, read: read)
        let session = progress(snapshot, "Session")

        XCTAssertEqual(session?.used, 110, "Overage must remain visible, not be clamped")
        XCTAssertEqual(session?.limit, 100)
        XCTAssertEqual(session?.reset, Date(timeIntervalSince1970: 1_800_003_600))
        XCTAssertEqual(session?.duration, 18_000_000)
        XCTAssertEqual(snapshot.refreshedAt, instant)
    }

    func testUnknownOrDuplicateQuotaPoolsDoNotSelectArbitraryUsage() {
        let profile = connection("antigravity", id: "antigravity", profile: "Work")
        let first = window(id: "five-hour", used: 10)
        let second = window(id: "Gemini/five-hour", used: 80)
        let snapshot = YCodingQuotaSnapshot(providerID: "antigravity", label: "Antigravity", profile: "Work",
                                            status: .available, source: .providerInternalAPI, stability: .clientContract,
                                            updatedAt: instant.timeIntervalSince1970 * 1000,
                                            windows: [first, second], message: nil)
        let read = fixtureRead(connections: [profile], quotas: [snapshot], rows: [usage(profile)])
        let mapped = YCodingConnectionMapper.snapshot(for: profile, read: read)

        XCTAssertNil(progress(mapped, "Session"))
        XCTAssertTrue(mapped.warning?.contains("no compatible quota meters") == true)
        XCTAssertFalse(values(mapped, "Today").isEmpty)
    }

    func testAntigravityCurrentGroupedPoolNamesMapWithoutCombiningPools() {
        let profile = connection("antigravity", id: "antigravity", profile: "Work")
        let windows = [window(id: "Gemini Models/five-hour", used: 11),
                       window(id: "Gemini Models/weekly", used: 22),
                       window(id: "Claude and GPT models/five-hour", used: 33),
                       window(id: "Claude and GPT models/weekly", used: 44)]
        let quota = YCodingQuotaSnapshot(providerID: "antigravity", label: "Antigravity", profile: "Work",
                                         status: .available, source: .providerInternalAPI, stability: .clientContract,
                                         updatedAt: instant.timeIntervalSince1970 * 1000,
                                         windows: windows, message: nil)
        let snapshot = YCodingConnectionMapper.snapshot(for: profile,
            read: fixtureRead(connections: [profile], quotas: [quota]))

        XCTAssertEqual(progress(snapshot, "Session")?.used, 11)
        XCTAssertEqual(progress(snapshot, "Weekly")?.used, 22)
        XCTAssertEqual(progress(snapshot, "Claude")?.used, 33)
        XCTAssertEqual(progress(snapshot, "Claude Weekly")?.used, 44)
        XCTAssertNil(snapshot.errorCategory)
    }

    func testCostCoverageAndPriceProvenanceRemainVisible() {
        let profile = connection("openai", id: "openai", profile: "Work")
        let row = usage(profile, cost: 2, provenance: "current_catalog", unpriced: 2)
        let snapshot = YCodingConnectionMapper.snapshot(for: profile,
            read: fixtureRead(connections: [profile], quotas: [quota(profile)], rows: [row]))
        let today = values(snapshot, "Today")

        XCTAssertEqual(today.first?.number, 2)
        XCTAssertTrue(today.first?.estimated == true)
        XCTAssertEqual(today.last?.number, 15)
        XCTAssertEqual(today.last?.label, "tokens")
        XCTAssertTrue(snapshot.warning?.contains("value is incomplete") == true)
        XCTAssertEqual(snapshot.warning?.components(separatedBy: "value is incomplete").count, 2,
                       "The same missing-price warning is not repeated for each period")
    }

    func testUpstreamQuotaErrorBodyIsNeverReturned() {
        let profile = connection("cursor", id: "cursor", profile: "Work")
        let marker = "synthetic-error-payload-must-not-escape"
        let snapshot = YCodingConnectionMapper.snapshot(for: profile,
            read: fixtureRead(connections: [profile], quotas: [quota(profile, status: .error, message: marker)]))

        XCTAssertEqual(snapshot.errorCategory, .notAvailable)
        XCTAssertFalse(String(describing: snapshot).contains(marker))
        XCTAssertTrue(snapshot.lines.contains(where: \.isError))
    }

    func testSharedBridgeReadsOnceForConcurrentProfilesAndReusesShortCache() async throws {
        let work = connection("openai", id: "work", profile: "Work")
        let personal = connection("openai", id: "personal", profile: "Personal")
        let client = FixtureClient(connections: [[work, personal]], quotas: [quota(work), quota(personal)],
                                   rows: [usage(work), usage(personal)], blockAutomatic: true)
        let bridge = YCodingConnectionBridge(client: client, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let first = Task { try await bridge.read(manual: false) }
        await client.waitForAutomaticSnapshot()
        let second = Task { try await bridge.read(manual: false) }
        await Task.yield()
        await client.releaseAutomatic()
        _ = try await first.value
        _ = try await second.value
        _ = try await bridge.read(manual: false)

        let calls = await client.calls()
        XCTAssertEqual(calls.connections, 2, "Metadata is checked before and after one shared read")
        XCTAssertEqual(calls.snapshots, [false])
        XCTAssertEqual(calls.usage, 3)
    }

    func testManualRefreshDuringAutomaticReadStillRequestsExplicitProbe() async throws {
        let profile = connection("muse", id: "muse", profile: "Work")
        let client = FixtureClient(connections: [[profile]], quotas: [quota(profile, window: "window")],
                                   blockAutomatic: true)
        let bridge = YCodingConnectionBridge(client: client, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let automatic = Task { try await bridge.read(manual: false) }
        await client.waitForAutomaticSnapshot()
        let manual = Task { try await bridge.read(manual: true) }
        await Task.yield()
        await client.releaseAutomatic()
        _ = try await automatic.value
        _ = try await manual.value

        let calls = await client.calls()
        XCTAssertEqual(calls.snapshots, [false, true])
        XCTAssertEqual(calls.usage, 6)
    }

    func testMetadataReplacementRenameOrRemovalFailsClosed() async {
        let original = connection("openai", id: "original", profile: "Work")
        let replacements = [
            [connection("openai", id: "replacement", profile: "Work")],
            [connection("openai", id: "original", profile: "Renamed")],
            []
        ]
        for after in replacements {
            let client = FixtureClient(connections: [[original], after], quotas: [quota(original)])
            let bridge = YCodingConnectionBridge(client: client)
            let provider = YCodingConnectionProvider(connection: original, bridge: bridge)
            let result = await provider.refresh()

            XCTAssertEqual(result.errorCategory, .notAvailable)
            XCTAssertTrue(errorMessage(result).contains("connections changed"))
            XCTAssertNil(progress(result, "Session"))
        }
    }

    func testActiveSwitchDoesNotChangeProfileOwnership() async {
        let active = connection("openai", id: "work", profile: "Work")
        let inactive = connection("openai", id: "work", profile: "Work", active: false)
        let client = FixtureClient(connections: [[active], [inactive]], quotas: [quota(active, used: 30)])
        let provider = YCodingConnectionProvider(connection: active, bridge: YCodingConnectionBridge(client: client))
        let result = await provider.refresh()

        XCTAssertNil(result.errorCategory)
        XCTAssertEqual(progress(result, "Session")?.used, 30)
    }

    func testProviderDoesNotFallBackAfterItsDiscoveredProfileDisappears() async {
        let original = connection("openai", id: "original", profile: "Work")
        let other = connection("openai", id: "other", profile: "Personal")
        let client = FixtureClient(connections: [[other]], quotas: [quota(other, used: 99)])
        let provider = YCodingConnectionProvider(connection: original, bridge: YCodingConnectionBridge(client: client))
        let result = await provider.refresh()

        XCTAssertEqual(result.errorCategory, .notAvailable)
        XCTAssertNil(progress(result, "Session"))
    }

    func testQuotaTransportFailureRetainsUsageAndSanitizesError() async {
        let profile = connection("anthropic", id: "api", profile: "API Profile")
        let client = FixtureClient(connections: [[profile]], rows: [usage(profile)], failQuota: true)
        let provider = YCodingConnectionProvider(connection: profile, bridge: YCodingConnectionBridge(client: client))
        let result = await provider.refresh()

        XCTAssertNil(result.errorCategory)
        XCTAssertFalse(values(result, "Today").isEmpty)
        XCTAssertTrue(result.warning?.contains("could not be refreshed") == true)
        XCTAssertFalse(String(describing: result).contains(FixtureError.marker))
    }

    func testHistoryTransportFailureRetainsQuotaAndSanitizesError() async {
        let profile = connection("openai", id: "account", profile: "Account Profile")
        let client = FixtureClient(connections: [[profile]], quotas: [quota(profile, used: 37)], failUsage: true)
        let provider = YCodingConnectionProvider(connection: profile, bridge: YCodingConnectionBridge(client: client))
        let result = await provider.refresh()

        XCTAssertNil(result.errorCategory)
        XCTAssertEqual(progress(result, "Session")?.used, 37)
        XCTAssertTrue(values(result, "Today").isEmpty)
        XCTAssertTrue(values(result, "Yesterday").isEmpty)
        XCTAssertTrue(values(result, "Last 30 Days").isEmpty)
        XCTAssertTrue(result.warning?.contains("recorded usage could not be read") == true)
        XCTAssertFalse(String(describing: result).contains(FixtureError.marker))
        let calls = await client.calls()
        XCTAssertEqual(calls.usage, 3)
    }

    func testDiscoveryFailureIsVisibleAndSafe() async throws {
        let assembly = await YCodingProviderAssembly.make(client: FixtureClient(connections: [], failConnections: true))
        let provider = try XCTUnwrap(assembly.providers.first)
        let result = await provider.refresh()

        XCTAssertEqual(assembly.providers.count, 1)
        XCTAssertEqual(provider.provider.displayName, "YCoding")
        XCTAssertEqual(result.errorCategory, .notAvailable)
        XCTAssertFalse(String(describing: result).contains(FixtureError.marker))
        XCTAssertFalse(provider.widgetDescriptors.isEmpty)
    }

    func testDiscoveryUsesFreshCacheStampsAndDetectionNeedsNoAdditionalReads() async throws {
        let profile = connection("cursor", id: "cursor", profile: "Work")
        let client = FixtureClient(connections: [[profile]])
        let first = await YCodingProviderAssembly.make(client: client)
        let second = await YCodingProviderAssembly.make(client: client)
        let provider = try XCTUnwrap(first.providers.first)
        let detected = await provider.hasLocalCredentials()

        XCTAssertTrue(detected)
        XCTAssertEqual(first.providers.map(\.provider.id), second.providers.map(\.provider.id))
        XCTAssertNotEqual(first.identityKeysByCard[profile.cardID], second.identityKeysByCard[profile.cardID])
        let calls = await client.calls()
        XCTAssertEqual(calls.connections, 2)
        XCTAssertTrue(calls.snapshots.isEmpty)
        XCTAssertEqual(calls.usage, 0)
    }

    func testCatalogKeepsProfileCardsBesideFamilyAndInheritsExistingMetricDefaults() throws {
        let profiles = [connection("openai", id: "openai", profile: "Work"),
                        connection("cursor", id: "cursor", profile: "Work"),
                        connection("muse", id: "muse", profile: "Work")]
        let bridge = YCodingConnectionBridge(client: FixtureClient(connections: [profiles]))
        let runtimes = profiles.map { YCodingConnectionProvider(connection: $0, bridge: bridge) }
        let catalog = ProviderCatalog.make(defaults: makeScratchDefaults(),
            excludingYCodingFamilies: YCodingConnectionBridge.replacedLegacyFamilies, ycodingProviders: runtimes)
        let ids = catalog.map(\.provider.id)

        for profile in profiles {
            let native = try XCTUnwrap(ids.firstIndex(of: profile.family))
            let scoped = try XCTUnwrap(ids.firstIndex(of: profile.cardID))
            XCTAssertEqual(scoped, native + 1)
            let nativeEnabled = DefaultLayout.metricIDs.filter { $0.hasPrefix(profile.family + ".") }
            let expanded = DefaultLayout.expandingAccounts(DefaultLayout.metricIDs, providerIDs: ids)
            for metric in nativeEnabled {
                let suffix = metric.dropFirst(profile.family.count)
                XCTAssertTrue(expanded.contains(profile.cardID + String(suffix)))
            }
        }
    }

    func testCursorRecordedUsageDoesNotDoubleCountNativeAccountWideSpend() {
        let cursor = connection("cursor", id: "cursor", profile: "Work")
        let openai = connection("openai", id: "openai", profile: "Work")
        let cursorSpend = YCodingConnectionMapper.descriptors(for: cursor).filter {
            ["Today", "Yesterday", "Last 30 Days"].contains($0.title)
        }
        let openaiSpend = YCodingConnectionMapper.descriptors(for: openai).filter {
            ["Today", "Yesterday", "Last 30 Days"].contains($0.title)
        }

        XCTAssertEqual(cursorSpend.count, 3)
        XCTAssertTrue(cursorSpend.allSatisfy { !$0.isSpendTile })
        XCTAssertTrue(openaiSpend.allSatisfy { !$0.isSpendTile })
    }

    private func connection(_ integration: String, id: String, profile: String, active: Bool = true) -> YCodingConnection {
        .init(integrationID: integration, id: id, profile: profile, active: active)
    }

    private func window(id: String, used: Double = 25) -> YCodingQuotaWindow {
        .init(id: id, label: "Fixture Window", group: nil, unit: .percent, used: used, limit: nil,
              remaining: nil, unlimited: nil, resetAt: 1_800_003_600_000, periodSeconds: 18_000)
    }

    private func quota(_ connection: YCodingConnection, window id: String = "codex-primary", used: Double = 25,
                       status: YCodingQuotaSnapshot.Status = .available, message: String? = nil) -> YCodingQuotaSnapshot {
        .init(providerID: connection.integrationID, label: "Fixture Provider", profile: connection.profile,
              status: status, source: .providerInternalAPI, stability: .clientContract,
              updatedAt: instant.timeIntervalSince1970 * 1000, windows: [window(id: id, used: used)], message: message)
    }

    private func usage(_ connection: YCodingConnection, cost: Double? = 1, provenance: String? = "recorded",
                       unpriced: Int = 0) -> YCodingProfileUsage {
        .init(providerID: connection.integrationID, profile: connection.profile, cost: cost,
              costProvenance: provenance, costCoverage: .init(pricedRequests: 1, unpricedRequests: unpriced),
              tokens: .init(input: 1, output: 2, reasoning: 3, cache: .init(read: 4, write: 5)), physical: 1)
    }

    private func fixtureRead(connections: [YCodingConnection], quotas: [YCodingQuotaSnapshot] = [],
                             rows: [YCodingProfileUsage] = []) -> YCodingConnectionRead {
        .init(connections: connections, quotas: quotas, today: rows, yesterday: rows, last30: rows, warning: nil)
    }

    private func values(_ snapshot: ProviderSnapshot, _ label: String) -> [MetricValue] {
        guard let line = snapshot.line(label: label), case .values(_, let values, _, _, _, _) = line else { return [] }
        return values
    }

    private func progress(_ snapshot: ProviderSnapshot, _ label: String)
        -> (used: Double, limit: Double, reset: Date?, duration: Int?)? {
        guard let line = snapshot.line(label: label),
              case .progress(_, let used, let limit, _, let reset, let duration, _) = line else { return nil }
        return (used, limit, reset, duration)
    }

    private func errorMessage(_ snapshot: ProviderSnapshot) -> String {
        guard let line = snapshot.lines.first, case .badge(_, let text, _, _) = line else { return "" }
        return text
    }
}

private struct FixtureError: Error, LocalizedError {
    static let marker = "synthetic-upstream-payload-must-not-escape"
    var errorDescription: String? { Self.marker }
}

private actor FixtureClient: YCodingConnectionReading {
    private let connectionBatches: [[YCodingConnection]]
    private let quotaValues: [YCodingQuotaSnapshot]
    private let rows: [YCodingProfileUsage]
    private let failConnections: Bool
    private let failQuota: Bool
    private let failUsage: Bool
    private var blockAutomatic: Bool
    private var connectionCalls = 0
    private var snapshotCalls: [Bool] = []
    private var usageCalls = 0
    private var snapshotWaiters: [CheckedContinuation<Void, Never>] = []
    private var automaticRelease: CheckedContinuation<Void, Never>?

    init(connections: [[YCodingConnection]], quotas: [YCodingQuotaSnapshot] = [], rows: [YCodingProfileUsage] = [],
         failConnections: Bool = false, failQuota: Bool = false, failUsage: Bool = false,
         blockAutomatic: Bool = false) {
        self.connectionBatches = connections
        self.quotaValues = quotas
        self.rows = rows
        self.failConnections = failConnections
        self.failQuota = failQuota
        self.failUsage = failUsage
        self.blockAutomatic = blockAutomatic
    }

    func connections() async throws -> [YCodingConnection] {
        connectionCalls += 1
        if failConnections { throw FixtureError() }
        guard !connectionBatches.isEmpty else { return [] }
        return connectionBatches[min(connectionCalls - 1, connectionBatches.count - 1)]
    }

    func snapshots(refresh: Bool) async throws -> [YCodingQuotaSnapshot] {
        snapshotCalls.append(refresh)
        if !refresh && blockAutomatic {
            await withCheckedContinuation { continuation in
                automaticRelease = continuation
                snapshotWaiters.forEach { $0.resume() }
                snapshotWaiters.removeAll()
            }
        }
        if failQuota { throw FixtureError() }
        return quotaValues
    }

    func usage(from: Date, to: Date) async throws -> [YCodingProfileUsage] {
        usageCalls += 1
        if failUsage { throw FixtureError() }
        return rows
    }

    func calls() -> (connections: Int, snapshots: [Bool], usage: Int) {
        (connectionCalls, snapshotCalls, usageCalls)
    }

    func waitForAutomaticSnapshot() async {
        guard automaticRelease == nil else { return }
        await withCheckedContinuation { snapshotWaiters.append($0) }
    }

    func releaseAutomatic() {
        blockAutomatic = false
        automaticRelease?.resume()
        automaticRelease = nil
    }
}
