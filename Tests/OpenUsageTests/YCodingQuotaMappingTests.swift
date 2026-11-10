import XCTest
@testable import OpenUsage

@MainActor
final class YCodingQuotaMappingTests: XCTestCase {
    private let connection = YCodingConnection(integrationID: "openai", id: "account", profile: "Account", active: true,
                                               authentication: .account)
    private let reset = Date(timeIntervalSince1970: 1_800_200_000)

    func testOpenAIAPIKeyShowsRealPrepaidBalanceIncludingZero() {
        let key = YCodingConnection(integrationID: "openai", id: "api-key", profile: "API", active: true,
                                    authentication: .apiKey)
        for amount in [0.0, 12.5] {
            let balance = YCodingQuotaWindow(id: "api-credit-balance", label: "API credit balance", group: nil,
                                             unit: .usd, used: nil, limit: nil, remaining: amount,
                                             unlimited: nil, resetAt: nil, periodSeconds: nil)
            let snapshot = map([balance], connection: key)
            XCTAssertEqual(values(snapshot, "API Credit Balance").map(\.number), [amount])
            XCTAssertNil(snapshot.line(label: "Credits"))
        }
    }

    func testClaudeAccountPrepaidBalanceIsSeparateFromExtraUsage() {
        let claude = YCodingConnection(integrationID: "anthropic", id: "account", profile: "Account", active: true,
                                       authentication: .account)
        let balance = YCodingQuotaWindow(id: "prepaid-balance", label: "Prepaid balance", group: nil,
                                         unit: .usd, used: nil, limit: nil, remaining: 0,
                                         unlimited: nil, resetAt: nil, periodSeconds: nil)
        let snapshot = map([usd("extra-usage", used: 12, limit: 50), balance], connection: claude)
        XCTAssertEqual(values(snapshot, "Prepaid Balance").map(\.number), [0])
        XCTAssertNotNil(snapshot.line(label: "Extra usage spent"))
    }

    func testBalanceDefaultsAreEnabledOnDemandAndNotPinned() {
        for id in ["codex.prepaid", "claude.prepaid"] {
            XCTAssertTrue(DefaultLayout.metricIDs.contains(id))
            XCTAssertTrue(DefaultLayout.expandedMetricIDs.contains(id))
            XCTAssertFalse(DefaultLayout.pinnedMetricIDs.contains(id))
        }
        let key = YCodingConnection(integrationID: "openai", id: "api-key", profile: "API", active: true,
                                    authentication: .apiKey)
        let descriptors = YCodingConnectionMapper.descriptors(for: key)
        let balance = descriptors.firstIndex { $0.title == "API Credit Balance" }
        let trend = descriptors.firstIndex { $0.title == "Usage Trend" }
        XCTAssertNotNil(balance)
        XCTAssertNotNil(trend)
        if let balance, let trend { XCTAssertLessThan(balance, trend) }
    }

    func testPrimaryOnlyWeeklyAllowancePreservesZeroRemainingAndReset() {
        let snapshot = map([window("codex-primary", period: 604_800, used: 100)])

        XCTAssertNil(snapshot.line(label: "Session"))
        assertProgress(snapshot, "Weekly", used: 100, duration: 604_800_000)
        XCTAssertNil(snapshot.warning)
    }

    func testBothResponsePositionsAreClassifiedByDuration() {
        for windows in [
            [window("codex-primary", period: 18_000, used: 12), window("codex-secondary", period: 604_800, used: 73)],
            [window("codex-primary", period: 604_800, used: 73), window("codex-secondary", period: 18_000, used: 12)]
        ] {
            let snapshot = map(windows)
            assertProgress(snapshot, "Session", used: 12, duration: 18_000_000)
            assertProgress(snapshot, "Weekly", used: 73, duration: 604_800_000)
        }
    }

