//
//  UsagePeriodTests.swift
//  CalyxTests
//
//  Pins UsagePeriod.startMs(lastDays:now:calendar:), the one rule that
//  turns "the last N local calendar days, today included" into an
//  inclusive lower bound in epoch milliseconds: the start of the local
//  day N - 1 days before the day containing `now`, in the INJECTED
//  calendar's time zone. It steps by calendar days, so a DST change
//  inside the window does not shift the bound by an hour, and a
//  `lastDays` below 1 has no answer.
//
//  Every expected value was computed independently of Swift (Python's
//  zoneinfo) and is written out as a literal, with the local and UTC
//  instants it stands for next to it.
//

import XCTest
@testable import Calyx

final class UsagePeriodTests: XCTestCase {

    private func calendar(_ identifier: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: identifier), "Fixture error: \(identifier)")
        return calendar
    }

    private func date(ms: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1_000)
    }

    /// 2026-10-02T10:27:29.765Z.
    private let utcNowMs: Int64 = 1_790_936_849_765

    // MARK: - UTC

    func test_utc_lastDays1_isTheStartOfToday() throws {
        let start = UsagePeriod.startMs(lastDays: 1, now: date(ms: utcNowMs), calendar: try calendar("UTC"))

        // 2026-10-02T00:00:00Z
        XCTAssertEqual(start, 1_790_899_200_000)
    }

    func test_utc_lastDays7_isTheStartOfTheDaySixDaysBeforeToday() throws {
        let start = UsagePeriod.startMs(lastDays: 7, now: date(ms: utcNowMs), calendar: try calendar("UTC"))

        // 2026-09-26T00:00:00Z
        XCTAssertEqual(start, 1_790_380_800_000)
    }

    func test_utc_lastDays30_isTheStartOfTheDay29DaysBeforeToday() throws {
        let start = UsagePeriod.startMs(lastDays: 30, now: date(ms: utcNowMs), calendar: try calendar("UTC"))

        // 2026-09-03T00:00:00Z
        XCTAssertEqual(start, 1_788_393_600_000)
    }

    func test_utc_lastMillisecondOfTheDay_stillCountsAsThatDay() throws {
        // 2026-10-02T23:59:59.999Z
        let start = UsagePeriod.startMs(lastDays: 1, now: date(ms: 1_790_985_599_999), calendar: try calendar("UTC"))

        // 2026-10-02T00:00:00Z
        XCTAssertEqual(start, 1_790_899_200_000)
    }

    // MARK: - A zone east of UTC

    // 2026-10-02T20:00:00Z is already 2026-10-03 05:00 in Tokyo, so the
    // local day is not the UTC day: the bound is Tokyo's midnight.
    func test_tokyo_lastDays1_isTheLocalMidnight_notTheUTCOne() throws {
        let now = date(ms: 1_790_971_200_000)

        let start = UsagePeriod.startMs(lastDays: 1, now: now, calendar: try calendar("Asia/Tokyo"))

        // 2026-10-03T00:00 JST = 2026-10-02T15:00:00Z
        XCTAssertEqual(start, 1_790_953_200_000)
    }

    func test_tokyo_lastDays7_isTheLocalMidnightSixDaysBefore() throws {
        let now = date(ms: 1_790_971_200_000)

        let start = UsagePeriod.startMs(lastDays: 7, now: now, calendar: try calendar("Asia/Tokyo"))

        // 2026-09-27T00:00 JST = 2026-09-26T15:00:00Z
        XCTAssertEqual(start, 1_790_434_800_000)
    }

    func test_exactlyAtLocalMidnight_theBoundIsThatInstant() throws {
        // 2026-10-03T00:00:00.000 JST: the first instant of the new day.
        let midnight: Int64 = 1_790_953_200_000

        let today = UsagePeriod.startMs(lastDays: 1, now: date(ms: midnight), calendar: try calendar("Asia/Tokyo"))
        let fourDays = UsagePeriod.startMs(lastDays: 4, now: date(ms: midnight), calendar: try calendar("Asia/Tokyo"))

        XCTAssertEqual(today, midnight)
        // 2026-09-30T00:00 JST = 2026-09-29T15:00:00Z
        XCTAssertEqual(fourDays, 1_790_694_000_000)
    }

    // MARK: - DST

    // New York springs forward on 2026-03-08 (that day has 23 hours).
    // Three days back from 2026-03-10 12:00 EDT is 2026-03-08 00:00 EST
    // = 05:00Z; subtracting 2 x 86,400 s from 2026-03-10 00:00 EDT
    // (04:00Z) would give 04:00Z, an hour early.
    func test_newYork_acrossSpringForward_stepsByCalendarDays() throws {
        let now = date(ms: 1_773_158_400_000) // 2026-03-10T12:00 EDT

        let start = UsagePeriod.startMs(lastDays: 3, now: now, calendar: try calendar("America/New_York"))

        XCTAssertEqual(start, 1_772_946_000_000) // 2026-03-08T05:00:00Z
        XCTAssertNotEqual(start, 1_772_942_400_000, "stepped by 86,400-second days")
    }

    // New York falls back on 2026-11-01 (that day has 25 hours). Two
    // days back from 2026-11-02 12:00 EST is 2026-11-01 00:00 EDT =
    // 04:00Z; 2026-11-02 00:00 EST (05:00Z) minus 86,400 s would give
    // 05:00Z, an hour late.
    func test_newYork_acrossFallBack_stepsByCalendarDays() throws {
        let now = date(ms: 1_793_638_800_000) // 2026-11-02T12:00 EST

        let start = UsagePeriod.startMs(lastDays: 2, now: now, calendar: try calendar("America/New_York"))

        XCTAssertEqual(start, 1_793_505_600_000) // 2026-11-01T04:00:00Z
        XCTAssertNotEqual(start, 1_793_509_200_000, "stepped by 86,400-second days")
    }

    // MARK: - No answer

    func test_lastDaysZeroOrNegative_isNil() throws {
        let utc = try calendar("UTC")

        XCTAssertNil(UsagePeriod.startMs(lastDays: 0, now: date(ms: utcNowMs), calendar: utc))
        XCTAssertNil(UsagePeriod.startMs(lastDays: -1, now: date(ms: utcNowMs), calendar: utc))
        XCTAssertNil(UsagePeriod.startMs(lastDays: Int.min, now: date(ms: utcNowMs), calendar: utc))
    }

    // MARK: - Far back

    // A calendar does not return nil for a day offset it cannot represent:
    // it saturates at its earliest date. Such a day is not "lastDays - 1
    // days before today", so there is no answer.
    func test_lastDaysBeyondTheCalendar_isNil() throws {
        let tokyo = try calendar("Asia/Tokyo")
        let now = date(ms: 1_790_971_200_000)

        for lastDays in [1_000_000_000, Int.max / 2, Int.max] {
            XCTAssertNil(UsagePeriod.startMs(lastDays: lastDays, now: now, calendar: tokyo), "\(lastDays)")
        }
    }

    // A long window the calendar does represent stays valid: it means
    // "everything from that day on".
    func test_lastDays36500_isTheDay36499DaysBeforeToday() throws {
        let start = UsagePeriod.startMs(lastDays: 36_500, now: date(ms: utcNowMs), calendar: try calendar("UTC"))

        // 1926-10-28T00:00:00Z
        XCTAssertEqual(start, -1_362_614_400_000)
    }

    // MARK: - DST at midnight

    // Some zones change at 00:00, so that local day has no midnight and
    // starts at 01:00. That day is still a valid answer: the bound is its
    // first instant.

    // Sao Paulo started DST at 00:00 on 2018-11-04. Seven days back from
    // 2018-11-10 (10:00 local) is 2018-11-04, which began at 01:00 -02.
    func test_saoPaulo_dayStartingAt0100_isTheAnswer() throws {
        let now = date(ms: 1_541_851_200_000) // 2018-11-10T12:00:00Z

        let start = UsagePeriod.startMs(lastDays: 7, now: now, calendar: try calendar("America/Sao_Paulo"))

        XCTAssertEqual(start, 1_541_300_400_000) // 2018-11-04T03:00:00Z = 01:00 local
    }

    // Havana started DST at 00:00 on 2024-03-10. Three days back from
    // 2024-03-12 13:00 local is 2024-03-10, which began at 01:00 -04.
    func test_havana_dayStartingAt0100_isTheAnswer() throws {
        let now = date(ms: 1_710_262_800_000) // 2024-03-12T17:00:00Z

        let start = UsagePeriod.startMs(lastDays: 3, now: now, calendar: try calendar("America/Havana"))

        XCTAssertEqual(start, 1_710_046_800_000) // 2024-03-10T05:00:00Z = 01:00 local
    }

    // Santiago started DST at 00:00 on 2024-09-08. Three days back from
    // 2024-09-10 09:00 local is 2024-09-08, which began at 01:00 -03.
    func test_santiago_dayStartingAt0100_isTheAnswer() throws {
        let now = date(ms: 1_725_969_600_000) // 2024-09-10T12:00:00Z

        let start = UsagePeriod.startMs(lastDays: 3, now: now, calendar: try calendar("America/Santiago"))

        XCTAssertEqual(start, 1_725_768_000_000) // 2024-09-08T04:00:00Z = 01:00 local
    }

    // Every day of a year that contains a DST change, for several window
    // lengths: never nil, and always the first instant of the local day
    // exactly `lastDays - 1` calendar days before today's local day.
    //
    // Checked without the implementation's stepping: the two local dates
    // are read as year/month/day and their distance is counted with
    // plain proleptic-Gregorian day numbers (`dayNumber`); "first instant
    // of its day" means the millisecond before has another local date.
    func test_sweep_everyDayOfAYear_isNeverNil_andIsTheRightLocalDaysStart() throws {
        let zones: [(String, Int)] = [
            ("America/Sao_Paulo", 2018), ("Asia/Tehran", 2022), ("Asia/Beirut", 2024),
            ("America/Havana", 2024), ("America/Santiago", 2024), ("America/New_York", 2024), ("UTC", 2024),
        ]
        var failures = 0
        for (identifier, year) in zones {
            let zone = try calendar(identifier)
            // 15:00Z on 1 January of `year`.
            let firstNowMs = Self.dayNumber(year: Int64(year), month: 1, day: 1) * 86_400_000 + 15 * 3_600_000
            for dayIndex in 0..<365 {
                let now = date(ms: firstNowMs + Int64(dayIndex) * 86_400_000)
                let today = localDate(now, zone)
                for lastDays in [1, 2, 7, 30, 365] {
                    guard let startMs = UsagePeriod.startMs(lastDays: lastDays, now: now, calendar: zone) else {
                        failures += 1
                        if failures <= 20 { XCTFail("nil: \(identifier) now \(now) lastDays \(lastDays)") }
                        continue
                    }
                    let start = localDate(date(ms: startMs), zone)
                    let before = localDate(date(ms: startMs - 1), zone)
                    let distance = Self.dayNumber(year: today.year, month: today.month, day: today.day)
                        - Self.dayNumber(year: start.year, month: start.month, day: start.day)
                    if distance != Int64(lastDays - 1) || before == start {
                        failures += 1
                        if failures <= 20 {
                            XCTFail("\(identifier) now \(now) lastDays \(lastDays): start \(start), before \(before)")
                        }
                    }
                }
            }
        }
        XCTAssertEqual(failures, 0)
    }

    private struct LocalDate: Equatable {
        let year: Int64
        let month: Int64
        let day: Int64
    }

    private func localDate(_ date: Date, _ calendar: Calendar) -> LocalDate {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return LocalDate(year: Int64(parts.year ?? 0), month: Int64(parts.month ?? 0), day: Int64(parts.day ?? 0))
    }

    /// Days from 1970-01-01 to a proleptic Gregorian date (Howard
    /// Hinnant's `days_from_civil`), independent of any Calendar.
    private static func dayNumber(year: Int64, month: Int64, day: Int64) -> Int64 {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    // MARK: - Calendar systems and the domain

    // Only the calendar's time zone matters: the day arithmetic is
    // Gregorian in that zone, so every calendar system gives the
    // Gregorian answer. The Gregorian answers are the literals above
    // (computed with Python zoneinfo) and the sweep's.
    private static let otherSystems: [Calendar.Identifier] = [
        .japanese, .buddhist, .hebrew, .islamicUmmAlQura, .persian,
    ]

    private func calendar(_ system: Calendar.Identifier, _ identifier: String) throws -> Calendar {
        var calendar = Calendar(identifier: system)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: identifier), "Fixture error: \(identifier)")
        return calendar
    }

    func test_otherCalendarSystems_fixedCases_giveTheGregorianResults() throws {
        let cases: [(zone: String, nowMs: Int64, lastDays: Int, expected: Int64)] = [
            ("Asia/Tokyo", 1_790_971_200_000, 1, 1_790_953_200_000), // 2026-10-03 JST
            ("Asia/Tokyo", 1_790_971_200_000, 7, 1_790_434_800_000), // 2026-09-27 JST
            ("Asia/Tokyo", 1_790_953_200_000, 4, 1_790_694_000_000), // at midnight; 2026-09-30 JST
            ("America/Sao_Paulo", 1_541_851_200_000, 7, 1_541_300_400_000), // 2018-11-04 01:00 -02
        ]
        for system in Self.otherSystems {
            for item in cases {
                let start = UsagePeriod.startMs(
                    lastDays: item.lastDays, now: date(ms: item.nowMs), calendar: try calendar(system, item.zone))
                XCTAssertEqual(start, item.expected, "\(system) \(item.zone) \(item.lastDays)")
            }
        }
    }

    // Every 7th day of 2018 in Sao Paulo (a midnight DST change in
    // November) and of 2026 in Tokyo, against the Gregorian calendar in
    // the same zone, which the sweep above checks independently.
    func test_otherCalendarSystems_sweepSample_givesTheGregorianResults() throws {
        for (zone, year) in [("America/Sao_Paulo", Int64(2018)), ("Asia/Tokyo", Int64(2026))] {
            let gregorian = try calendar(.gregorian, zone)
            let firstNowMs = Self.dayNumber(year: year, month: 1, day: 1) * 86_400_000 + 15 * 3_600_000
            for system in Self.otherSystems {
                let other = try calendar(system, zone)
                for dayIndex in stride(from: 0, to: 365, by: 7) {
                    let now = date(ms: firstNowMs + Int64(dayIndex) * 86_400_000)
                    for lastDays in [1, 2, 7, 30, 365] {
                        let expected = UsagePeriod.startMs(lastDays: lastDays, now: now, calendar: gregorian)
                        XCTAssertNotNil(expected, "Fixture error: \(zone) \(now) \(lastDays)")
                        XCTAssertEqual(
                            UsagePeriod.startMs(lastDays: lastDays, now: now, calendar: other), expected,
                            "\(system) \(zone) \(now) \(lastDays)")
                    }
                }
            }
        }
    }

    func test_maxLastDays_is100000() {
        XCTAssertEqual(UsagePeriod.maxLastDays, 100_000)
    }

    // Above the documented domain there is no answer, in every calendar
    // system: some systems wrap a huge day offset around instead of
    // saturating, and the wrapped day would pass a round-trip check.
    func test_lastDaysAboveTheDomain_isNil_inEveryCalendarSystem() throws {
        let now = date(ms: 1_790_971_200_000)
        for system in [Calendar.Identifier.gregorian] + Self.otherSystems {
            for zone in ["Asia/Tokyo", "America/Sao_Paulo"] {
                let calendar = try calendar(system, zone)
                for lastDays in [Int.max, 4_110_634_394, UsagePeriod.maxLastDays + 1] {
                    XCTAssertNil(
                        UsagePeriod.startMs(lastDays: lastDays, now: now, calendar: calendar),
                        "\(system) \(zone) \(lastDays)")
                }
            }
        }
    }

    // The largest valid window: 99,999 days before 2026-10-02 is
    // 1752-12-18 (Python `date.fromordinal`), 00:00Z.
    func test_maxLastDays_isTheVerifiedDay_gregorianAndJapanese() throws {
        for system in [Calendar.Identifier.gregorian, .japanese] {
            let start = UsagePeriod.startMs(
                lastDays: UsagePeriod.maxLastDays, now: date(ms: utcNowMs), calendar: try calendar(system, "UTC"))

            XCTAssertEqual(start, -6_849_014_400_000, "\(system)")
        }
    }
}
