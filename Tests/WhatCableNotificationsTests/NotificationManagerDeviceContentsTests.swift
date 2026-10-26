import XCTest
import WhatCableCore
import WhatCableNotifications

/// A reviewer forced the reconnect branch in `diffDevices` off and rebuilt:
/// all 5 pure-helper tests for `isReconnectPair` /
/// `reconnectedNotificationContent`, plus the full `NotificationManager*`
/// filter, still passed. The gate condition itself (exactly one removed
/// group and one added group, matching, applied ahead of the usual
/// removed-then-added composition) had zero test coverage; it only ran
/// inside `diffDevices`, which needs `UNUserNotificationCenter` and
/// `WatcherHub` to exercise. `deviceNotificationContents` is the whole batch
/// decision extracted as one pure function so the gate is testable directly.
final class NotificationManagerDeviceContentsTests: XCTestCase {
    /// Builds real `ChangeGroup`s via `USBDeviceChangeGrouper.diff` rather
    /// than constructing them directly, matching the sibling content test
    /// files. See `NotificationManagerAddedContentTests`'s snapshot helper
    /// doc for the locationID nibble scheme.
    private func snapshot(id: UInt64, locationID: UInt32, name: String) -> USBDeviceChangeGrouper.Snapshot {
        USBDeviceChangeGrouper.Snapshot(id: id, locationID: locationID, name: name)
    }

    private func removedGroups(from snapshots: [USBDeviceChangeGrouper.Snapshot]) -> [USBDeviceChangeGrouper.ChangeGroup] {
        USBDeviceChangeGrouper.diff(previous: snapshots, current: []).removed
    }

    private func addedGroups(from snapshots: [USBDeviceChangeGrouper.Snapshot]) -> [USBDeviceChangeGrouper.ChangeGroup] {
        USBDeviceChangeGrouper.diff(previous: [], current: snapshots).added
    }

    /// The gate's core case: one device drops and returns at the same port
    /// with the same name. Exactly one "Reconnected:" content, nothing else.
    func testMatchedOneToOnePairProducesOnlyAReconnectContent() {
        let removed = removedGroups(from: [snapshot(id: 1, locationID: 0x01100000, name: "SSD Enclosure")])
        let added = addedGroups(from: [snapshot(id: 2, locationID: 0x01100000, name: "SSD Enclosure")])

        let contents = NotificationDecision.deviceNotificationContents(
            removedGroups: removed,
            addedGroups: added
        ) { _ in nil }

        XCTAssertEqual(contents, [
            NotificationContent(title: "Reconnected: SSD Enclosure", body: "")
        ])
    }

    /// Two removed groups and two added groups, even though each pair would
    /// individually match on port and name, must NOT reconnect-pair: the
    /// gate is EXACTLY one removed and EXACTLY one added, no more. Falls
    /// back to the existing multi-group merge (one "USB devices
    /// disconnected" content, one "USB devices connected" content).
    func testTwoRemovedAndTwoAddedNeverReconnectsEvenWhenNamesAndPortsMatch() {
        let snapshots = [
            snapshot(id: 1, locationID: 0x01100000, name: "SSD Enclosure"),
            snapshot(id: 2, locationID: 0x01200000, name: "USB Hub")
        ]
        let removed = removedGroups(from: snapshots)
        let added = addedGroups(from: [
            snapshot(id: 3, locationID: 0x01100000, name: "SSD Enclosure"),
            snapshot(id: 4, locationID: 0x01200000, name: "USB Hub")
        ])
        XCTAssertEqual(removed.count, 2, "fixture should produce 2 removed groups; test is invalid otherwise")
        XCTAssertEqual(added.count, 2, "fixture should produce 2 added groups; test is invalid otherwise")

        let contents = NotificationDecision.deviceNotificationContents(
            removedGroups: removed,
            addedGroups: added
        ) { _ in nil }

        XCTAssertEqual(contents.count, 2)
        XCTAssertEqual(contents[0].title, "USB devices disconnected")
        XCTAssertEqual(contents[1].title, "USB devices connected")
        XCTAssertFalse(contents.contains { $0.title.hasPrefix("Reconnected") })
    }

    /// One removed, one added, but NOT a match (different port): falls back
    /// to the existing single-group "Disconnected" then "Connected" pair,
    /// removed ordered before added.
    func testOneToOneNonMatchingPairFallsBackToDisconnectedThenConnected() {
        let removed = removedGroups(from: [snapshot(id: 1, locationID: 0x01100000, name: "SSD Enclosure")])
        let added = addedGroups(from: [snapshot(id: 2, locationID: 0x01200000, name: "SSD Enclosure")])

        let contents = NotificationDecision.deviceNotificationContents(
            removedGroups: removed,
            addedGroups: added
        ) { _ in nil }

        XCTAssertEqual(contents, [
            NotificationContent(title: "Disconnected: SSD Enclosure", body: ""),
            NotificationContent(title: "Connected: SSD Enclosure", body: "")
        ])
    }

    /// Removes only: unchanged single "Disconnected" content, no reconnect.
    func testRemovesOnlyIsUnchanged() {
        let removed = removedGroups(from: [snapshot(id: 1, locationID: 0x01100000, name: "SSD Enclosure")])

        let contents = NotificationDecision.deviceNotificationContents(
            removedGroups: removed,
            addedGroups: []
        ) { _ in nil }

        XCTAssertEqual(contents, [
            NotificationContent(title: "Disconnected: SSD Enclosure", body: "")
        ])
    }

    /// Adds only: unchanged single "Connected" content, no reconnect.
    func testAddsOnlyIsUnchanged() {
        let added = addedGroups(from: [snapshot(id: 1, locationID: 0x01100000, name: "SSD Enclosure")])

        let contents = NotificationDecision.deviceNotificationContents(
            removedGroups: [],
            addedGroups: added
        ) { _ in nil }

        XCTAssertEqual(contents, [
            NotificationContent(title: "Connected: SSD Enclosure", body: "")
        ])
    }
}
