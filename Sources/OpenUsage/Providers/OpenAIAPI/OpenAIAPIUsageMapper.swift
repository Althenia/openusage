import Foundation

enum OpenAIAPIUsageMapper {
    static func lines(from report: OpenAIAPIMonthReport) -> [MetricLine] {
        [
            .values(label: "Completions Tokens", values: [
                MetricValue(number: report.tokens, kind: .count, label: "tokens")
            ]),
            .values(label: "Cost", values: [MetricValue(number: report.costUSD, kind: .dollars)])
        ]
    }
}
