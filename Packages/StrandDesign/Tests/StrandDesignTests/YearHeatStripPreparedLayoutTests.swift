import XCTest
@testable import StrandDesign

final class YearHeatStripPreparedLayoutTests: XCTestCase {

    func testPreparedLayoutPreservesSortedMondayFirstCellsAndStableIDs() throws {
        let dates = try (0..<11).map { offset -> Date in
            let day = 26 + offset
            let month = day <= 29 ? 2 : 3
            let monthDay = day <= 29 ? day : day - 29
            return try utcDate(year: 2024, month: month, day: monthDay)
        }
        let source = dates.enumerated().map { index, date in
            RecoveryDay(date: date, score: index == 1 ? nil : 70)
        }

        let prepared = YearHeatStrip.PreparedLayout(
            days: Array(source.reversed()), locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(prepared.days.map(\.date), dates)
        XCTAssertEqual(prepared.scoredDayCount, 10)
        XCTAssertEqual(prepared.weekCellDates, [
            dates[0...6].map { Optional<Date>.some($0) },
            dates[7...10].map { Optional<Date>.some($0) } + [nil, nil, nil],
        ])
        XCTAssertEqual(prepared.weekIDs, [dates[0], dates[7]])

        // Re-preparing after a score-only refresh keeps each calendar day and week identity stable.
        let updated = YearHeatStrip.PreparedLayout(
            days: source.map { day in RecoveryDay(date: day.date, score: day.score == nil ? nil : 82) },
            locale: Locale(identifier: "en_US"), timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(updated.days.map(\.id), prepared.days.map(\.id))
        XCTAssertEqual(updated.weekIDs, prepared.weekIDs)
        XCTAssertEqual(updated.days.compactMap(\.score).first, 82.0)
    }

    func testPreparedLayoutUsesPassedTimezoneForWeekdayPlacement() throws {
        let date = try utcDate(year: 2024, month: 3, day: 4, hour: 0, minute: 30)
        let day = RecoveryDay(date: date, score: 70)
        let locale = Locale(identifier: "en_US")

        let utc = YearHeatStrip.PreparedLayout(
            days: [day], locale: locale, timeZone: TimeZone(secondsFromGMT: 0)!
        )
        let losAngeles = YearHeatStrip.PreparedLayout(
            days: [day], locale: locale, timeZone: try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        )

        // 00:30 UTC Monday is still Sunday evening in Los Angeles. The grid remains Monday-first,
        // while the passed timezone determines which weekday row contains the same instant.
        XCTAssertEqual(utc.weekCellDates[0][0], date)
        XCTAssertEqual(losAngeles.weekCellDates[0][6], date)
        XCTAssertNotEqual(utc.weekCellDates, losAngeles.weekCellDates)
    }

    func testPreparedLayoutReformatsMonthLabelsForPassedLocale() throws {
        let date = try utcDate(year: 2024, month: 3, day: 1)
        let day = RecoveryDay(date: date, score: 70)
        let timeZone = TimeZone(secondsFromGMT: 0)!

        let english = YearHeatStrip.PreparedLayout(
            days: [day], locale: Locale(identifier: "en_US"), timeZone: timeZone
        )
        let japanese = YearHeatStrip.PreparedLayout(
            days: [day], locale: Locale(identifier: "ja_JP"), timeZone: timeZone
        )

        XCTAssertEqual(english.weekMonthLabels.first!, "Mar")
        XCTAssertEqual(japanese.weekMonthLabels.first!, "3月")
    }

    @MainActor
    func testPreparedLayoutCacheReusesHitsAndInvalidatesScoreOnlyRefreshes() throws {
        final class Source {}
        let source = Source()
        let cache = YearHeatStrip.PreparedLayoutCache()
        let key = makeKey(source: ObjectIdentifier(source), generation: 4)
        let date = try utcDate(year: 2025, month: 1, day: 1)
        var builds = 0

        let first = cache.get(for: key) {
            builds += 1
            return YearHeatStrip.PreparedLayout(days: [RecoveryDay(date: date, score: 55)])
        }
        let hit = cache.get(for: key) {
            builds += 1
            return YearHeatStrip.PreparedLayout(days: [RecoveryDay(date: date, score: 99)])
        }
        XCTAssertEqual(builds, 1)
        XCTAssertEqual(hit.days.first?.score, 55)
        XCTAssertTrue(cache.value(for: key) != nil)

        // Same number of rows, changed score: the repository generation is the invalidation signal.
        let refreshedKey = makeKey(source: ObjectIdentifier(source), generation: 5)
        let refreshed = cache.get(for: refreshedKey) {
            builds += 1
            return YearHeatStrip.PreparedLayout(days: [RecoveryDay(date: date, score: 82)])
        }
        XCTAssertEqual(builds, 2)
        XCTAssertEqual(refreshed.days.count, first.days.count)
        XCTAssertEqual(refreshed.days.first?.score, 82)
        XCTAssertEqual(refreshed.days.first?.id, first.days.first?.id)
        XCTAssertNil(cache.value(for: key))
    }

    @MainActor
    func testThousandSameKeyRendersParseAndPrepareOnceThenRefreshOnce() throws {
        final class Source {}
        let source = Source()
        let cache = YearHeatStrip.PreparedLayoutCache()
        let firstKey = makeKey(source: ObjectIdentifier(source), generation: 10, selection: 365)
        let refreshedKey = makeKey(source: ObjectIdentifier(source), generation: 11, selection: 365)
        let locale = Locale(identifier: "en_US_POSIX")
        let timeZone = TimeZone(secondsFromGMT: 0)!
        var parser = DateFormatter()
        parser.locale = locale
        parser.timeZone = timeZone
        parser.dateFormat = "yyyy-MM-dd"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let anchor = try utcDate(year: 2025, month: 12, day: 31)
        let dayKeys = (0..<365).compactMap { offset -> String? in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: anchor) else { return nil }
            return parser.string(from: date)
        }
        XCTAssertEqual(dayKeys.count, 365)

        var cachedLayoutBuilds = 0
        var cachedDateParses = 0
        var cachedChecksum = 0
        for _ in 0..<1_000 {
            let layout = cache.get(for: firstKey) {
                cachedLayoutBuilds += 1
                let days = dayKeys.enumerated().compactMap { index, key -> RecoveryDay? in
                    guard let date = parser.date(from: key) else { return nil }
                    cachedDateParses += 1
                    return RecoveryDay(date: date, score: Double(index % 101))
                }
                return YearHeatStrip.PreparedLayout(days: days, locale: locale, timeZone: timeZone)
            }
            cachedChecksum += layout.scoredDayCount
        }

        var baselineLayoutBuilds = 0
        var baselineDateParses = 0
        var baselineChecksum = 0
        for _ in 0..<1_000 {
            let days = dayKeys.enumerated().compactMap { index, key -> RecoveryDay? in
                guard let date = parser.date(from: key) else { return nil }
                baselineDateParses += 1
                return RecoveryDay(date: date, score: Double(index % 101))
            }
            let layout = YearHeatStrip.PreparedLayout(days: days, locale: locale, timeZone: timeZone)
            baselineLayoutBuilds += 1
            baselineChecksum += layout.scoredDayCount
        }

        XCTAssertEqual(cachedLayoutBuilds, 1)
        XCTAssertEqual(cachedDateParses, 365)
        XCTAssertEqual(baselineLayoutBuilds, 1_000)
        XCTAssertEqual(baselineDateParses, 365_000)
        XCTAssertEqual(cachedChecksum, baselineChecksum)

        // A repository-generation change invalidates even with the same 365 day keys and row count.
        let refreshed = cache.get(for: refreshedKey) {
            cachedLayoutBuilds += 1
            let days = dayKeys.enumerated().compactMap { index, key -> RecoveryDay? in
                guard let date = parser.date(from: key) else { return nil }
                cachedDateParses += 1
                let score = index == 0 ? 100.0 : Double(index % 101)
                return RecoveryDay(date: date, score: score)
            }
            return YearHeatStrip.PreparedLayout(days: days, locale: locale, timeZone: timeZone)
        }
        XCTAssertEqual(cachedLayoutBuilds, 2)
        XCTAssertEqual(cachedDateParses, 730)
        XCTAssertEqual(refreshed.days.count, 365)
        XCTAssertEqual(refreshed.days.last?.score, 100.0)
    }

    @MainActor
    func testCacheKeyIncludesRangeLocaleCalendarAndTimezone() throws {
        final class Source {}
        let source = Source()
        let otherSource = Source()
        let cache = YearHeatStrip.PreparedLayoutCache()
        let base = makeKey(source: ObjectIdentifier(source), generation: 1)
        let date = try utcDate(year: 2025, month: 1, day: 1)
        var builds = 0

        for key in [
            base,
            makeKey(source: ObjectIdentifier(otherSource), generation: 1),
            makeKey(source: ObjectIdentifier(source), generation: 1, selection: 365),
            makeKey(source: ObjectIdentifier(source), generation: 1, locale: "fr_FR"),
            makeKey(source: ObjectIdentifier(source), generation: 1, calendar: "buddhist"),
            makeKey(source: ObjectIdentifier(source), generation: 1, firstWeekday: 1),
            makeKey(source: ObjectIdentifier(source), generation: 1, timeZone: "Pacific/Auckland"),
        ] {
            _ = cache.get(for: key) {
                builds += 1
                return YearHeatStrip.PreparedLayout(days: [RecoveryDay(date: date, score: 50)])
            }
        }

        XCTAssertEqual(builds, 7)
    }

    private func makeKey(source: ObjectIdentifier, generation: Int, selection: Int = 90,
                         locale: String = "en_US", calendar: String = "gregorian",
                         firstWeekday: Int = 2,
                         timeZone: String = "UTC") -> YearHeatStrip.PreparedLayoutCache.Key {
        YearHeatStrip.PreparedLayoutCache.Key(
            source: source, generation: generation, selection: selection,
            localeIdentifier: locale, calendarIdentifier: calendar,
            firstWeekday: firstWeekday, minimumDaysInFirstWeek: 4, timeZoneIdentifier: timeZone
        )
    }

    private func utcDate(year: Int, month: Int, day: Int, hour: Int = 12, minute: Int = 0) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                                 hour: hour, minute: minute)))
    }
}
