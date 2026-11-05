import Foundation

enum YCodingConnectionMapper {
    static let usageSourceNote = "From your YCoding usage report"

    struct Slot {
        let suffix: String
        let title: String
        let windowIDs: Set<String>
    }

    static func slots(for integration: String) -> [Slot] {
        switch integration {
        case "openai":
            return [.init(suffix: "session", title: "Session", windowIDs: ["codex-primary"]),
                    .init(suffix: "weekly", title: "Weekly", windowIDs: ["codex-secondary"])]
        case "anthropic":
            return [.init(suffix: "session", title: "Session", windowIDs: ["five-hour"]),
                    .init(suffix: "weekly", title: "Weekly", windowIDs: ["seven-day"]),
                    .init(suffix: "fable", title: "Fable", windowIDs: ["seven-day-fable"]),
                    .init(suffix: "sonnet", title: "Sonnet", windowIDs: ["seven-day-sonnet"])]
        case "cursor":
            return [.init(suffix: "usage", title: "Total Usage", windowIDs: ["included"]),
                    .init(suffix: "auto", title: "Cursor Models", windowIDs: ["auto"]),
                    .init(suffix: "api", title: "Other Models", windowIDs: ["api"])]
        case "muse":
            return [.init(suffix: "session", title: "Session", windowIDs: ["window"]),
                    .init(suffix: "weekly", title: "Weekly", windowIDs: ["weekly"])]
        case "antigravity":
            return [.init(suffix: "geminiPro", title: "Session", windowIDs: ["five-hour", "Gemini/five-hour", "Gemini Models/five-hour"]),
                    .init(suffix: "geminiWeekly", title: "Weekly", windowIDs: ["weekly", "Gemini/weekly", "Gemini Models/weekly"]),
                    .init(suffix: "claude", title: "Claude", windowIDs: ["Claude/five-hour", "Claude and GPT models/five-hour"]),
                    .init(suffix: "claudeWeekly", title: "Claude Weekly", windowIDs: ["Claude/weekly", "Claude and GPT models/weekly"]),
                    .init(suffix: "argonWeekly", title: "Argon Weekly", windowIDs: ["Argon/weekly"])]
        default: return []
        }
    }

    @MainActor
    static func descriptors(for connection: YCodingConnection) -> [WidgetDescriptor] {
        let provider = connection.provider
        let quotas = (connection.showsSubscriptionQuotas ? slots(for: connection.integrationID) : []).map { slot in
            WidgetDescriptor.percent(id: "\(provider.id).\(slot.suffix)", provider: provider, title: slot.title)
                .exportingLimit(slot.suffix, unit: "percent")
        }
        let trend = WidgetDescriptor.usageTrend(provider: provider)
            .exportingHistory(
                scope: .machineLocal,
                estimatedCost: true,
                sourceNote: usageSourceNote
            )
        let spend = WidgetDescriptor.spendTiles(
            provider: provider,
            valueTooltipNote: "Recorded or estimated model usage value, not a credit balance, billed charge, or subscription allowance."
        ).map {
            var sample = $0.sample
            sample.dollarLabelAsSubtitle = true
            return WidgetDescriptor(
                id: $0.id,
                providerID: $0.providerID,
                metricLabel: $0.metricLabel,
                sample: sample,
                pinnable: $0.pinnable,
                isSpendTile: $0.isSpendTile,
                limitResources: $0.limitResources,
                historyResource: $0.historyResource
            )
        }
        return quotas + [trend] + spend
    }

