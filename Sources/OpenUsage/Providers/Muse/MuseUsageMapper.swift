import Foundation

enum MuseUsageMapper {
    static let weeklyPeriodMs = 7 * 24 * 60 * 60 * 1000

    static func map(eventStreamBody: Data) throws -> [MetricLine] {
        guard let text = String(data: eventStreamBody, encoding: .utf8) else {
            throw MuseUsageError.usageUnavailable
        }
        var eventName: String?
        var dataLines: [String] = []
        var mapped: [MetricLine]?

        func consume() throws {
            guard eventName == "response.subscription_usage" else {
                eventName = nil
                dataLines.removeAll(keepingCapacity: true)
                return
            }
            guard !dataLines.isEmpty else { throw MuseUsageError.usageUnavailable }
            let payload = dataLines.joined(separator: "\n")
            mapped = try subscriptionLines(Data(payload.utf8))
            eventName = nil
            dataLines.removeAll(keepingCapacity: true)
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let line = line.hasSuffix("\r") ? String(line.dropLast()) : line
            if line.isEmpty {
                try consume()
            } else if line.hasPrefix("event:") {
                eventName = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces))
            }
        }
        try consume()
        guard let mapped else { throw MuseUsageError.usageUnavailable }
        return mapped
    }

    private static func subscriptionLines(_ data: Data) throws -> [MetricLine] {
        guard let root = ProviderParse.jsonObject(data),
              root["type"] as? String == "response.subscription_usage",
              let subscription = root["subscription"] as? [String: Any],
              let window = subscription["window"] as? [String: Any],
              let weekly = subscription["weekly"] as? [String: Any],
              let windowUsed = percent(window["used_percent"]),
              let weeklyUsed = percent(weekly["used_percent"]),
              let windowReset = resetDate(window["resets_at"]),
              let weeklyReset = resetDate(weekly["resets_at"]),
              let duration = positiveInteger(window["window_duration_mins"]),
              duration <= Int.max / 60_000
        else { throw MuseUsageError.usageUnavailable }

        return [
            .progress(
                label: "Session",
                used: windowUsed,
                limit: 100,
                format: .percent,
                resetsAt: windowReset,
                periodDurationMs: duration * 60_000
            ),
            .progress(
                label: "Weekly",
                used: weeklyUsed,
                limit: 100,
                format: .percent,
                resetsAt: weeklyReset,
                periodDurationMs: weeklyPeriodMs
            )
        ]
    }

    private static func percent(_ value: Any?) -> Double? {
        guard let value = ProviderParse.number(value), value >= 0, value.rounded(.towardZero) == value else {
            return nil
        }
        return value
    }

    private static func resetDate(_ value: Any?) -> Date? {
        guard let seconds = ProviderParse.number(value) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func positiveInteger(_ value: Any?) -> Int? {
        guard let number = ProviderParse.number(value), number > 0,
              number.rounded(.towardZero) == number,
              number < Double(Int.max)
        else { return nil }
        return Int(number)
    }
}