    func testMissingDurationCannotClassifyPrimaryOrSecondaryByPosition() {
        let snapshot = map([window("codex-primary", period: nil, used: 21), window("codex-secondary", period: nil, used: 43)])
        XCTAssertNil(snapshot.line(label: "Session"))
        XCTAssertNil(snapshot.line(label: "Weekly"))
        XCTAssertEqual(snapshot.errorCategory, .notAvailable)
    }

    func testUnknownDurationOrAmbiguousWeeklyWindowsDoesNotInventAQuota() {
        for windows in [
            [window("codex-primary", period: 86_400, used: 10)],
            [window("codex-primary", period: 604_800, used: 10), window("codex-secondary", period: 604_800, used: 90)],
            [window("unrecognized-pool", period: 604_800, used: 10)]
        ] {
            let snapshot = map(windows)
            XCTAssertNil(snapshot.line(label: "Session"))
            XCTAssertNil(snapshot.line(label: "Weekly"))
            XCTAssertEqual(snapshot.errorCategory, .notAvailable)
            XCTAssertTrue(snapshot.lines.contains(where: \.isError))
        }
    }

    func testCodexCreditsRenderLikeNativeExtraUsageIncludingRealZero() {
        let credits = map([count("codex-credits", remaining: 9370)])
        XCTAssertEqual(values(credits, "Credits"), CodexUsageMapper.creditValues(remaining: 9370))
        XCTAssertEqual(values(credits, "Credits").first?.number ?? 0, 374.8, accuracy: 1e-9)
        XCTAssertEqual(values(credits, "Credits").last?.number, 9370)
        XCTAssertNil(credits.warning)
        XCTAssertEqual(values(map([count("codex-credits", remaining: 0)]), "Credits").map(\.number), [0, 0])
        XCTAssertEqual(values(map([count("pro-credits", remaining: 25)]), "Credits"), CodexUsageMapper.creditValues(remaining: 25))
        let descriptors = YCodingConnectionMapper.descriptors(for: connection)
        XCTAssertTrue(descriptors.contains { $0.id == "\(connection.cardID).credits" && $0.title == "Extra Usage" && $0.metricLabel == "Credits" })
    }

    func testUnlimitedOrAmbiguousCreditsShowNoInventedBalance() {
        XCTAssertNil(map([count("codex-credits", remaining: nil, unlimited: true)]).line(label: "Credits"))
        XCTAssertNil(map([count("codex-credits", remaining: 4), count("pro-credits", remaining: 9)]).line(label: "Credits"))
    }

    func testRateLimitResetsShowAvailableCountIncludingZero() {
        for available in [2.0, 0.0] {
            let snapshot = map([count("reset-credits", remaining: available)])
            XCTAssertEqual(values(snapshot, "Rate Limit Resets").map(\.number), [available])
            XCTAssertEqual(values(snapshot, "Rate Limit Resets").first?.label, "available")
            XCTAssertEqual(values(snapshot, "Rate Limit Resets").first?.kind, .count)
            XCTAssertNil(snapshot.line(label: "Credits"), "Reset credits are not flex credits")
        }
        XCTAssertTrue(YCodingConnectionMapper.descriptors(for: connection).contains {
            $0.id == "\(connection.cardID).rateLimitResets" && $0.title == "Rate Limit Resets"
        })
    }

    func testMissingBalanceWindowsLeaveNoBalanceRows() {
        let snapshot = map([window("codex-primary", period: 18_000, used: 12)])
        XCTAssertNil(snapshot.line(label: "Credits"))
        XCTAssertNil(snapshot.line(label: "Rate Limit Resets"))
        XCTAssertNil(snapshot.line(label: "Extra usage spent"))
    }

