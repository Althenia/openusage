import XCTest
@testable import OpenUsage

@MainActor
final class YCodingQuotaMappingTests: XCTestCase {
    private let connection = YCodingConnection(integrationID: "openai", id: "account", profile: "Account", active: true,
                                               authentication: .account)
    private let reset = Date(timeIntervalSince1970: 1_800_200_000)

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
