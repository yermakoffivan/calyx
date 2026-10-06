//
//  MissionMapPopoverPlacementTests.swift
//  CalyxTests
//
//  Pins MissionMapPopoverPlacement.place(extent:anchor:gap:edgeInset:obstacles:bounds:):
//  candidates in order above, below, left, right of the anchor (bubble
//  edge `gap` away, centered on the anchor along the other axis), then
//  the four diagonal corners (bubble corner `gap` from the anchor); each
//  clamped (translated, never resized) into `bounds` inset by `edgeInset`
//  on each axis -- the inset shrinking to min(edgeInset, max(0, (bounds
//  side - rect side) / 2)) when there is no room -- then scored by total
//  overlap area with `obstacles` -- lowest score wins, ties -> earlier
//  candidate. Also pins `score(_:obstacles:)`.
//
//  All expected values below are computed by hand from the spec's rule,
//  not by running an implementation.
//

import XCTest
@testable import Calyx

final class MissionMapPopoverPlacementTests: XCTestCase {

    private let gap: CGFloat = 8
    private let extent = CGSize(width: 320, height: 80)
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)

    /// Two adjacent cards with an 8 pt gap directly above them (card top
    /// edge at y=100) and the anchor sitting on that gap's midline. The
    /// "above" candidate (bubble bottom edge 8 pt above the anchor, i.e.
    /// 8 pt above the cards' top edge) then clears both cards entirely:
    ///   above candidate: y 12...92 (bottom = 100-8 = 92, top = 92-80 = 12),
    ///   x 120...440 (centered on anchor.x = 280, width 320).
    /// Neither card (y 100...250) overlaps y 12...92, so score = 0, and
    /// "above" is tried before below/left/right/diagonals, all of which
    /// do overlap the cards -- so it wins outright.
    ///
    /// (Note: the task's original fixture -- cards flush at y=40...190
    /// with the anchor at their shared gap's *midpoint*, y=115 -- has NO
    /// zero-overlap candidate: the cards leave only 40 pt above/below,
    /// less than the bubble's 80 pt height, and every one of the 8
    /// candidates (hand-computed) scores at least 17420. That fixture is
    /// used unmodified in `test_place_noRoomAboveOrBelow_stillWithinBounds`
    /// below, without asserting score == 0.)
    func test_place_adjacentCardsWithRoomAbove_placesAboveWithZeroOverlap() {
        let card1 = CGRect(x: 0, y: 100, width: 260, height: 150)
        let card2 = CGRect(x: 300, y: 100, width: 260, height: 150)
        let anchor = CGPoint(x: 280, y: 100)

        let rect = MissionMapPopoverPlacement.place(
            extent: extent, anchor: anchor, gap: gap, obstacles: [card1, card2], bounds: bounds
        )

        XCTAssertEqual(rect, CGRect(x: 120, y: 12, width: 320, height: 80))
        XCTAssertEqual(MissionMapPopoverPlacement.score(rect, obstacles: [card1, card2]), 0)
    }

    /// The task's original fixture: cards flush at y=40...190, anchor at
    /// their shared gap's midpoint (280, 115). By hand, none of the 8
    /// candidates clears the cards (the gap is only 40 pt tall, the
    /// bubble 80 pt); the best is 17420 (a diagonal). A shrunk bounds
    /// height (240, still taller than every candidate's clamped rect, so
    /// clamping itself does not change any candidate's score here) does
    /// not change that -- there is no room above or below either way.
    /// This asserts only what is unambiguous: the result stays inside
    /// bounds, scores strictly above zero, and is no worse than the best
    /// hand-computed axis candidate ("above", 18760) -- so an
    /// implementation that ignores obstacles (e.g. always "above") or
    /// ignores bounds fails this test.
    func test_place_noRoomAboveOrBelow_stillWithinBounds() {
        let card1 = CGRect(x: 0, y: 40, width: 260, height: 150)
        let card2 = CGRect(x: 300, y: 40, width: 260, height: 150)
        let anchor = CGPoint(x: 280, y: 115)
        let shortBounds = CGRect(x: 0, y: 0, width: 1000, height: 240)

        let rect = MissionMapPopoverPlacement.place(
            extent: extent, anchor: anchor, gap: gap, obstacles: [card1, card2], bounds: shortBounds
        )

        XCTAssertTrue(shortBounds.contains(rect.origin))
        XCTAssertLessThanOrEqual(rect.maxX, shortBounds.maxX)
        XCTAssertLessThanOrEqual(rect.maxY, shortBounds.maxY)
        let score = MissionMapPopoverPlacement.score(rect, obstacles: [card1, card2])
        XCTAssertGreaterThan(score, 0)
        XCTAssertLessThanOrEqual(score, 18760)
    }

    /// No obstacles: the anchor is 10 pt from the right edge of a
    /// 1000-wide bounds, so the "above" candidate (first tried, always
    /// tied at score 0 with no obstacles) would overhang the right edge
    /// (x 830...1150) and must be clamped (translated left) to sit the
    /// default 8 pt inset in from it: x = 1000 - 8 - 320 = 672, so
    /// x 672...992, y 212...292 (bottom = 300-8 = 292, top = 292-80 = 212).
    func test_place_nearRightEdge_clampsIntoBounds() {
        let anchor = CGPoint(x: 990, y: 300)

        let rect = MissionMapPopoverPlacement.place(
            extent: extent, anchor: anchor, gap: gap, obstacles: [], bounds: bounds
        )

        XCTAssertEqual(rect, CGRect(x: 672, y: 212, width: 320, height: 80))
        XCTAssertLessThanOrEqual(rect.maxX, bounds.maxX - 8)
    }

    /// No obstacles, anchor 10 pt from the left edge: "above" (first,
    /// score 0) has x = 10 - 160 = -150, clamped right to the 8 pt inset:
    /// x = 0 + 8 = 8; y = 300 - 8 - 80 = 212 (inside 8...612, untouched).
    func test_place_nearLeftEdge_clampsEdgeInsetFromLeft() {
        let anchor = CGPoint(x: 10, y: 300)

        let rect = MissionMapPopoverPlacement.place(
            extent: extent, anchor: anchor, gap: gap, obstacles: [], bounds: bounds
        )

        XCTAssertEqual(rect, CGRect(x: 8, y: 212, width: 320, height: 80))
        XCTAssertEqual(rect.minX, bounds.minX + 8)
    }

    /// No obstacles, anchor 50 pt below the top: "above" has
    /// y = 50 - 8 - 80 = -38, clamped down to the inset: y = 8;
    /// x = 500 - 160 = 340 (inside 8...672, untouched).
    func test_place_nearTopEdge_clampsEdgeInsetFromTop() {
        let anchor = CGPoint(x: 500, y: 50)

        let rect = MissionMapPopoverPlacement.place(
            extent: extent, anchor: anchor, gap: gap, obstacles: [], bounds: bounds
        )

        XCTAssertEqual(rect, CGRect(x: 340, y: 8, width: 320, height: 80))
        XCTAssertEqual(rect.minY, bounds.minY + 8)
    }

    /// No obstacles, anchor below the bounds (y = 760, e.g. scrolled
    /// content): "above" (still first, score 0) has y = 760 - 88 = 672,
    /// maxY 752 > 692, so it is clamped up to y = 700 - 8 - 80 = 612
    /// (maxY 692); x = 500 - 160 = 340.
    func test_place_nearBottomEdge_clampsEdgeInsetFromBottom() {
        let anchor = CGPoint(x: 500, y: 760)

        let rect = MissionMapPopoverPlacement.place(
            extent: extent, anchor: anchor, gap: gap, obstacles: [], bounds: bounds
        )

        XCTAssertEqual(rect, CGRect(x: 340, y: 612, width: 320, height: 80))
        XCTAssertEqual(rect.maxY, bounds.maxY - 8)
    }

    /// Bounds only 330 wide for a 320-wide bubble: room 10 < 2*8, so the
    /// x inset shrinks to min(8, 10/2) = 5. "above" x = 10 - 160 = -150
    /// -> clamped to 0 + 5 = 5 (centered: 5...325). y = 212 (room on y).
    func test_place_tightBounds_shrinksInsetEquallyAndStaysInside() {
        let anchor = CGPoint(x: 10, y: 300)
        let tightBounds = CGRect(x: 0, y: 0, width: 330, height: 700)

        let rect = MissionMapPopoverPlacement.place(
            extent: extent, anchor: anchor, gap: gap, obstacles: [], bounds: tightBounds
        )

        XCTAssertEqual(rect, CGRect(x: 5, y: 212, width: 320, height: 80))
        XCTAssertEqual(rect.minX, tightBounds.minX + 5)
        XCTAssertTrue(tightBounds.contains(rect))
    }

    /// Mirror of the tight case on the max side: bounds 330 wide, inset
    /// min(8, 10/2) = 5. Anchor x = 320: "above" x = 320 - 160 = 160,
    /// maxX 480 > 325, so clamped left to 330 - 5 - 320 = 5 (5...325).
    /// y = 300 - 88 = 212.
    func test_place_tightBounds_maxSide_shrinksInsetEqually() {
        let anchor = CGPoint(x: 320, y: 300)
        let tightBounds = CGRect(x: 0, y: 0, width: 330, height: 700)

        let rect = MissionMapPopoverPlacement.place(
            extent: extent, anchor: anchor, gap: gap, obstacles: [], bounds: tightBounds
        )

        XCTAssertEqual(rect, CGRect(x: 5, y: 212, width: 320, height: 80))
        XCTAssertEqual(rect.maxX, tightBounds.maxX - 5)
    }

    /// Tight x axis with non-zero origin: bounds (100, 50, 330x700),
    /// inset x = min(8, (330-320)/2) = 5; allowed x is exactly
    /// 100+5 = 105 ... 430-5-320 = 105.
    ///   min side: anchor x 110 -> raw 110-160 = -50 -> 105.
    ///   max side: anchor x 420 -> raw 420-160 = 260 -> 105.
    /// y: inset 8, allowed 58 ... 750-8-80 = 662; raw 300-88 = 212, kept.
    func test_place_tightBounds_nonZeroOrigin_centersOnBothSides() {
        let offsetTight = CGRect(x: 100, y: 50, width: 330, height: 700)

        let fromMin = MissionMapPopoverPlacement.place(
            extent: extent, anchor: CGPoint(x: 110, y: 300), gap: gap, obstacles: [], bounds: offsetTight
        )
        let fromMax = MissionMapPopoverPlacement.place(
            extent: extent, anchor: CGPoint(x: 420, y: 300), gap: gap, obstacles: [], bounds: offsetTight
        )

        XCTAssertEqual(fromMin, CGRect(x: 105, y: 212, width: 320, height: 80))
        XCTAssertEqual(fromMax, CGRect(x: 105, y: 212, width: 320, height: 80))
    }

    /// Only y oversize: extent 320x800 in bounds (100, 50, 1000x700).
    /// y inset = max(0, (700-800)/2) -> 0; allowed y: lower 50, upper
    /// 750-0-800 = -50; max(50, min(raw, -50)) = 50 -> min edge on
    /// bounds' min edge. (raw "above" y = 350-8-800 = -458.)
    /// x is roomy, inset 8, allowed 108 ... 1100-8-320 = 772:
    ///   anchor x 110  -> raw -50 -> 108;
    ///   anchor x 1090 -> raw 930 -> 772.
    func test_place_oneAxisOversize_otherAxisKeepsFullInsetFromNonZeroOrigin() {
        let tallExtent = CGSize(width: 320, height: 800)
        let offsetBounds = CGRect(x: 100, y: 50, width: 1000, height: 700)

        let nearMin = MissionMapPopoverPlacement.place(
            extent: tallExtent, anchor: CGPoint(x: 110, y: 350), gap: gap, obstacles: [], bounds: offsetBounds
        )
        let nearMax = MissionMapPopoverPlacement.place(
            extent: tallExtent, anchor: CGPoint(x: 1090, y: 350), gap: gap, obstacles: [], bounds: offsetBounds
        )

        XCTAssertEqual(nearMin, CGRect(x: 108, y: 50, width: 320, height: 800))
        XCTAssertEqual(nearMax, CGRect(x: 772, y: 50, width: 320, height: 800))
    }

    /// Negative edgeInset is treated as 0: right-edge fixture (anchor
    /// (990, 300)), raw "above" x = 830; with inset 0 the upper bound is
    /// 1000-0-320 = 680 -> (680, 212), same as edgeInset 0. Never
    /// overhangs bounds.
    func test_place_negativeEdgeInset_treatedAsZero() {
        let anchor = CGPoint(x: 990, y: 300)

        let rect = MissionMapPopoverPlacement.place(
            extent: extent, anchor: anchor, gap: gap, edgeInset: -20, obstacles: [], bounds: bounds
        )

        XCTAssertEqual(rect, CGRect(x: 680, y: 212, width: 320, height: 80))
        XCTAssertLessThanOrEqual(rect.maxX, bounds.maxX)
    }

    /// Bubble 1200x800 in bounds (100, 50, 1000x700): larger on both
    /// axes, so the inset is max(0, negative) = 0 and the rect's min
    /// edge sits on bounds' min edge: origin (100, 50).
    func test_place_extentLargerThanBounds_pinsOriginToBoundsOrigin() {
        let bigExtent = CGSize(width: 1200, height: 800)
        let offsetBounds = CGRect(x: 100, y: 50, width: 1000, height: 700)

        let rect = MissionMapPopoverPlacement.place(
            extent: bigExtent, anchor: CGPoint(x: 500, y: 350), gap: gap, obstacles: [], bounds: offsetBounds
        )

        XCTAssertEqual(rect.origin, offsetBounds.origin)
        XCTAssertEqual(rect.size, bigExtent)
    }

    func test_defaultEdgeInset_isEight() {
        XCTAssertEqual(MissionMapPopoverPlacement.defaultEdgeInset, 8)
    }

    /// Right-edge fixture with explicit insets: 20 -> x = 1000-20-320 = 660;
    /// 0 -> the old flush behavior, x = 1000-320 = 680. y = 212 both.
    func test_place_explicitEdgeInset_isHonored() {
        let anchor = CGPoint(x: 990, y: 300)

        let inset20 = MissionMapPopoverPlacement.place(
            extent: extent, anchor: anchor, gap: gap, edgeInset: 20, obstacles: [], bounds: bounds
        )
        let inset0 = MissionMapPopoverPlacement.place(
            extent: extent, anchor: anchor, gap: gap, edgeInset: 0, obstacles: [], bounds: bounds
        )

        XCTAssertEqual(inset20, CGRect(x: 660, y: 212, width: 320, height: 80))
        XCTAssertEqual(inset0, CGRect(x: 680, y: 212, width: 320, height: 80))
    }

    /// One obstacle covering the whole bounds: every candidate, once
    /// clamped into bounds, is fully contained in the obstacle, so every
    /// candidate scores the same (320*80 = 25600) and the tie goes to
    /// the first candidate, "above": x 340...660 (centered on anchor.x =
    /// 500), y 262...342 (bottom = 350-8 = 342, top = 262).
    func test_place_fullyPackedObstacles_returnsFirstCandidateDeterministically() {
        let anchor = CGPoint(x: 500, y: 350)
        let obstacle = bounds

        let rect = MissionMapPopoverPlacement.place(
            extent: extent, anchor: anchor, gap: gap, obstacles: [obstacle], bounds: bounds
        )

        XCTAssertEqual(rect, CGRect(x: 340, y: 262, width: 320, height: 80))
        XCTAssertTrue(bounds.contains(rect.origin))
        XCTAssertLessThanOrEqual(rect.maxX, bounds.maxX)
        XCTAssertLessThanOrEqual(rect.maxY, bounds.maxY)
    }

    /// score(_:obstacles:) sums intersection areas over several
    /// obstacles: a 100x100 rect at the origin against an obstacle that
    /// overlaps it by 50x50 (2500), one fully inside it 20x20 (400), and
    /// one entirely outside it (0). Total: 2900.
    func test_score_sumsOverlapAreasAcrossObstacles() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let obstacles = [
            CGRect(x: 50, y: 50, width: 100, height: 100),
            CGRect(x: 0, y: 0, width: 20, height: 20),
            CGRect(x: 200, y: 200, width: 10, height: 10),
        ]

        XCTAssertEqual(MissionMapPopoverPlacement.score(rect, obstacles: obstacles), 2900)
    }
}
