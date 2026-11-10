import XCTest
@testable import OpenUsage

@MainActor
final class YCodingAuthenticationMappingTests: XCTestCase {
    func testAccountAndAPIKeyCardsHaveDistinctQuotaSemanticsForBothProviders() {
        for integration in ["openai", "anthropic"] {
            let account = connection(integration, kind: .account)
            let key = connection(integration, kind: .apiKey)
            let accountSnapshot = map(account, status: .available)
            let keySnapshot = map(key, status: .available)

            XCTAssertNotNil(accountSnapshot.line(label: "Session"))
            XCTAssertEqual(accountSnapshot.plan, "YCoding · Account")
            XCTAssertNil(keySnapshot.line(label: "Session"), "A key never inherits a subscription quota")
            XCTAssertNil(keySnapshot.line(label: "Weekly"))
            XCTAssertEqual(keySnapshot.plan, "YCoding · API Key")
            XCTAssertNil(keySnapshot.warning)
            XCTAssertNotNil(keySnapshot.line(label: "Today"))
            XCTAssertFalse(YCodingConnectionMapper.descriptors(for: key).contains { ["Session", "Weekly"].contains($0.title) })
        }
    }

    func testUnknownTypeStaysExplicitEvenWithAvailableQuotaOrCreditNamedProfile() {
        for integration in ["openai", "anthropic"] {
            let unknown = connection(integration, kind: .unknown)
            let snapshot = map(unknown, status: .available)
            XCTAssertEqual(snapshot.plan, "YCoding · Type Unknown")
            XCTAssertTrue(snapshot.warning?.contains("Connection type is unknown") == true)
            XCTAssertNotNil(snapshot.line(label: "Session"), "Verified quota may still be reported without inferring auth kind")
        }
    }

    func testUnavailableQuotasDoNotInventCreditBalancesOrHideRealErrors() {
        for integration in ["openai", "anthropic"] {
            for kind in [YCodingConnection.Authentication.account, .apiKey, .unknown] {
                let profile = connection(integration, kind: kind)
                for status in [YCodingQuotaSnapshot.Status.unsupported, .unauthorized, .error] {
                    let snapshot = map(profile, status: status, withUsage: false)
                    XCTAssertNil(snapshot.line(label: "Session"))
                    XCTAssertNil(snapshot.line(label: "Weekly"))
                    XCTAssertEqual(snapshot.plan, profile.sourceLabel)
                    XCTAssertEqual(snapshot.errorCategory, .notAvailable)
                    guard case .badge(_, let message, _, _) = snapshot.lines.first else {
                        return XCTFail("Expected an unavailable-data notice")
                    }
                    if kind == .apiKey { XCTAssertFalse(message.contains("credit balance")) }
                    if kind == .unknown { XCTAssertTrue(message.contains("type is unknown")) }
                    if status == .error { XCTAssertTrue(message.contains("could not refresh")) }
                    if status == .unauthorized { XCTAssertTrue(message.contains("could not")) }
                    XCTAssertFalse(message.contains("synthetic-secret-marker"))
                }
            }
        }
    }

    func testAPIKeyCardsShowRecordedUsageAndReportingErrorsWithoutInventedBalanceRows() {
        for integration in ["openai", "anthropic"] {
            let key = connection(integration, kind: .apiKey)
            for status in [YCodingQuotaSnapshot.Status.unsupported, .unauthorized, .error, .available] {
                let snapshot = map(key, status: status)
                if status == .unauthorized || status == .error {
                    XCTAssertNotNil(snapshot.warning, "\(integration) \(status)")
                } else {
                    XCTAssertNil(snapshot.warning, "\(integration) \(status)")
                }
                XCTAssertNil(snapshot.errorCategory)
                XCTAssertNotNil(snapshot.line(label: "Today"))
                for label in ["Credits", "Rate Limit Resets", "Extra usage spent"] { XCTAssertNil(snapshot.line(label: label)) }
            }
            XCTAssertFalse(YCodingConnectionMapper.descriptors(for: key).contains {
                ["Extra Usage", "Rate Limit Resets"].contains($0.title)
            })
        }
    }

    func testOpenAIAdminShowsOrganizationUsageFailureAlongsideCreditAndRecordedUsage() {
        let key = connection("openai", kind: .apiKey)
        let snapshot = map(key, status: .available, message: "Organization usage unavailable")
        XCTAssertNotNil(snapshot.line(label: "Today"))
        XCTAssertNotNil(snapshot.line(label: "API Credit Balance"))
        XCTAssertTrue(snapshot.warning?.contains("organization usage") == true)
    }