    func testClaudeExtraUsageMatchesNativeCard() {
        let claude = YCodingConnection(integrationID: "anthropic", id: "claude", profile: "Account", active: true,
                                       authentication: .account)
        let limited = map([usd("extra-usage", used: 12.5, limit: 50)], connection: claude)
        guard case .progress(_, let used, let limit, let format, _, _, _) = limited.line(label: "Extra usage spent") else {
            return XCTFail("Expected extra usage progress")
        }
        XCTAssertEqual(used, 12.5)
        XCTAssertEqual(limit, 50)
        XCTAssertEqual(format, .dollars)
        let unlimited = map([usd("extra-usage", used: 7, limit: nil)], connection: claude)
        XCTAssertEqual(values(unlimited, "Extra usage spent").map(\.number), [7])
        XCTAssertEqual(values(unlimited, "Extra usage spent").first?.kind, .dollars)
        XCTAssertNil(map([usd("extra-usage", used: 0, limit: nil), window("five-hour", period: 18_000, used: 1)],
                         connection: claude).line(label: "Extra usage spent"))
        XCTAssertNil(map([window("five-hour", period: 18_000, used: 1)], connection: claude).line(label: "Extra usage spent"))
        XCTAssertTrue(YCodingConnectionMapper.descriptors(for: claude).contains {
            $0.id == "\(claude.cardID).extra" && $0.title == "Extra Usage" && $0.metricLabel == "Extra usage spent"
        })
        XCTAssertNil(map([count("codex-credits", remaining: 4)], connection: claude).line(label: "Credits"))
    }

    private func count(_ id: String, remaining: Double?, unlimited: Bool? = nil) -> YCodingQuotaWindow {
        .init(id: id, label: "Credits", group: nil, unit: .count, used: nil, limit: nil,
              remaining: remaining, unlimited: unlimited, resetAt: nil, periodSeconds: nil)
    }

    private func usd(_ id: String, used: Double, limit: Double?) -> YCodingQuotaWindow {
        .init(id: id, label: "Extra usage", group: nil, unit: .usd, used: used, limit: limit,
              remaining: limit.map { $0 - used }, unlimited: nil, resetAt: nil, periodSeconds: nil)
    }

    private func values(_ snapshot: ProviderSnapshot, _ label: String) -> [MetricValue] {
        guard case .values(_, let values, _, _, _, _) = snapshot.line(label: label) else { return [] }
        return values
    }

    private func map(_ windows: [YCodingQuotaWindow], connection: YCodingConnection) -> ProviderSnapshot {
        let quota = YCodingQuotaSnapshot(providerID: connection.integrationID, label: "Fixture", profile: connection.profile,
            status: .available, source: .providerInternalAPI, stability: .bestEffort,
            updatedAt: 1_800_000_000_000, windows: windows, message: nil)
        return YCodingConnectionMapper.snapshot(for: connection, read: .init(connections: [connection],
            quotas: [quota], today: [], yesterday: [], last30: [], warning: nil))
    }

    private func map(_ windows: [YCodingQuotaWindow]) -> ProviderSnapshot {
        let quota = YCodingQuotaSnapshot(providerID: "openai", label: "Codex", profile: connection.profile,
            status: .available, source: .providerInternalAPI, stability: .bestEffort,
            updatedAt: 1_800_000_000_000, windows: windows, message: nil)
        return YCodingConnectionMapper.snapshot(for: connection, read: .init(connections: [connection],
            quotas: [quota], today: [], yesterday: [], last30: [], warning: nil))
    }

    private func window(_ id: String, period: Double?, used: Double) -> YCodingQuotaWindow {
        .init(id: id, label: "Upstream Window", group: nil, unit: .percent, used: used, limit: nil,
              remaining: nil, unlimited: nil, resetAt: reset.timeIntervalSince1970 * 1000, periodSeconds: period)
    }

    private func assertProgress(_ snapshot: ProviderSnapshot, _ label: String, used: Double, duration: Int?,
                                file: StaticString = #filePath, line: UInt = #line) {
        guard case .progress(_, let actualUsed, let limit, _, let actualReset, let actualDuration, _)
                = snapshot.line(label: label) else {
            return XCTFail("Expected quota row \(label)", file: file, line: line)
        }
        XCTAssertEqual(actualUsed, used, file: file, line: line)
        XCTAssertEqual(limit, 100, file: file, line: line)
        XCTAssertEqual(actualReset, reset, file: file, line: line)
        XCTAssertEqual(actualDuration, duration, file: file, line: line)
    }
}
