import XCTest
@testable import WhatCable

/// Cover for `UpdateChecker.isStale`, the throttle that decides whether opening
/// the menu panel triggers a fresh update check (issue #372). Keeps the panel
/// from hitting GitHub on every open while still refreshing a stale version.
final class UpdateCheckerThrottleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let halfHour: TimeInterval = 30 * 60

    func testNeverCheckedIsStale() {
        XCTAssertTrue(
            UpdateChecker.isStale(lastCheck: nil, now: now, staleAfter: halfHour),
            "With no prior check, a check is always due"
        )
    }

    func testRecentCheckIsNotStale() {
        let fiveMinutesAgo = now.addingTimeInterval(-5 * 60)
        XCTAssertFalse(
            UpdateChecker.isStale(lastCheck: fiveMinutesAgo, now: now, staleAfter: halfHour),
            "A check 5 minutes ago is fresh; opening the panel must not re-check"
        )
    }

    func testOldCheckIsStale() {
        let fortyMinutesAgo = now.addingTimeInterval(-40 * 60)
        XCTAssertTrue(
            UpdateChecker.isStale(lastCheck: fortyMinutesAgo, now: now, staleAfter: halfHour),
            "A check 40 minutes ago is stale; opening the panel should re-check"
        )
    }

    func testOneSecondBeforeBoundaryIsNotStale() {
        let justUnder = now.addingTimeInterval(-(halfHour - 1))
        XCTAssertFalse(
            UpdateChecker.isStale(lastCheck: justUnder, now: now, staleAfter: halfHour),
            "One second before the threshold the check is not yet due (guards a >= to > regression)"
        )
    }

    func testExactBoundaryIsStale() {
        let exactlyHalfHourAgo = now.addingTimeInterval(-halfHour)
        XCTAssertTrue(
            UpdateChecker.isStale(lastCheck: exactlyHalfHourAgo, now: now, staleAfter: halfHour),
            "At exactly the interval the boundary is inclusive, so a check is due"
        )
    }
}
