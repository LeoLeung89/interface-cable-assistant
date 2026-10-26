import XCTest
import WhatCableCore
import WhatCableNotifications

/// A device that drops and returns within one settle window used to read as
/// a plain "Connected: <name>" (the removal's "Disconnected" got replaced in
/// place by the later "Connected" post, per issue #567's shared identifier),
/// silently absorbing the flap. `isReconnectPair` and
/// `reconnectedNotificationContent` are the pure decisions behind the
/// "Reconnected: <name>" wording, extracted so the narrow trigger condition
/// (exactly one removed group and one added group, matching by physical
/// port) is testable without `UNUserNotificationCenter`.
final class NotificationManagerReconnectContentTests: XCTestCase {
    /// Builds real `ChangeGroup`s via `USBDeviceChangeGrouper.diff` rather
    /// than constructing them directly, matching
    /// `NotificationManagerAddedContentTests`. See that file's snapshot
    /// helper doc for the locationID nibble scheme.
    private func snapshot(id: UInt64, locationID: UInt32, name: String) -> USBDeviceChangeGrouper.Snapshot {
        USBDeviceChangeGrouper.Snapshot(id: id, locationID: locationID, name: name)
    }

    // MARK: - isReconnectPair

    func testSamePortSameNameIsAReconnectPair() {
        let previous = [snapshot(id: 1, locationID: 0x01100000, name: "SSD Enclosure")]
        let current = [snapshot(id: 2, locationID: 0x01100000, name: "SSD Enclosure")]
        let (added, removed) = USBDeviceChangeGrouper.diff(previous: previous, current: current)

        let removedGroup = try! XCTUnwrap(removed.first)
        let addedGroup = try! XCTUnwrap(added.first)

        XCTAssertTrue(NotificationDecision.isReconnectPair(removed: removedGroup, added: addedGroup))
    }

    /// A device swapped on the same physical port within the settle window
    /// (different product, same locationID) is NOT a reconnect: pinned per
    /// the spec's acceptance criteria.
    func testSamePortDifferentNameIsNotAReconnectPair() {
        let previous = [snapshot(id: 1, locationID: 0x01100000, name: "SSD Enclosure")]
        let current = [snapshot(id: 2, locationID: 0x01100000, name: "USB Hub")]
        let (added, removed) = USBDeviceChangeGrouper.diff(previous: previous, current: current)

        let removedGroup = try! XCTUnwrap(removed.first)
        let addedGroup = try! XCTUnwrap(added.first)

        XCTAssertFalse(NotificationDecision.isReconnectPair(removed: removedGroup, added: addedGroup))
    }

    /// Same product name on a different physical port (e.g. the same model
    /// of enclosure plugged into a different bay) is a coincidence, not a
    /// reconnect: the port persists across a re-enumeration, the name alone
    /// does not identify a physical device.
    func testDifferentPortSameNameIsNotAReconnectPair() {
        let previous = [snapshot(id: 1, locationID: 0x01100000, name: "SSD Enclosure")]
        let current = [snapshot(id: 2, locationID: 0x01200000, name: "SSD Enclosure")]
        let (added, removed) = USBDeviceChangeGrouper.diff(previous: previous, current: current)

        let removedGroup = try! XCTUnwrap(removed.first)
        let addedGroup = try! XCTUnwrap(added.first)

        XCTAssertFalse(NotificationDecision.isReconnectPair(removed: removedGroup, added: addedGroup))
    }

    // MARK: - reconnectedNotificationContent

    func testReconnectContentTitlesWithRootNameAndListsMembers() {
        let current = [
            snapshot(id: 1, locationID: 0x01100000, name: "Dock"),
            snapshot(id: 2, locationID: 0x01110000, name: "Hub")
        ]
        let (added, _) = USBDeviceChangeGrouper.diff(previous: [], current: current)
        let group = try! XCTUnwrap(added.first)

        let content = NotificationDecision.reconnectedNotificationContent(for: group) { _ in nil }

        XCTAssertEqual(content, NotificationContent(title: "Reconnected: Dock", body: "Hub"))
    }

    func testReconnectContentForMemberlessGroupUsesSpeedVendorBody() {
        let current = [snapshot(id: 7, locationID: 0x01100000, name: "SSD Enclosure")]
        let (added, _) = USBDeviceChangeGrouper.diff(previous: [], current: current)
        let group = try! XCTUnwrap(added.first)

        let content = NotificationDecision.reconnectedNotificationContent(for: group) { rootID in
            rootID == 7 ? "10 Gbps · Vendor Co" : nil
        }

        XCTAssertEqual(
            content,
            NotificationContent(title: "Reconnected: SSD Enclosure", body: "10 Gbps · Vendor Co")
        )
    }
}
