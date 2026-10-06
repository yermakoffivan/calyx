// TranscriptTimestamp.swift
// Calyx
//
// The one parser of the timestamps Claude Code writes into its
// transcripts. Shared by every transcript reader (the per-response
// records and the run log) and by the `usage_report` MCP tool, so all of
// them accept exactly the same shape.

import Foundation

enum TranscriptTimestamp {
    /// Parses the one shape Claude Code writes (JavaScript's
    /// `toISOString()`): `YYYY-MM-DDTHH:MM:SS[.fraction]Z`, UTC only.
    /// Done by hand in integer arithmetic for two reasons: the result is
    /// millisecond-exact (no Double seconds to round), and it needs no
    /// formatter, which would either be allocated per line or shared as
    /// non-Sendable global state. The `usage_report` MCP tool parses its
    /// `since` / `until` arguments with it, so they take exactly the shape
    /// the transcripts use.
    static func epochMilliseconds(fromISO8601 text: String) -> Int64? {
        let bytes = Array(text.utf8)
        // "YYYY-MM-DDTHH:MM:SSZ" is 20 bytes; a fraction adds "." + digits.
        guard bytes.count >= 20, bytes.last == UInt8(ascii: "Z"),
              bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
              bytes[10] == UInt8(ascii: "T"),
              bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":"),
              let year = decimal(bytes[0..<4]),
              let month = decimal(bytes[5..<7]),
              let day = decimal(bytes[8..<10]),
              let hour = decimal(bytes[11..<13]),
              let minute = decimal(bytes[14..<16]),
              let second = decimal(bytes[17..<19]),
              (1...12).contains(month),
              (1...daysInMonth(month, year: year)).contains(day),
              hour < 24, minute < 60, second < 60 else {
            return nil
        }

        var milliseconds: Int64 = 0
        if bytes.count > 20 {
            let fraction = bytes[20..<(bytes.count - 1)]
            guard bytes[19] == UInt8(ascii: "."), !fraction.isEmpty,
                  fraction.allSatisfy(isDigit) else {
                return nil
            }
            // Digits beyond the third are below a millisecond: truncated.
            var scale: Int64 = 100
            for byte in fraction.prefix(3) {
                milliseconds += Int64(byte - UInt8(ascii: "0")) * scale
                scale /= 10
            }
        }

        let seconds = daysFromCivil(year: year, month: month, day: day) * 86_400
            + hour * 3_600 + minute * 60 + second
        return seconds * 1_000 + milliseconds
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    /// The value of an all-digit ASCII run; nil if any byte is not a digit.
    private static func decimal(_ bytes: ArraySlice<UInt8>) -> Int64? {
        var value: Int64 = 0
        for byte in bytes {
            guard isDigit(byte) else { return nil }
            value = value * 10 + Int64(byte - UInt8(ascii: "0"))
        }
        return value
    }

    private static func daysInMonth(_ month: Int64, year: Int64) -> Int64 {
        switch month {
        case 2:
            let isLeap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return isLeap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }

    /// Days from 1970-01-01 to the given proleptic Gregorian date (Howard
    /// Hinnant's `days_from_civil`): the year is shifted to start in March
    /// so the leap day falls at the end of the 400-year era's year.
    private static func daysFromCivil(year: Int64, month: Int64, day: Int64) -> Int64 {
        let shiftedYear = month <= 2 ? year - 1 : year
        // The parsed year is 0...9999, so shiftedYear is -1 at the lowest.
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
