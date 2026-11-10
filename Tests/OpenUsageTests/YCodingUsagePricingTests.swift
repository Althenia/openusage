import XCTest
@testable import OpenUsage

@MainActor
final class YCodingUsagePricingTests: XCTestCase {
    private let rates = ModelRates(inputPerMillion: 2, outputPerMillion: 10,
                                   cacheWritePerMillion: 2.5, cacheReadPerMillion: 0.2)

    private func pricing(_ rates: ModelRates? = nil) -> ModelPricing {
        .init(supplement: .init(), primary: .init(entries: ["fixture-model": rates ?? self.rates]), secondary: .init())
    }

    private func row(provider: String = "anthropic", profile: String = "Work", model: String? = "fixture-model",
                     cost: Double? = nil, priced: Int = 0, unpriced: Int = 1, physical: Int = 1,
                     input: Double = 100, output: Double = 20, reasoning: Double = 5,
                     read: Double = 40, write: Double = 0) -> YCodingModelUsage {
        .init(modelID: model,
              usage: .init(providerID: provider, profile: profile, cost: cost,
                           costProvenance: cost == nil ? nil : "recorded",
                           costCoverage: .init(pricedRequests: priced, unpricedRequests: unpriced),
                           tokens: .init(input: input, output: output, reasoning: reasoning,
                                         cache: .init(read: read, write: write)), physical: physical))
    }

    func testFullyPricedAndRecordedZeroRemainAuthoritative() throws {
        for amount in [0.0, 4.5] {
            let source = row(cost: amount, priced: 1, unpriced: 0)
            XCTAssertFalse(YCodingUsagePricing.needsPricing([source]))
            let result = try XCTUnwrap(YCodingUsagePricing.aggregate([source], pricing: pricing()).first)
            XCTAssertEqual(result.cost, amount)
            XCTAssertEqual(result.costProvenance, "recorded")
            XCTAssertFalse(result.usesOpenUsagePricing)
            XCTAssertFalse(result.hasIncompleteCost)
        }
    }

    func testUnpricedKnownModelCountsEachTokenCategoryOnceForEveryProvider() throws {
        for provider in ["openai", "anthropic", "antigravity", "muse", "cursor"] {
            let result = try XCTUnwrap(YCodingUsagePricing.aggregate([row(provider: provider)], pricing: pricing()).first)
            // 100 uncached input + 40 cached input + (20 text + 5 reasoning) output.
            XCTAssertEqual(try XCTUnwrap(result.cost), 0.000458, accuracy: 1e-12)
            XCTAssertTrue(result.usesOpenUsagePricing)
            XCTAssertEqual(result.estimatedRequests, 1)
            XCTAssertFalse(result.hasIncompleteCost)
        }
    }

    func testMissingModelRateOrTokenCategoryNeverBecomesZeroCost() throws {
        let sources = [row(model: nil), row(model: "unknown-model"), row(input: -1), row(input: 1.5)]
        for source in sources {
            let result = try XCTUnwrap(YCodingUsagePricing.aggregate([source], pricing: pricing()).first)
            XCTAssertNil(result.cost)
            XCTAssertTrue(result.hasIncompleteCost)
            XCTAssertEqual(result.estimatedRequests, 0)
        }
    }

    func testMixedRecordedAndEstimatedModelsKeepTheirProvenanceAndProfileTotals() throws {
        let sources = [row(model: "already-priced", cost: 2, priced: 1, unpriced: 0), row(),
                       row(profile: "Personal", cost: 9, priced: 1, unpriced: 0),
                       row(provider: "openai", cost: 7, priced: 1, unpriced: 0)]
        let results = try YCodingUsagePricing.aggregate(sources, pricing: pricing())
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(try XCTUnwrap(results[0].cost), 2.000458, accuracy: 1e-12)
        XCTAssertEqual(results[0].physical, 2)
        XCTAssertEqual(results[0].estimatedRequests, 1)
        XCTAssertFalse(results[0].hasIncompleteCost)
        XCTAssertTrue(results[0].usesOpenUsagePricing)
        XCTAssertEqual(results[1].cost, 9)
        XCTAssertEqual(results[2].cost, 7)
        XCTAssertFalse(results[1].usesOpenUsagePricing)
        XCTAssertFalse(results[2].usesOpenUsagePricing)
    }

