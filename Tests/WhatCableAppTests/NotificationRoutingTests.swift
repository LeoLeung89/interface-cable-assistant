import XCTest
@testable import WhatCable

/// `NotificationRouting.action(for:)` is the pure identifier -> action
/// mapping the notification delegate uses, extracted so it's testable
/// without `UNUserNotificationCenter` (see issue #567).
final class NotificationRoutingTests: XCTestCase {
    func testUpdateIdentifierOpensPopoverShowingUpdate() {
        XCTAssertEqual(NotificationRouting.action(for: "update-1.5.0"), .openPopoverShowingUpdate)
    }

    func testDeviceIdentifierOpensPopover() {
        XCTAssertEqual(NotificationRouting.action(for: "device-event"), .openPopover)
    }

    func testChargerIdentifierOpensPopover() {
        XCTAssertEqual(NotificationRouting.action(for: "charger-event"), .openPopover)
    }

    func testUnknownIdentifierFallsBackToOpeningThePopover() {
        XCTAssertEqual(NotificationRouting.action(for: "some-stale-identifier"), .openPopover)
    }
}
