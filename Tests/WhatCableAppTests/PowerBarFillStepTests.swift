import XCTest
@testable import WhatCable

/// The menu bar power bar (issue #366) quantises live watts into discrete fill
/// steps so it sits still instead of twitching. This covers the quantisation
/// against the charger's rating, the unknown-rating fallback, and clamping.
final class PowerBarFillStepTests: XCTestCase {
    // 10 steps total, so each step is 10% of the rated wattage.

    func testFullAndEmpty() {
        // 0 W -> empty; rated W -> full.
        XCTAssertEqual(AppDelegate.powerBarFillStep(watts: 0, rated: 70), 0)
        XCTAssertEqual(AppDelegate.powerBarFillStep(watts: 70, rated: 70), 10)
    }

    func testQuantisesToNearestStep() {
        // 35/70 = 0.5 -> step 5.
        XCTAssertEqual(AppDelegate.powerBarFillStep(watts: 35, rated: 70), 5)
        // 21/70 = 0.30 -> 3.0 -> step 3.
        XCTAssertEqual(AppDelegate.powerBarFillStep(watts: 21, rated: 70), 3)
        // 24/70 = 0.342 -> 3.42 -> rounds to step 3.
        XCTAssertEqual(AppDelegate.powerBarFillStep(watts: 24, rated: 70), 3)
        // 26/70 = 0.371 -> 3.71 -> rounds to step 4.
        XCTAssertEqual(AppDelegate.powerBarFillStep(watts: 26, rated: 70), 4)
    }

    func testClampsAboveRated() {
        // Drawing more than the rating (shouldn't happen, but be safe) clamps to full.
        XCTAssertEqual(AppDelegate.powerBarFillStep(watts: 140, rated: 70), 10)
    }

    func testUnknownRatingUsesFallbackScale() {
        // rated == 0 -> 100 W fallback scale. 50/100 = 0.5 -> step 5.
        XCTAssertEqual(AppDelegate.powerBarFillStep(watts: 50, rated: 0), 5)
        // 100/100 = 1.0 -> step 10.
        XCTAssertEqual(AppDelegate.powerBarFillStep(watts: 100, rated: 0), 10)
        // 5/100 = 0.05 -> 0.5 -> rounds to step 1 (Foundation rounds halves away from zero).
        XCTAssertEqual(AppDelegate.powerBarFillStep(watts: 5, rated: 0), 1)
    }

    func testAnyPositiveDrawShowsAtLeastOneStep() {
        // A tiny draw rounds to 0 but must floor to step 1, so the bar shows a
        // visible nub while charging instead of an empty track.
        // 1/100 = 0.01 -> 0.1 -> rounds to 0 -> floored to 1.
        XCTAssertEqual(AppDelegate.powerBarFillStep(watts: 1, rated: 100), 1)
        // 2/140 = 0.014 -> 0.14 -> rounds to 0 -> floored to 1.
        XCTAssertEqual(AppDelegate.powerBarFillStep(watts: 2, rated: 140), 1)
    }

    func testNonPositiveWattsIsEmpty() {
        // Zero (and any non-positive) draw is an empty bar, no floor applied.
        XCTAssertEqual(AppDelegate.powerBarFillStep(watts: 0, rated: 100), 0)
        XCTAssertEqual(AppDelegate.powerBarFillStep(watts: -5, rated: 100), 0)
    }
}
