import XCTest
@testable import OpenUsage

final class CodexSparkRetirementTests: XCTestCase {
    @MainActor
    func testDescriptorsExcludeSparkForDefaultAndAdditionalAccountCards() {
        for id in ["codex", "codex-synthetic-account"] {
            let provider = CodexProvider.isolated(
                provider: CodexProvider.makeProvider(id: id),
                authStore: CodexAuthStore(environment: FakeEnvironment(), files: FakeFiles(), keychain: FakeKeychain())
            )
            let ids = provider.widgetDescriptors.map(\.id)
            XCTAssertFalse(ids.contains(id + ".spark"))
            XCTAssertFalse(ids.contains(id + ".sparkWeekly"))
            XCTAssertTrue(ids.contains(id + ".session"))
            XCTAssertTrue(ids.contains(id + ".weekly"))
            XCTAssertTrue(ids.contains(id + ".rateLimitResets"))
        }
    }

    func testHistoricalSparkModelTokensAndPricingRemainAvailable() throws {
        let model = "gpt-5.3-codex-spark"
        let log = [
            CodexLogFixture.turnContext(timestamp: "2026-05-12T08:00:00Z", model: model),
            CodexLogFixture.tokenCount(timestamp: "2026-05-12T08:01:00Z",
                                       last: CodexLogFixture.usage(input: 100, output: 50))
        ].joined(separator: "\n")
        let events = CodexLogUsageScanner.parseFile(Data(log.utf8))
        XCTAssertEqual(events.map(\.model), [model])
        let pricing = ModelPricing(supplement: PricingSupplement(), primary: PricingCatalog(entries: [
            model: ModelRates(inputPerMillion: 2, outputPerMillion: 3, cacheWritePerMillion: 2, cacheReadPerMillion: 0.2)
        ]), secondary: PricingCatalog(entries: [:]))
        let scan = CodexLogUsageScanner.aggregate(events: events, since: .distantPast, pricing: pricing)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 150)
        XCTAssertEqual(try XCTUnwrap(scan.series.daily.first?.costUSD), 0.00035, accuracy: 0.0000001)
        XCTAssertEqual(scan.modelUsage?.daily.first?.models.first?.model, model)
        XCTAssertTrue(scan.unknownModelsByDay.isEmpty)
    }
}