    func testClaudeShowsReportingFailureAlongsideObservedQuotaAndRecordedUsage() {
        let account = connection("anthropic", kind: .account)
        let snapshot = map(account, status: .available, message: "Provider usage refresh failed")
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertNotNil(snapshot.line(label: "Today"))
        XCTAssertTrue(snapshot.warning?.contains("could not refresh") == true)
    }

    func testAccountQuotaFailuresStayVisible() {
        for integration in ["openai", "anthropic"] {
            let account = connection(integration, kind: .account)
            XCTAssertTrue(map(account, status: .unauthorized).warning?.contains("could not read quotas") == true)
            XCTAssertTrue(map(account, status: .error).warning?.contains("could not refresh") == true)
        }
    }

    func testChangedAuthKindDoesNotMatchCachedConnectionIdentity() {
        let account = connection("openai", kind: .account)
        let key = connection("openai", kind: .apiKey)
        XCTAssertNil(YCodingQuotaSnapshot.matching(account, connections: [key], snapshots: [quota(account, status: .available)]))
    }

    func testHiddenOrUnavailableQuotaCannotMakeFreshRecordedUsageStale() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        for kind in [YCodingConnection.Authentication.account, .apiKey, .unknown] {
            let connection = connection("openai", kind: kind)
            let usage = YCodingProfileUsage(providerID: "openai", profile: connection.profile, cost: 1,
                costProvenance: "recorded", costCoverage: .init(pricedRequests: 1, unpricedRequests: 0),
                tokens: .init(input: 1, output: 1, reasoning: 0, cache: .init(read: 0, write: 0)), physical: 1)
            for status in [YCodingQuotaSnapshot.Status.available, .unauthorized] {
                let result = YCodingConnectionMapper.snapshot(for: connection, read: .init(connections: [connection],
                    quotas: [quota(connection, status: status)], today: [usage], yesterday: [], last30: [], warning: nil), now: now)
                XCTAssertEqual(result.refreshedAt, kind == .apiKey || status == .unauthorized
                    ? now : Date(timeIntervalSince1970: 1_800_000_000))
            }
        }
    }

    private func connection(_ integration: String, kind: YCodingConnection.Authentication) -> YCodingConnection {
        .init(integrationID: integration, id: "same-id", profile: "Misleading Credit Name", active: true, authentication: kind)
    }

    private func quota(_ connection: YCodingConnection, status: YCodingQuotaSnapshot.Status, message: String = "synthetic-secret-marker") -> YCodingQuotaSnapshot {
        let balance: [YCodingQuotaWindow] = message == "Organization usage unavailable"
            ? [.init(id: "api-credit-balance", label: "API credit balance", group: nil, unit: .usd,
                     used: nil, limit: nil, remaining: 5, unlimited: nil, resetAt: nil, periodSeconds: nil)] : []
        return .init(providerID: connection.integrationID, label: "Fixture", profile: connection.profile, status: status,
              source: .providerInternalAPI, stability: .clientContract, updatedAt: 1_800_000_000_000,
              windows: [.init(id: connection.integrationID == "openai" ? "codex-primary" : "five-hour",
                              label: "Session", group: nil, unit: .percent, used: 100, limit: nil, remaining: nil,
                              unlimited: nil, resetAt: 1_800_003_600_000, periodSeconds: 18_000)] + balance,
              message: message)
    }

    private func map(_ connection: YCodingConnection, status: YCodingQuotaSnapshot.Status, withUsage: Bool = true,
                     message: String = "synthetic-secret-marker") -> ProviderSnapshot {
        let rows: [YCodingProfileUsage] = withUsage ? [.init(providerID: connection.integrationID, profile: connection.profile,
            cost: 4, costProvenance: "recorded", costCoverage: .init(pricedRequests: 1, unpricedRequests: 0),
            tokens: .init(input: 10, output: 5, reasoning: 0, cache: .init(read: 0, write: 0)), physical: 1)] : []
        return YCodingConnectionMapper.snapshot(for: connection, read: .init(connections: [connection],
            quotas: [quota(connection, status: status, message: message)], today: rows, yesterday: [], last30: [], warning: nil))
    }
}
