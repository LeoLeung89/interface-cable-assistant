import XCTest
import WhatCableCore
import WhatCableNotifications

/// Issue #570 part 1: when the settle window's batch involves a Thunderbolt
/// device (a downstream TB fabric switch appeared or disappeared alongside
/// the USB diff), the MERGED titles read "Thunderbolt devices connected" /
/// "Thunderbolt devices disconnected" instead of "USB devices ...". Two
/// halves are covered here: the pure `thunderboltInvolved` derivation
/// (this file's first section) and the content-decision wiring that swaps
/// the title (second section). `DeviceDiffSequencerTests` covers the third
/// half: the sequencer actually deriving the flag from a live TB-switch-ID
/// closure and threading it through to `deviceNotificationContents`.
final class NotificationManagerThunderboltInvolvedTests: XCTestCase {
    // MARK: - Pure rule: NotificationDecision.thunderboltInvolved(previous:current:)

    /// A downstream TB switch appearing (baseline empty, current has one) is
    /// involvement.
    ///
    /// Red-proof: flip the `!=` in `thunderboltInvolved` to `==` and this
    /// goes red (asserts true, gets false).
    func testSwitchAppearingIsInvolved() {
        XCTAssertTrue(NotificationDecision.thunderboltInvolved(previous: [], current: [42]))
    }

    /// A downstream TB switch disappearing (baseline has one, current empty)
    /// is involvement, the other direction.
    ///
    /// Red-proof: same `!=` -> `==` flip goes red here too (asserts true,
    /// gets false), proving both directions are actually exercised and not
    /// just one arm of a broken comparison.
    func testSwitchDisappearingIsInvolved() {
        XCTAssertTrue(NotificationDecision.thunderboltInvolved(previous: [42], current: []))
    }

    /// No change to the downstream set (same single switch, or both empty)
    /// is NOT involvement.
    ///
    /// Red-proof: hardcode the function body to `return true` and this goes
    /// red (asserts false, gets true).
    func testNoChangeIsNotInvolved() {
        XCTAssertFalse(NotificationDecision.thunderboltInvolved(previous: [42], current: [42]))
        XCTAssertFalse(NotificationDecision.thunderboltInvolved(previous: [], current: []))
    }

    /// One switch appears AND a different one disappears within the same
    /// settle window: net count is unchanged (still one switch), but the SET
    /// changed, so this must still read as involvement. This is the case a
    /// naive "count went up or down" check would miss.
    ///
    /// Red-proof: swap the rule for `previous.count != current.count` (a
    /// plausible-looking but wrong simplification) and this goes red
    /// (asserts true, gets false, since both sides have exactly one ID).
    func testAppearAndDisappearInTheSameWindowIsInvolved() {
        XCTAssertTrue(NotificationDecision.thunderboltInvolved(previous: [42], current: [43]))
    }

    // MARK: - Content: merged titles flip with the flag; single-group and
    // reconnect titles never do.

    private func snapshot(id: UInt64, locationID: UInt32, name: String) -> USBDeviceChangeGrouper.Snapshot {
        USBDeviceChangeGrouper.Snapshot(id: id, locationID: locationID, name: name)
    }

    /// Three added groups (mirrors the existing merge test's dock fixture),
    /// `thunderboltInvolved: true`, must read "Thunderbolt devices
    /// connected" in place of "USB devices connected". Body composition is
    /// untouched.
    ///
    /// Red-proof: delete the `thunderboltInvolved ? ... : ...` ternary in
    /// `addedNotificationContents` and always use the USB string; this goes
    /// red (expects "Thunderbolt devices connected", gets "USB devices
    /// connected").
    func testMergedAddedTitleFlipsToThunderboltWhenInvolved() {
        let current = [
            snapshot(id: 1, locationID: 0x01100000, name: "USB3 Hub"),
            snapshot(id: 3, locationID: 0x01200000, name: "USB2 Hub"),
            snapshot(id: 4, locationID: 0x01300000, name: "PD Device")
        ]
        let (added, _) = USBDeviceChangeGrouper.diff(previous: [], current: current)
        XCTAssertEqual(added.count, 3, "fixture should produce 3 groups; test is invalid otherwise")

        let contents = NotificationDecision.addedNotificationContents(groups: added, thunderboltInvolved: true) { _ in nil }

        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(contents.first?.title, "Thunderbolt devices connected")
    }

