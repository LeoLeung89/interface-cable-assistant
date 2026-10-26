import XCTest
@testable import WhatCable

/// `LaunchInstanceDecision.decide` is the pure election behind the
/// single-instance fix for issue #455. See its doc comment for why it
/// keys on launch date (a stable, immutable fact) rather than
/// `isFinishedLaunching` (a transient flag that flips to true on a
/// deferring copy mid-handover, which produced a mutual-defer race where
/// both copies terminate).
final class LaunchInstanceDecisionTests: XCTestCase {
    func testNoOtherInstanceContinuesLaunch() {
        XCTAssertEqual(
            LaunchInstanceDecision.decide(
                otherExists: false,
                myLaunch: Date(),
                otherLaunch: nil,
                myPID: 100,
                otherPID: 0
            ),
            .continueLaunch
        )
    }

    func testEarlierMyLaunchDateContinues() {
        let earlier = Date(timeIntervalSince1970: 1000)
        let later = Date(timeIntervalSince1970: 2000)
        // My PID is higher, but my launch date is earlier, so I still win.
        XCTAssertEqual(
            LaunchInstanceDecision.decide(
                otherExists: true,
                myLaunch: earlier,
                otherLaunch: later,
                myPID: 500,
                otherPID: 100
            ),
            .continueLaunch
        )
    }

    func testEarlierOtherLaunchDateDefers() {
        let earlier = Date(timeIntervalSince1970: 1000)
        let later = Date(timeIntervalSince1970: 2000)
        // My PID is lower, but the other process launched first, so it wins.
        XCTAssertEqual(
            LaunchInstanceDecision.decide(
                otherExists: true,
                myLaunch: later,
                otherLaunch: earlier,
                myPID: 100,
                otherPID: 500
            ),
            .deferToRunningInstance
        )
    }

    func testEqualDatesLowerPIDContinues() {
        let same = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(
            LaunchInstanceDecision.decide(
                otherExists: true,
                myLaunch: same,
                otherLaunch: same,
                myPID: 100,
                otherPID: 200
            ),
            .continueLaunch
        )
    }

    func testEqualDatesHigherPIDDefers() {
        let same = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(
            LaunchInstanceDecision.decide(
                otherExists: true,
                myLaunch: same,
                otherLaunch: same,
                myPID: 200,
                otherPID: 100
            ),
            .deferToRunningInstance
        )
    }

    func testNilMyLaunchDateFallsBackToPIDLowerContinues() {
        XCTAssertEqual(
            LaunchInstanceDecision.decide(
                otherExists: true,
                myLaunch: nil,
                otherLaunch: Date(),
                myPID: 100,
                otherPID: 200
            ),
            .continueLaunch
        )
    }

    func testNilOtherLaunchDateFallsBackToPIDHigherDefers() {
        XCTAssertEqual(
            LaunchInstanceDecision.decide(
                otherExists: true,
                myLaunch: Date(),
                otherLaunch: nil,
                myPID: 200,
                otherPID: 100
            ),
            .deferToRunningInstance
        )
    }
}
