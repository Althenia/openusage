import XCTest
@testable import OpenUsage

/// Direct pins for the shared accumulate-then-assemble contract behind the Claude/Codex/Grok scanners
/// (the class of drift behind the ccusage false-zero fix): one `dayKey` spelling, newest-first day
/// order, per-model accumulation, always-priced days, and unknown models isolated from the series.
final class DailyUsageAccumulatorTests: XCTestCase {
    func testDayKeyUsesInjectedTimeZoneAndZeroPads() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // 2024-03-07 23:30 UTC — pads month and day to two digits.
        let date = calendar.date(from: DateComponents(year: 2024, month: 3, day: 7, hour: 23, minute: 30))!
        XCTAssertEqual(DailyUsageAccumulator.dayKey(from: date, calendar: calendar), "2024-03-07")

        // One instant belongs to different Gregorian days in different time zones.
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(DailyUsageAccumulator.dayKey(from: date, calendar: tokyo), "2024-03-08")
    }

    func testNonGregorianCalendarsKeepGregorianStorageKeysAndLocalMidnight() throws {
        let date = try XCTUnwrap(OpenUsageISO8601.date(from: "2026-12-31T17:30:00Z"))
        for identifier: Calendar.Identifier in [.buddhist, .hebrew, .islamicUmmAlQura, .japanese] {
            var calendar = Calendar(identifier: identifier)
            calendar.locale = Locale(identifier: "th_TH")
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Bangkok"))
            XCTAssertEqual(DailyUsageAccumulator.dayKey(from: date, calendar: calendar), "2027-01-01")
            calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
            XCTAssertEqual(DailyUsageAccumulator.dayKey(from: date, calendar: calendar), "2026-12-31")
        }
    }

    func testCalendarPreferenceDoesNotSplitUsageIntoDifferentStorageDays() throws {
        let date = try XCTUnwrap(OpenUsageISO8601.date(from: "2026-07-12T12:00:00Z"))
        var accumulator = DailyUsageAccumulator()
        for identifier: Calendar.Identifier in [.gregorian, .buddhist] {
            var calendar = Calendar(identifier: identifier)
            calendar.locale = Locale(identifier: "th_TH")
            calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
            accumulator.add(
                day: DailyUsageAccumulator.dayKey(from: date, calendar: calendar),
                tokens: 10, cost: 0.5, model: "fixture-model"
            )
        }
        XCTAssertEqual(accumulator.build().series.daily, [
            DailyUsageEntry(date: "2026-07-12", totalTokens: 20, costUSD: 1)
        ])
    }

    func testBuddhistHistoryWindowKeepsDistinctGregorianDaysAcrossDST() throws {
        var calendar = Calendar(identifier: .buddhist)
        calendar.locale = Locale(identifier: "th_TH")
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let beforeJump = try XCTUnwrap(OpenUsageISO8601.date(from: "2026-03-08T06:30:00Z"))
        let afterJump = try XCTUnwrap(OpenUsageISO8601.date(from: "2026-03-08T07:30:00Z"))
        XCTAssertEqual(DailyUsageAccumulator.dayKey(from: beforeJump, calendar: calendar), "2026-03-08")
        XCTAssertEqual(DailyUsageAccumulator.dayKey(from: afterJump, calendar: calendar), "2026-03-08")
        let now = try XCTUnwrap(OpenUsageISO8601.date(from: "2026-03-09T16:00:00Z"))
        let days = UsageHistoryWindow.dayKeys(through: now, calendar: calendar)
        XCTAssertEqual(days.count, 31)
        XCTAssertEqual(days.min(), "2026-02-07")
        XCTAssertEqual(days.max(), "2026-03-09")
        XCTAssertTrue(days.contains("2026-03-08"))
    }

    func testBuildSortsDaysNewestFirstAndSumsPerModel() {
        var accumulator = DailyUsageAccumulator()
        accumulator.add(day: "2024-06-01", tokens: 100, cost: 1.0, model: "sonnet")
        accumulator.add(day: "2024-06-03", tokens: 50, cost: 0.5, model: "sonnet")
        accumulator.add(day: "2024-06-01", tokens: 200, cost: 2.0, model: "sonnet")
        accumulator.add(day: "2024-06-01", tokens: 10, cost: 0.1, model: "opus")

        let scan = accumulator.build()
        XCTAssertEqual(scan.series.daily.map(\.date), ["2024-06-03", "2024-06-01"])
        XCTAssertEqual(scan.series.daily.map(\.totalTokens), [50, 310])
        // Every counted day is priced — a real cost, never nil-by-omission.
        XCTAssertEqual(scan.series.daily[1].costUSD ?? -1, 3.1, accuracy: 0.0001)

        let june1 = scan.modelUsage?.daily.first { $0.date == "2024-06-01" }
        let models = Dictionary(uniqueKeysWithValues: (june1?.models ?? []).map { ($0.model, $0) })
        XCTAssertEqual(models["sonnet"]?.totalTokens, 300)
        XCTAssertEqual(models["sonnet"]?.costUSD ?? -1, 3.0, accuracy: 0.0001)
        XCTAssertEqual(models["opus"]?.totalTokens, 10)
    }

    func testUnknownModelsStayOutOfTheSeries() {
        var accumulator = DailyUsageAccumulator()
        accumulator.addUnknownModel(day: "2024-06-02", model: "mystery-model")

        let scan = accumulator.build()
        // A day with only unpriceable usage never enters the series or the model breakdown — it
        // surfaces solely through the warning-triangle set.
        XCTAssertTrue(scan.series.daily.isEmpty)
        XCTAssertEqual(scan.modelUsage?.daily.isEmpty, true)
        XCTAssertEqual(scan.unknownModelsByDay, ["2024-06-02": ["mystery-model"]])
    }
}