    func testMixedPricedAndUnpricedGroupIsEstimatedOnceFromAllItsTokens() throws {
        let mixed = row(cost: 2, priced: 1, unpriced: 1, physical: 2)
        XCTAssertTrue(YCodingUsagePricing.needsPricing([mixed]))
        let result = try XCTUnwrap(YCodingUsagePricing.aggregate([mixed], pricing: pricing()).first)
        XCTAssertEqual(try XCTUnwrap(result.cost), 0.000458, accuracy: 1e-12)
        XCTAssertNil(result.costProvenance)
        XCTAssertEqual(result.estimatedRequests, 2)
        XCTAssertTrue(result.usesOpenUsagePricing)
        XCTAssertFalse(result.hasIncompleteCost)
        XCTAssertEqual(result.estimatedModels, ["fixture-model"])
    }

    func testMixedGroupWithUnknownModelKeepsRecordedSubtotalAsPartial() throws {
        let result = try XCTUnwrap(YCodingUsagePricing.aggregate(
            [row(model: "unknown-model", cost: 2, priced: 1, unpriced: 1, physical: 2)], pricing: pricing()).first)
        XCTAssertEqual(result.cost, 2)
        XCTAssertEqual(result.costProvenance, "recorded")
        XCTAssertFalse(result.usesOpenUsagePricing)
        XCTAssertTrue(result.hasIncompleteCost)
        XCTAssertTrue(result.estimatedModels.isEmpty)
    }

    func testCacheWritesArePricedAsFiveMinuteWritesWhenCacheReadIsUnreported() throws {
        let estimate = try XCTUnwrap(YCodingUsagePricing.estimate(row(write: 10), pricing: pricing()))
        // 100 input × 2 + 10 write × 2.5 + 40 read × 0.2 + 25 output × 10, per million.
        XCTAssertEqual(estimate, 0.000483, accuracy: 1e-12)
        let unreportedReads = try XCTUnwrap(YCodingUsagePricing.estimate(row(read: 0, write: 10), pricing: pricing()))
        XCTAssertEqual(unreportedReads, 0.000475, accuracy: 1e-12)
    }

    func testUnreportedCacheReadsArePricedAsInputWithoutMarkingThePeriodPartial() throws {
        for reported in [false, nil] as [Bool?] {
            var source = row()
            source.cacheReadReported = reported
            let result = try XCTUnwrap(YCodingUsagePricing.aggregate([source], pricing: pricing()).first)
            XCTAssertEqual(try XCTUnwrap(result.cost), 0.000458, accuracy: 1e-12,
                           "Input that includes unreported cached reads is priced at the input rate, an upper bound")
            XCTAssertTrue(result.usesOpenUsagePricing)
            XCTAssertFalse(result.hasIncompleteCost)
        }
    }

    func testYCodingModelIDsResolveOnlyThroughExistingCatalogEntriesAndAliases() {
        for model in ["claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5-5",
                      "gemini-3.8-flash", "gemini-3.8-flash-high", "muse-spark-1.3", "gpt-6.1-sol", "gpt-6-luna"] {
            XCTAssertNotNil(YCodingUsagePricing.estimate(row(model: model, write: 10), pricing: TestPricing.bundled), model)
        }
        XCTAssertEqual(TestPricing.bundled.resolve(model: "claude-fable-5-1"), TestPricing.bundled.resolve(model: "claude-fable-5.1"))
        for model in ["muse-wonder-full-1.0-contributor", "muse-spark-1.3-contributor", "gemini-4-argon", "made-up-model"] {
            XCTAssertNil(YCodingUsagePricing.estimate(row(model: model), pricing: TestPricing.bundled), model)
        }
    }

