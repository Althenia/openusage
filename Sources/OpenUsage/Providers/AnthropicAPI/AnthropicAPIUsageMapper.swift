import Foundation

enum AnthropicAPIUsageMapper {
    static func usageLine(_ report: AnthropicAPIReport) -> MetricLine {
        .values(label: "Usage", values: [MetricValue(number: report.value, kind: .count, label: "tokens")])
    }

    static func costLine(_ report: AnthropicAPIReport) -> MetricLine {
        .values(label: "Cost", values: [MetricValue(number: report.value, kind: .dollars)])
    }
}
