// UsagePeriod.swift
// Calyx
//
// The one rule for "the last N days" of usage, shared by every reader of
// the ledger so they all mean the same instant by it.

import Foundation

enum UsagePeriod {
    /// The largest `lastDays` `startMs` answers (about 273 years, far
    /// beyond any transcript); above it the result is nil.
    static let maxLastDays = 100_000

    /// The calendar every local-day computation of the usage feature
    /// uses: Gregorian, in `calendar`'s time zone. Only the time zone of
    /// an injected calendar matters. Day boundaries are the same in every
    /// calendar system, but labels are ISO `yyyy-MM-dd` dates, so the
    /// arithmetic behind them must be Gregorian too; other systems also
    /// wrap instead of saturating for huge day offsets.
    static func localDayCalendar(_ calendar: Calendar) -> Calendar {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian
    }

    /// Epoch milliseconds of the start of the local day exactly
    /// `lastDays - 1` calendar days before the day containing `now`, even
    /// when that day starts later than 00:00 (DST starting at midnight);
    /// nil when `lastDays` is outside `1...maxLastDays`, or when the
    /// calendar does not represent that day (or its start in Int64
    /// milliseconds). Of `calendar` only the time zone is used: see
    /// `localDayCalendar`.
    ///
    /// Steps by calendar days from the start of today, not by multiples
    /// of 86,400 seconds: a day around a DST change is 23 or 25 hours
    /// long, and a fixed step would land an hour off local midnight.
    ///
    /// The day found is verified by stepping forward from it by
    /// `lastDays - 1` calendar days and requiring that to land on today:
    /// for an offset beyond its range a calendar does not return nil but
    /// saturates at its earliest date, which is not the day asked for.
    /// Elapsed time cannot be the check: a day count between two
    /// instants is one short when the earlier day starts after 00:00,
    /// though it is still the right calendar day.
    static func startMs(lastDays: Int, now: Date, calendar injected: Calendar) -> Int64? {
        // Checked before `lastDays - 1`, which overflows for `Int.min`.
        guard (1...maxLastDays).contains(lastDays) else { return nil }
        let calendar = localDayCalendar(injected)
        let daysBack = lastDays - 1
        let today = calendar.startOfDay(for: now)
        guard let day = calendar.date(byAdding: .day, value: -daysBack, to: today) else { return nil }
        // Midnight of the target day may not exist in some zones (a DST
        // change at 00:00); its start of day is the first instant it has.
        let start = calendar.startOfDay(for: day)
        guard let back = calendar.date(byAdding: .day, value: daysBack, to: start),
              calendar.isDate(back, inSameDayAs: today) else { return nil }
        // `exactly`: a day too far back for Int64 milliseconds is nil, not a trap.
        return Int64(exactly: (start.timeIntervalSince1970 * 1_000).rounded())
    }
}