    static func snapshot(for connection: YCodingConnection, read: YCodingConnectionRead, now: Date = Date()) -> ProviderSnapshot {
        let quota = YCodingQuotaSnapshot.matching(connection, connections: read.connections, snapshots: read.quotas)
        var lines: [MetricLine] = []
        var warnings: [String] = read.warning.map { [$0] } ?? []
        if connection.showsSubscriptionQuotas, let quota, quota.status == .available || quota.status == .stale {
            let slots = slots(for: connection.integrationID)
            for slot in slots {
                let matches = quota.windows.filter {
                    matches($0, slot: slot, integration: connection.integrationID)
                }
                // Multiple matching pools never get silently summed or selected by response order.
                guard matches.count == 1, let window = matches.first, let used = window.used else { continue }
                let duration = window.periodSeconds.flatMap {
                    $0 > 0 && $0 < Double(Int.max / 1000) ? Int($0 * 1000) : nil
                }
                lines.append(.progress(label: slot.title, used: used, limit: 100, format: .percent,
                                       resetsAt: window.resetAt.map { Date(timeIntervalSince1970: $0 / 1000) },
                                       periodDurationMs: duration))
            }
            if quota.status == .stale { warnings.append("YCoding reports stale quotas. Refresh YCoding and try again.") }
            if lines.isEmpty { warnings.append("YCoding has no compatible quota meters for this profile.") }
        } else if connection.showsSubscriptionQuotas {
            switch quota?.status {
            case .unauthorized:
                warnings.append("YCoding could not read quotas for this connection. Check it in YCoding; ordinary API keys may not provide quotas.")
            case .error:
                warnings.append("YCoding could not refresh this profile's quotas.")
            default:
                warnings.append("YCoding has no profile-bound quotas for this connection. Recorded usage is shown when available.")
            }
        }
        if connection.distinguishesAccountAndKey {
            switch connection.authentication {
            case .apiKey:
                if quota?.status == .unauthorized {
                    warnings.append("YCoding could not authorize quota reporting for this API-key connection.")
                } else if quota?.status == .error {
                    warnings.append("YCoding could not refresh this API-key connection's usage status.")
                }
                warnings.append("API-key connection. YCoding does not report its remaining credit balance. Recorded usage value is shown when available.")
            case .unknown:
                warnings.append("Connection type is unknown. YCoding did not provide a recognized account/API-key type.")
            case .account: break
            }
        }
        let displaysQuota = !lines.isEmpty
        let matching: ([YCodingProfileUsage]) -> YCodingProfileUsage? = { rows in
            let matches = rows.filter { $0.providerID == connection.integrationID && $0.profile == connection.profile }
            return matches.count == 1 ? matches[0] : nil
        }
        for (label, rows) in [("Today", read.today), ("Yesterday", read.yesterday), ("Last 30 Days", read.last30)] {
            guard let usage = matching(rows), usage.physical > 0 else { continue }
            var values: [MetricValue] = []
            if let cost = usage.cost {
                let estimated = usage.usesOpenUsagePricing || usage.costProvenance == "current_catalog"
                let qualifier = usage.hasIncompleteCost ? "partial " : ""
                values.append(.init(number: cost, kind: .dollars,
                                    label: qualifier + (estimated ? "estimated usage value" : "recorded usage value"), estimated: estimated))
            }
            let tokens = usage.tokens
            let total = tokens.input + tokens.output + tokens.reasoning + tokens.cache.read + tokens.cache.write
            values.append(.init(number: total, kind: .count, label: "tokens"))
            let totalTokens = Int(min(max(total.rounded(), 0), 1_000_000_000_000_000))
            let breakdown = makeModelBreakdown(for: usage, totalTokens: totalTokens)
            lines.append(.values(label: label, values: values, modelBreakdown: breakdown))
            if usage.hasIncompleteCost {
                warnings.append("Some recorded YCoding usage cannot be priced reliably; its usage value is incomplete.")
            }
        }
        let dailySeries = read.dailyByProfile[[connection.integrationID, connection.profile]]
            ?? fallbackDailySeries(today: matching(read.today), yesterday: matching(read.yesterday), now: now)
        SpendTileMapper.appendUsageTrend(dailySeries, to: &lines, now: now, note: usageSourceNote)
        if connection.integrationID == "muse", let usage = matching(read.last30), usage.physical > 0 {
            warnings.append("YCoding recorded \(usage.physical) requests for this profile in the last 30 days.")
        }
        // Upstream free-form error messages are intentionally never forwarded to the UI or logs.
        var seen = Set<String>()
        let warning = warnings.filter { seen.insert($0).inserted }.joined(separator: " ").nilIfEmpty
        if lines.isEmpty {
            let message = warning ?? "YCoding has no usage for this profile yet."
            AppLog.warn("plugin:ycoding", message)
            var error = ProviderSnapshot.error(provider: connection.provider, message: message, category: .notAvailable)
            error.plan = connection.sourceLabel
            return error
        }
        if warning != nil { AppLog.warn("plugin:ycoding", "YCoding profile usage is partially available") }
        return .make(provider: connection.provider, plan: connection.sourceLabel, lines: lines,
                     refreshedAt: displaysQuota ? quota.map { Date(timeIntervalSince1970: $0.updatedAt / 1000) } ?? now : now,
                     warning: warning)
    }

