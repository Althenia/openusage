import Foundation

struct YCodingModelUsage: Sendable {
    let modelID: String?
    var cacheReadReported: Bool? = true
    let usage: YCodingProfileUsage
}

/// YCoding records token counts per request but prices only some of them. Any model group with
/// unpriced requests is valued from all of its tokens through the shared pricing engine, replacing
/// a partial recorded subtotal, so the same tokens are never counted twice. When `cacheReadReported`
/// is false, `tokens.input` includes cached reads YCoding could not break out; they are priced at the
/// input rate, so the estimate is an upper bound. A mixed model-day in the Usage Trend likewise
/// replaces that model's recorded day subtotal with this estimate, and days with models that cannot
/// be priced are understated without a per-day partial marker.
enum YCodingUsagePricing {
    static func needsPricing(_ rows: [YCodingModelUsage]) -> Bool {
        rows.contains { eligibleTokens($0) != nil }
    }

    static func aggregate(_ rows: [YCodingModelUsage], pricing: ModelPricing) throws -> [YCodingProfileUsage] {
        var order: [[String]] = []
        var totals: [[String]: YCodingProfileUsage] = [:]
        for row in rows {
            var usage = priced(row, pricing: pricing)
            let totalTokens = usage.tokens.input + usage.tokens.output + usage.tokens.reasoning + usage.tokens.cache.read + usage.tokens.cache.write
            if usage.physical > 0 {
                let modelName = row.modelID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? ModelUsageEntry.unattributedModelName
                let tokenCount = Int(min(max(totalTokens.rounded(), 0), 1_000_000_000_000_000))
                if tokenCount > 0 || (usage.cost ?? 0) > 0 {
                    usage.models = [ModelUsageEntry(model: modelName, totalTokens: tokenCount, costUSD: usage.cost)]
                }
            }
            let key = [usage.providerID, usage.profile]
            if let prior = totals[key] {
                totals[key] = try merge(prior, usage)
            } else {
                order.append(key)
                totals[key] = usage
            }
        }
        return order.compactMap { totals[$0] }
    }

    static func priced(_ row: YCodingModelUsage, pricing: ModelPricing) -> YCodingProfileUsage {
        let usage = row.usage
        guard let estimate = estimate(row, pricing: pricing), let model = row.modelID else { return usage }
        return .init(providerID: usage.providerID, profile: usage.profile, cost: estimate, costProvenance: nil,
                     costCoverage: .init(pricedRequests: usage.physical, unpricedRequests: 0), tokens: usage.tokens,
                     physical: usage.physical, estimatedRequests: usage.physical, usesOpenUsagePricing: true,
                     estimatedModels: [model])
    }

    static func estimate(_ row: YCodingModelUsage, pricing: ModelPricing) -> Double? {
        guard let tokens = eligibleTokens(row), let model = row.modelID,
              let rates = pricing.resolve(model: model) else { return nil }
        guard tokens.cacheRead == 0 || rates.cacheReadIsExplicit else { return nil }
        let tiered = [rates.inputAbove200kPerMillion, rates.outputAbove200kPerMillion,
                      rates.cacheReadAbove200kPerMillion, rates.cacheWriteAbove200kPerMillion].contains { $0 != nil }
        guard row.usage.physical == 1 || !tiered || tokens.promptTokens <= rates.longContextThresholdTokens else { return nil }
        guard let value = pricing.estimatedCostDollars(model: model, tokens: tokens,
                                                      applyLongContextRates: row.usage.physical == 1),
              value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func eligibleTokens(_ row: YCodingModelUsage) -> TokenBreakdown? {
        let usage = row.usage
        guard usage.physical > 0, usage.cost == nil || (usage.costCoverage?.unpricedRequests ?? 0) > 0,
              let model = row.modelID, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let tokens = usage.tokens
        let values = [tokens.input, tokens.output, tokens.reasoning, tokens.cache.read, tokens.cache.write]
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1_000_000_000_000_000 && Int(exactly: $0) != nil }) else { return nil }
        return TokenBreakdown(input: Int(tokens.input), cacheWrite5m: Int(tokens.cache.write),
                              cacheRead: Int(tokens.cache.read), output: Int(tokens.output) + Int(tokens.reasoning))
    }

    private static func merge(_ lhs: YCodingProfileUsage, _ rhs: YCodingProfileUsage) throws -> YCodingProfileUsage {
        func count(_ a: Int, _ b: Int) throws -> Int {
            let (sum, overflow) = a.addingReportingOverflow(b)
            guard !overflow else { throw YCodingConnectionClientError.malformedResponse }
            return sum
        }
        func number(_ a: Double, _ b: Double) throws -> Double {
            let sum = a + b
            guard sum.isFinite else { throw YCodingConnectionClientError.malformedResponse }
            return sum
        }
        let cost = lhs.cost == nil && rhs.cost == nil ? nil : try number(lhs.cost ?? 0, rhs.cost ?? 0)
        let coverage: YCodingCostCoverage?
        if let left = lhs.costCoverage, let right = rhs.costCoverage {
            coverage = .init(pricedRequests: try count(left.pricedRequests, right.pricedRequests),
                             unpricedRequests: try count(left.unpricedRequests, right.unpricedRequests))
        } else { coverage = nil }
        let provenance = [lhs.costProvenance, rhs.costProvenance].contains("current_catalog")
            ? "current_catalog" : (lhs.costProvenance ?? rhs.costProvenance)
        return .init(providerID: lhs.providerID, profile: lhs.profile, cost: cost, costProvenance: provenance,
                     costCoverage: coverage,
                     tokens: .init(input: try number(lhs.tokens.input, rhs.tokens.input),
                                   output: try number(lhs.tokens.output, rhs.tokens.output),
                                   reasoning: try number(lhs.tokens.reasoning, rhs.tokens.reasoning),
                                   cache: .init(read: try number(lhs.tokens.cache.read, rhs.tokens.cache.read),
                                                write: try number(lhs.tokens.cache.write, rhs.tokens.cache.write))),
                     physical: try count(lhs.physical, rhs.physical),
                     estimatedRequests: try count(lhs.estimatedRequests, rhs.estimatedRequests),
                     usesOpenUsagePricing: lhs.usesOpenUsagePricing || rhs.usesOpenUsagePricing,
                     models: lhs.models + rhs.models,
                     estimatedModels: lhs.estimatedModels + rhs.estimatedModels)
    }
}