    func testPartiallyEstimatedProfileRetainsIncompleteWarning() throws {
        let result = try XCTUnwrap(YCodingUsagePricing.aggregate([row(), row(model: "unknown")], pricing: pricing()).first)
        XCTAssertEqual(try XCTUnwrap(result.cost), 0.000458, accuracy: 1e-12)
        XCTAssertEqual(result.estimatedRequests, 1)
        XCTAssertTrue(result.hasIncompleteCost)
    }

    func testPartialValueIsMarkedOnItsOwnPeriod() throws {
        let connection = YCodingConnection(integrationID: "anthropic", id: "fixture", profile: "Work", active: true)
        let rows = try YCodingUsagePricing.aggregate([row(), row(model: "unknown")], pricing: pricing())
        let result = YCodingConnectionMapper.snapshot(for: connection, read: .init(connections: [connection],
            quotas: [], today: rows, yesterday: [], last30: [], warning: nil))
        guard case .values(_, let values, _, _, _, _) = result.line(label: "Today") else { return XCTFail("Expected value") }
        XCTAssertEqual(values.first?.label, "partial estimated usage value")
        XCTAssertFalse(result.warning?.contains("incomplete") == true, "An incomplete subtotal is marked on its row only")
        XCTAssertFalse(result.warning?.contains("partial") == true)
    }

    func testCacheDiscountMustBeExplicitAndLongContextBoundariesMustBeKnown() throws {
        var assumedDiscount = rates
        assumedDiscount.cacheReadIsExplicit = false
        XCTAssertNil(YCodingUsagePricing.estimate(row(), pricing: pricing(assumedDiscount)))
        XCTAssertNotNil(YCodingUsagePricing.estimate(row(read: 0), pricing: pricing(assumedDiscount)))
        var tiered = rates
        tiered.inputAbove200kPerMillion = 4
        XCTAssertNil(YCodingUsagePricing.estimate(
            row(unpriced: 2, physical: 2, input: 300_000), pricing: pricing(tiered)))
        XCTAssertNotNil(YCodingUsagePricing.estimate(
            row(unpriced: 2, physical: 2, input: 100_000), pricing: pricing(tiered)))
        XCTAssertEqual(try XCTUnwrap(YCodingUsagePricing.estimate(row(input: 300_000), pricing: pricing(tiered))),
                       1.200258, accuracy: 1e-12)
    }

    func testEstimatedUsageValueIsLabeledAndExcludedFromSpendForAllProfiles() throws {
        for provider in ["openai", "anthropic", "antigravity", "muse", "cursor"] {
            let connection = YCodingConnection(integrationID: provider, id: "fixture", profile: "Work", active: true)
            let rows = try YCodingUsagePricing.aggregate([row(provider: provider)], pricing: pricing())
            let result = try XCTUnwrap(rows.first)
            XCTAssertTrue(
                result.models.contains(ModelUsageEntry(model: "fixture-model", totalTokens: 165, costUSD: 0.000458)) ||
                result.models.contains { $0.model == "fixture-model" && $0.totalTokens == 165 && abs(($0.costUSD ?? 0) - 0.000458) < 1e-12 }
            )
            let entry = try XCTUnwrap(result.models.first)
            XCTAssertEqual(entry.model, "fixture-model")
            XCTAssertEqual(entry.totalTokens, 165)
            XCTAssertEqual(try XCTUnwrap(entry.costUSD), 0.000458, accuracy: 1e-12)

            let snapshot = YCodingConnectionMapper.snapshot(for: connection, read: .init(connections: [connection],
                quotas: [], today: rows, yesterday: [], last30: [], warning: nil))
            guard case .values(_, let values, _, _, _, _) = snapshot.line(label: "Today") else { return XCTFail("Expected usage value") }
            XCTAssertEqual(values.first?.label, "estimated usage value")
            XCTAssertTrue(values.first?.estimated == true)
            XCTAssertFalse(snapshot.warning?.contains("incomplete") == true)
            let descriptors = YCodingConnectionMapper.descriptors(for: connection)
            XCTAssertTrue(descriptors.contains(where: \.isSpendTile))
            XCTAssertTrue(descriptors.contains { $0.id == "\(connection.cardID).trend" })
            XCTAssertTrue(descriptors.contains { $0.title == "Last 30 Days" })
        }
    }
}