    private static func makeModelBreakdown(for usage: YCodingProfileUsage, totalTokens: Int) -> ModelUsageBreakdown? {
        let filtered = usage.models.compactMap { entry -> ModelUsageEntry? in
            guard entry.totalTokens > 0 || (entry.costUSD ?? 0) > 0 else { return nil }
            var rounded = entry
            rounded.costUSD = entry.costUSD.map { ($0 * 100).rounded() / 100 }
            return rounded
        }
        let sortedModels = filtered.sorted { lhs, rhs in
            let lhsCost = lhs.costUSD ?? 0
            let rhsCost = rhs.costUSD ?? 0
            if lhsCost != rhsCost { return lhsCost > rhsCost }
            if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
            return lhs.model.localizedStandardCompare(rhs.model) == .orderedAscending
        }
        guard !sortedModels.isEmpty else { return nil }
        return ModelUsageBreakdown(
            totalTokens: totalTokens,
            totalCostUSD: usage.cost,
            models: sortedModels,
            sourceNote: usageSourceNote
        )
    }

    private static func fallbackDailySeries(
        today: YCodingProfileUsage?,
        yesterday: YCodingProfileUsage?,
        now: Date
    ) -> DailyUsageSeries {
        var daily: [DailyUsageEntry] = []
        if let yesterday {
            let tokens = yesterday.tokens
            let total = tokens.input + tokens.output + tokens.reasoning + tokens.cache.read + tokens.cache.write
            let tokenCount = Int(min(max(total.rounded(), 0), 1_000_000_000_000_000))
            if (yesterday.physical > 0 || tokenCount > 0 || (yesterday.cost ?? 0) > 0),
               let dayKey = Calendar.current.date(byAdding: .day, value: -1, to: now).map({ DailyUsageAccumulator.dayKey(from: $0) }) {
                daily.append(DailyUsageEntry(date: dayKey, totalTokens: tokenCount, costUSD: yesterday.cost))
            }
        }
        if let today {
            let tokens = today.tokens
            let total = tokens.input + tokens.output + tokens.reasoning + tokens.cache.read + tokens.cache.write
            let tokenCount = Int(min(max(total.rounded(), 0), 1_000_000_000_000_000))
            if today.physical > 0 || tokenCount > 0 || (today.cost ?? 0) > 0 {
                let dayKey = DailyUsageAccumulator.dayKey(from: now)
                daily.append(DailyUsageEntry(date: dayKey, totalTokens: tokenCount, costUSD: today.cost))
            }
        }
        return DailyUsageSeries(daily: daily)
    }

    private static func matches(_ window: YCodingQuotaWindow, slot: Slot, integration: String) -> Bool {
        guard window.unit == .percent else { return false }
        guard integration == "openai" else { return slot.windowIDs.contains(window.id) }
        guard ["codex-primary", "codex-secondary"].contains(window.id) else { return false }
        // Primary/secondary indicate response positions, not reset periods. A sole weekly
        // Codex allowance can occupy the primary slot. Never turn its seven-day reset into
        // a Session meter, or guess a familiar period from an unfamiliar explicit duration.
        switch window.periodSeconds {
        case 18_000: return slot.suffix == "session"
        case 604_800: return slot.suffix == "weekly"
        default: return false
        }
    }
}