    /// Same fixture, removed side: "Thunderbolt devices disconnected" in
    /// place of "USB devices disconnected".
    ///
    /// Red-proof: same ternary deletion in `removedNotificationContents`
    /// goes red (expects the Thunderbolt string, gets the USB one).
    func testMergedRemovedTitleFlipsToThunderboltWhenInvolved() {
        let previous = [
            snapshot(id: 1, locationID: 0x01100000, name: "USB3 Hub"),
            snapshot(id: 3, locationID: 0x01200000, name: "USB2 Hub"),
            snapshot(id: 4, locationID: 0x01300000, name: "PD Device")
        ]
        let (_, removed) = USBDeviceChangeGrouper.diff(previous: previous, current: [])
        XCTAssertEqual(removed.count, 3, "fixture should produce 3 groups; test is invalid otherwise")

        let contents = NotificationDecision.removedNotificationContents(groups: removed, thunderboltInvolved: true)

        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(contents.first?.title, "Thunderbolt devices disconnected")
    }

    /// `thunderboltInvolved: false` (the default) must produce a
    /// byte-identical title to today's wording: the merge path is only ever
    /// reached with the parameter explicitly threaded through by
    /// `DeviceDiffSequencer`, so a caller that never passes it (every
    /// existing call site) must see no behaviour change at all.
    ///
    /// Red-proof: hardcode the Thunderbolt string unconditionally in
    /// `addedNotificationContents`; this goes red (expects "USB devices
    /// connected", gets "Thunderbolt devices connected").
    func testFlagFalseKeepsTodaysMergedTitleByteIdentical() {
        let current = [
            snapshot(id: 1, locationID: 0x01100000, name: "USB3 Hub"),
            snapshot(id: 3, locationID: 0x01200000, name: "USB2 Hub"),
            snapshot(id: 4, locationID: 0x01300000, name: "PD Device")
        ]
        let (added, _) = USBDeviceChangeGrouper.diff(previous: [], current: current)

        let contents = NotificationDecision.addedNotificationContents(groups: added) { _ in nil }

        XCTAssertEqual(contents.first?.title, "USB devices connected")
    }

    /// A single-group add (no merge) must keep "Connected: <name>" even with
    /// `thunderboltInvolved: true`: the outcome only names the two MERGED
    /// titles, never the single-device ones.
    ///
    /// Red-proof: move the ternary above the `groups.count == 1` branch so
    /// it applies there too; this goes red (expects "Connected: SSD
    /// Enclosure", gets a Thunderbolt-flavoured title).
    func testSingleGroupAddedTitleNeverFlipsEvenWhenInvolved() {
        let current = [snapshot(id: 7, locationID: 0x01100000, name: "SSD Enclosure")]
        let (added, _) = USBDeviceChangeGrouper.diff(previous: [], current: current)

        let contents = NotificationDecision.addedNotificationContents(groups: added, thunderboltInvolved: true) { _ in nil }

        XCTAssertEqual(contents.first?.title, "Connected: SSD Enclosure")
    }

    /// A single-group remove (no merge) must keep "Disconnected: <name>"
    /// even with `thunderboltInvolved: true`.
    ///
    /// Red-proof: same ternary-hoist mutation on the removed side goes red
    /// (expects "Disconnected: SSD Enclosure", gets a flipped title).
    func testSingleGroupRemovedTitleNeverFlipsEvenWhenInvolved() {
        let previous = [snapshot(id: 7, locationID: 0x01100000, name: "SSD Enclosure")]
        let (_, removed) = USBDeviceChangeGrouper.diff(previous: previous, current: [])

        let contents = NotificationDecision.removedNotificationContents(groups: removed, thunderboltInvolved: true)

        XCTAssertEqual(contents.first?.title, "Disconnected: SSD Enclosure")
    }

    /// The reconnect gate (one removed, one added, same port and name) must
    /// keep "Reconnected: <name>" even with `thunderboltInvolved: true`:
    /// `deviceNotificationContents` never threads the flag into
    /// `reconnectedNotificationContent` at all.
    ///
    /// Red-proof: pass `thunderboltInvolved` into
    /// `reconnectedNotificationContent` and have it flip the title the same
    /// way the merge paths do; this goes red (expects "Reconnected: SSD
    /// Enclosure", gets a flipped title).
    func testReconnectTitleNeverFlipsEvenWhenInvolved() {
        let (_, removed) = USBDeviceChangeGrouper.diff(
            previous: [snapshot(id: 1, locationID: 0x01100000, name: "SSD Enclosure")],
            current: []
        )
        let (added, _) = USBDeviceChangeGrouper.diff(
            previous: [],
            current: [snapshot(id: 2, locationID: 0x01100000, name: "SSD Enclosure")]
        )

        let contents = NotificationDecision.deviceNotificationContents(
            removedGroups: removed,
            addedGroups: added,
            thunderboltInvolved: true
        ) { _ in nil }

        XCTAssertEqual(contents, [
            NotificationContent(title: "Reconnected: SSD Enclosure", body: "")
        ])
    }
}
