//
//  UsageClockTests.swift
//  CalyxTests
//
//  `UsageClock.nanoseconds`: whole nanoseconds since the epoch, truncated
//  toward zero, saturated to `Int64.min ... Int64.max`; a non-finite date
//  reads as `Int64.max`. Every expected value below is computed by hand
//  from inputs chosen so that the seconds value survives `Date`'s
//  reference-date round trip exactly and its product with 1e9 is exactly
//  representable as a Double.
//

import XCTest
@testable import Calyx

final class UsageClockTests: XCTestCase {

    // MARK: - Ordinary dates

    func test_epoch_isZero() {
        XCTAssertEqual(UsageClock.nanoseconds(Date(timeIntervalSince1970: 0)), 0)
    }

    func test_fractionalPositiveSeconds_giveExactNanoseconds() {
        XCTAssertEqual(UsageClock.nanoseconds(Date(timeIntervalSince1970: 1_700_000_000.5)), 1_700_000_000_500_000_000)
    }

    func test_negativeHalfSecond_givesNegativeNanoseconds() {
        XCTAssertEqual(UsageClock.nanoseconds(Date(timeIntervalSince1970: -0.5)), -500_000_000)
    }

    /// 2^-23 s = 119.20928955078125 ns: truncation gives 119.
    func test_positiveSubNanosecondFraction_isTruncated() {
        let seconds = 1.0 / 8_388_608.0  // 2^-23, exact
        XCTAssertEqual(UsageClock.nanoseconds(Date(timeIntervalSince1970: seconds)), 119)
    }

    /// -2^-23 s = -119.20928955078125 ns: truncation toward zero gives -119
    /// (flooring would give -120).
    func test_negativeSubNanosecondFraction_isTruncatedTowardZero() {
        let seconds = -1.0 / 8_388_608.0  // -2^-23, exact
        XCTAssertEqual(UsageClock.nanoseconds(Date(timeIntervalSince1970: seconds)), -119)
    }

    // MARK: - Saturation

    func test_distantFuture_isInt64Max() {
        XCTAssertEqual(UsageClock.nanoseconds(Date.distantFuture), Int64.max)
    }

    func test_distantPast_isInt64Min() {
        XCTAssertEqual(UsageClock.nanoseconds(Date.distantPast), Int64.min)
    }

    /// 9_223_372_036 s * 1e9 = 9_223_372_036_000_000_000 < Int64.max
    /// (9_223_372_036_854_775_807), and it is a multiple of 1024 so the
    /// Double product is exact.
    func test_justInsideUpperBound_isExact() {
        XCTAssertEqual(UsageClock.nanoseconds(Date(timeIntervalSince1970: 9_223_372_036)), 9_223_372_036_000_000_000)
    }

    func test_justInsideLowerBound_isExact() {
        XCTAssertEqual(UsageClock.nanoseconds(Date(timeIntervalSince1970: -9_223_372_036)), -9_223_372_036_000_000_000)
    }

    /// 9_223_372_037 s * 1e9 = 9_223_372_037_000_000_000 > Int64.max.
    func test_justOutsideUpperBound_saturatesToInt64Max() {
        XCTAssertEqual(UsageClock.nanoseconds(Date(timeIntervalSince1970: 9_223_372_037)), Int64.max)
    }

    func test_justOutsideLowerBound_saturatesToInt64Min() {
        XCTAssertEqual(UsageClock.nanoseconds(Date(timeIntervalSince1970: -9_223_372_037)), Int64.min)
    }

    /// A finite date whose nanosecond product overflows to +infinity is
    /// still a finite date: it saturates to the maximum.
    func test_hugeFinitePositiveDate_saturatesToInt64Max() {
        XCTAssertEqual(UsageClock.nanoseconds(Date(timeIntervalSince1970: 1e300)), Int64.max)
    }

    /// A finite date whose nanosecond product overflows to -infinity must
    /// saturate to the minimum, not be mistaken for a non-finite date.
    func test_hugeFiniteNegativeDate_saturatesToInt64Min() {
        XCTAssertEqual(UsageClock.nanoseconds(Date(timeIntervalSince1970: -1e300)), Int64.min)
    }

    // MARK: - Non-finite dates

    func test_nan_isInt64Max() {
        XCTAssertEqual(UsageClock.nanoseconds(Date(timeIntervalSinceReferenceDate: .nan)), Int64.max)
    }

    func test_positiveInfinity_isInt64Max() {
        XCTAssertEqual(UsageClock.nanoseconds(Date(timeIntervalSinceReferenceDate: .infinity)), Int64.max)
    }

    func test_negativeInfinity_isInt64Max() {
        XCTAssertEqual(UsageClock.nanoseconds(Date(timeIntervalSinceReferenceDate: -.infinity)), Int64.max)
    }
}
