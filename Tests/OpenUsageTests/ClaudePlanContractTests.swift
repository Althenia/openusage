import XCTest
@testable import OpenUsage

final class ClaudePlanContractTests: XCTestCase {
    func testStoredPayloadUsesCurrentIndividualPlanNames() throws {
        let cases: [(String, String?, String)] = [
            ("pro", "default_claude_pro", "Pro"),
            ("max", "default_claude_max_5x", "Max"),
            ("max", "default_claude_max_20x", "Ultra"),
            ("max", "claude_max_subscription_20x", "Ultra"),
            ("max", nil, "Max"),
            ("team", nil, "Team"),
            ("enterprise", nil, "Enterprise"),
            ("custom", "custom_7x", "Custom 7x"),
            ("max", "custom_200x", "Max 200x")
        ]
        for (subscription, tier, expected) in cases {
            var oauth: [String: Any] = ["subscriptionType": subscription]
            if let tier { oauth["rateLimitTier"] = tier }
            let data = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
            let credentials = try XCTUnwrap(ClaudeCredentialsFile(data: data)?.claudeAiOauth)
            let usage = try ClaudeUsageMapper.mapUsageResponse(response("{}"), credentials: credentials)
            XCTAssertEqual(usage.plan, expected, "\(subscription): \(tier ?? "missing")")
        }
        XCTAssertNil(ClaudeUsageMapper.formatPlan(subscriptionType: nil, rateLimitTier: "default_claude_max_20x"))
        XCTAssertNil(ClaudeUsageMapper.formatPlan(subscriptionType: "  ", rateLimitTier: nil))
    }

    func testLiveProfileUsesCurrentNamesWithoutMixingPlanFamilies() throws {
        let stored = ClaudeOAuth(subscriptionType: "max", rateLimitTier: "default_claude_max_20x")
        let cases: [(String, String)] = [
            (#"{"organization_type":"claude_max","rate_limit_tier":"default_claude_max_5x"}"#, "Max"),
            (#"{"organization_type":"claude_max","rate_limit_tier":"default_claude_max_20x"}"#, "Ultra"),
            (#"{"organization_type":"claude_pro"}"#, "Pro"),
            (#"{"rate_limit_tier":"default_claude_max_5x"}"#, "Max"),
            (#"{"organization_type":"claude_max"}"#, "Ultra")
        ]
        for (fields, expected) in cases {
            var organization = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fields.utf8)) as? [String: Any])
            organization["uuid"] = "synthetic-organization"
            let body = try JSONSerialization.data(withJSONObject: [
                "account": ["uuid": "synthetic-account"], "organization": organization
            ])
            let profile = try ClaudeUsageClient.decodeProfile(HTTPResponse(statusCode: 200, headers: [:], body: body))
            XCTAssertEqual(ClaudeUsageMapper.formatLivePlan(profile: profile, credentials: stored), expected)
        }
    }

    func testAbsentOrUnusableSessionPayloadNeverCreatesSessionForAnyPlan() throws {
        let sessionFields = ["", #""five_hour":null,"#, #""five_hour":{},"#, #""five_hour":{"utilization":null},"#,
                             #""five_hour":{"utilization":"unknown"},"#]
        for tier in ["default_claude_max_5x", "default_claude_max_20x"] {
            for sessionField in sessionFields {
                let usage = try ClaudeUsageMapper.mapUsageResponse(response("""
                {\(sessionField)"seven_day":{"utilization":31},
                 "limits":[{"kind":"weekly_scoped","percent":12,"scope":{"model":{"display_name":"Fable"}}}]}
                """), credentials: ClaudeOAuth(subscriptionType: "max", rateLimitTier: tier))
                XCTAssertEqual(usage.lines.map(\.label), ["Weekly", "Fable"], "\(tier): \(sessionField)")
            }
        }
    }

    func testUltraRetainsReportedTemporarySessionIncludingMeasuredZero() throws {
        for used in [0, 17] {
            let usage = try ClaudeUsageMapper.mapUsageResponse(response("""
            {"five_hour":{"utilization":\(used),"resets_at":"2099-01-01T00:00:00Z"},"seven_day":{"utilization":31}}
            """), credentials: ClaudeOAuth(subscriptionType: "max", rateLimitTier: "default_claude_max_20x"))
            XCTAssertEqual(usage.plan, "Ultra")
            guard case .progress(_, let value, _, _, let reset, let duration, _) = usage.lines.first else {
                return XCTFail("Expected the reported temporary session")
            }
            XCTAssertEqual(value, Double(used))
            XCTAssertNotNil(reset)
            XCTAssertEqual(duration, MetricPeriod.sessionMs)
        }
    }

    private func response(_ json: String) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
    }
}
