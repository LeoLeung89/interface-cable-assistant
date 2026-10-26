import XCTest
@testable import WhatCable

/// `NotificationClickPresentation.decide(isAppActive:)` is the pure
/// active/not-active -> present-now/defer decision behind the
/// notification-click popover race fix. See its doc comment for why the
/// app's active state is the gate: presenting a `.transient` popover before
/// the app's own activation handover has actually finished reads as a
/// click-away and the popover closes itself again almost instantly.
final class NotificationClickPresentationTests: XCTestCase {
    func testActiveAppPresentsImmediately() {
        XCTAssertEqual(NotificationClickPresentation.decide(isAppActive: true), .presentNow)
    }

    func testInactiveAppDefersUntilActivation() {
        XCTAssertEqual(NotificationClickPresentation.decide(isAppActive: false), .activateThenPresentOnActivation)
    }
}
