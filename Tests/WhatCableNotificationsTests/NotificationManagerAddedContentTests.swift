import XCTest
import WhatCableCore
import WhatCableNotifications

/// `postAddedGroupNotifications` posted one `UNUserNotificationCenter.add`
/// PER group, so a dock spanning several subtrees (main USB3 hub, USB2
/// companion hubs, PD device) fired 2-3 simultaneous banners with only the
/// last one visible, and most devices never showed as "connected" even
/// though they were posted. `addedNotificationContents` is the pure decision
/// extracted from that method so the merge (mirroring the already-correct
/// removal path) is testable without `UNUserNotificationCenter`. See issue
/// #556.
final class NotificationManagerAddedContentTests: XCTestCase {
    /// Builds real `ChangeGroup`s via `USBDeviceChangeGrouper.diff` rather
    /// than constructing them directly: the memberwise init is internal to
    /// `WhatCableCore`, and diffing a fixture "connect" is closer to how
    /// production actually produces groups anyway.
    ///
    /// `locationID` follows the nibble-encoded USB location ID scheme
    /// (`USBDevice.parentLocationID`): a location with a single nonzero
    /// nibble at bit position 20 (e.g. `0x01100000`) is a top-level root;
    /// setting the next nibble down (bit position 16, e.g. `0x01110000`)
    /// makes it a child of that root.
    private func snapshot(id: UInt64, locationID: UInt32, name: String) -> USBDeviceChangeGrouper.Snapshot {
        USBDeviceChangeGrouper.Snapshot(id: id, locationID: locationID, name: name)
    }

    func testSingleGroupWithMembersListsThemInBody() {
        let current = [
            snapshot(id: 1, locationID: 0x01100000, name: "Dock"),
            snapshot(id: 2, locationID: 0x01110000, name: "Hub"),
            snapshot(id: 3, locationID: 0x01120000, name: "Card Reader")
        ]
        let (added, _) = USBDeviceChangeGrouper.diff(previous: [], current: current)

        let contents = NotificationDecision.addedNotificationContents(groups: added) { _ in nil }

        XCTAssertEqual(contents, [
            NotificationContent(title: "Connected: Dock", body: "Hub\nCard Reader")
        ])
    }

    func testSingleMemberlessGroupUsesSpeedVendorBody() {
        let current = [snapshot(id: 7, locationID: 0x01100000, name: "SSD Enclosure")]
        let (added, _) = USBDeviceChangeGrouper.diff(previous: [], current: current)

        let contents = NotificationDecision.addedNotificationContents(groups: added) { rootID in
            rootID == 7 ? "10 Gbps · Vendor Co" : nil
        }

        XCTAssertEqual(contents, [
            NotificationContent(title: "Connected: SSD Enclosure", body: "10 Gbps · Vendor Co")
        ])
    }

    func testThreeGroupsMergeIntoOneMergedNotification() {
        // Three independent top-level roots (distinct top-level ports on the
        // same bus), mirroring a dock's split subtrees: main USB3 hub with a
        // member, a standalone USB2 companion hub, and a PD device with a
        // member.
        let current = [
            snapshot(id: 1, locationID: 0x01100000, name: "USB3 Hub"),
            snapshot(id: 2, locationID: 0x01110000, name: "Card Reader"),
            snapshot(id: 3, locationID: 0x01200000, name: "USB2 Hub"),
            snapshot(id: 4, locationID: 0x01300000, name: "PD Device"),
            snapshot(id: 5, locationID: 0x01310000, name: "Charger Port")
        ]
        let (added, _) = USBDeviceChangeGrouper.diff(previous: [], current: current)
        XCTAssertEqual(added.count, 3, "fixture should produce 3 groups; test is invalid otherwise")

        let contents = NotificationDecision.addedNotificationContents(groups: added) { _ in nil }

        // Exactly one notification, titled with the merged key, listing every
        // root and member in group order, root before its own members: same
        // shape as the removal-path merge (issue #556).
        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(contents.first?.title, "USB devices connected")
        XCTAssertEqual(
            contents.first?.body,
            "USB3 Hub\nCard Reader\nUSB2 Hub\nPD Device\nCharger Port"
        )
    }
}
