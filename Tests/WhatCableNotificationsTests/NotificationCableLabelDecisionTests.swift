import XCTest
import WhatCableCore
@testable import WhatCableNotifications

/// Issue #570 part B (saved-cable notification labels), the pure half:
/// `NotificationDecision.cableLabelChange` (the key-set diff) and
/// `NotificationDecision.isPortLevelChange` / `batchNeedsCablePlausibilityHold`
/// (the cable-plausibility gate). `DeviceDiffSequencerTests` covers the
/// timing/hold machinery these feed into.
final class NotificationCableLabelDecisionTests: XCTestCase {

    // MARK: - cableLabelChange

    /// Exactly one key appearing is a connect-direction change.
    ///
    /// Red-proof: flip `wasAdded: true` to `false` in the `current[id]`
    /// branch and this goes red.
    func testExactlyOneKeyAppearedIsAddedChange() {
        let change = NotificationDecision.cableLabelChange(previous: [:], current: ["a": "Apple TB 1m"])
        XCTAssertEqual(change?.name, "Apple TB 1m")
        XCTAssertEqual(change?.wasAdded, true)
    }

    /// Exactly one key vanishing is a disconnect-direction change.
    ///
    /// Red-proof: flip `wasAdded: false` to `true` in the `previous[id]`
    /// branch and this goes red.
    func testExactlyOneKeyVanishedIsRemovedChange() {
        let change = NotificationDecision.cableLabelChange(previous: ["a": "Apple TB 1m"], current: [:])
        XCTAssertEqual(change?.name, "Apple TB 1m")
        XCTAssertEqual(change?.wasAdded, false)
    }

    /// Zero changes -> nil.
    ///
    /// Red-proof: change `changedIDs.count == 1` to `>= 0` and this goes
    /// red (asserts nil, gets a value).
    func testNoChangeIsNil() {
        XCTAssertNil(NotificationDecision.cableLabelChange(previous: ["a": "X"], current: ["a": "X"]))
    }

    /// Two-or-more changes -> nil (ambiguous). Covers both a genuine
    /// two-cable swap and the "exactly-one rule" the spec names.
    ///
    /// Red-proof: change `changedIDs.count == 1` to `<= 2` and this goes
    /// red.
    func testTwoChangesIsAmbiguousNil() {
        XCTAssertNil(NotificationDecision.cableLabelChange(previous: ["a": "X"], current: ["b": "Y"]))
        XCTAssertNil(NotificationDecision.cableLabelChange(previous: [:], current: ["a": "X", "b": "Y"]))
    }

    /// Rename-while-connected: the key set is unchanged, only the VALUE for
    /// an existing key changed. Must read as inert (nil), not as a change.
    ///
    /// Red-proof: compare dictionaries directly (`previous != current`)
    /// instead of key sets, and this goes red.
    func testRenameWhileConnectedIsInert() {
        XCTAssertNil(NotificationDecision.cableLabelChange(previous: ["a": "Old Name"], current: ["a": "New Name"]))
    }

    /// Port-move inert: cable-ID keying means the SAME id staying present
    /// (even if the underlying port key it's attached to would have
    /// changed) never appears in `previous`/`current` as a key change,
    /// because this function never sees port keys at all -- only the
    /// dictionaries the caller already built by cable ID. Modelled here by
    /// the id simply staying present across two calls.
    func testPortMoveIsInertBecauseIDStaysPresent() {
        XCTAssertNil(NotificationDecision.cableLabelChange(previous: ["a": "Apple TB 1m"], current: ["a": "Apple TB 1m"]))
    }

    // MARK: - isPortLevelChange / batchNeedsCablePlausibilityHold

    /// A device with no parent at all (a top-level device, one non-zero
    /// locationID nibble) appearing at a Mac port has no ancestor to walk,
    /// so the loop never finds a "surviving ancestor": port-level by
    /// construction.
    ///
    /// Red-proof: hardcode the function to `return false` and this goes
    /// red.
    func testTopLevelGroupIsPortLevel() {
        let group = onlyChangeGroup(previous: [], current: [snap(id: 1, loc: 0x0210_0000, name: "Dock")])
        XCTAssertTrue(NotificationDecision.isPortLevelChange(
            group: group,
            previousLocationIDs: [],
            currentLocationIDs: [0x0210_0000]
        ))
    }

    /// A device appearing behind an UNCHANGED (surviving) hub is an in-tree
    /// change: the hub's locationID is present in both snapshots, so the
    /// walk finds a surviving ancestor and this reads as NOT port-level.
    ///
    /// Red-proof: flip `return false` to `return true` in the "found a
    /// surviving ancestor" branch and this goes red.
    func testDeviceBehindSurvivingHubIsInTree() {
        let hub = snap(id: 1, loc: 0x0110_0000, name: "Hub")
        let child = snap(id: 2, loc: 0x0111_0000, name: "Mouse")
        let group = onlyChangeGroup(previous: [hub], current: [hub, child])
        XCTAssertFalse(NotificationDecision.isPortLevelChange(
            group: group,
            previousLocationIDs: [0x0110_0000],
            currentLocationIDs: [0x0110_0000, 0x0111_0000]
        ))
    }

    /// A whole hub subtree (hub + child) arriving together at a Mac port:
    /// the hub itself is the group root (no changed OR surviving ancestor
    /// above it), so this is port-level.
    func testWholeSubtreeArrivingAtPortIsPortLevel() {
        let hub = snap(id: 1, loc: 0x0110_0000, name: "Hub")
        let child = snap(id: 2, loc: 0x0111_0000, name: "Mouse")
        let group = onlyChangeGroup(previous: [], current: [hub, child])
        XCTAssertTrue(NotificationDecision.isPortLevelChange(
            group: group,
            previousLocationIDs: [],
            currentLocationIDs: [0x0110_0000, 0x0111_0000]
        ))
    }

    /// Batch-level trigger: a batch containing ONE port-level group among
    /// others is enough to need the hold (mixed batch case).
    ///
    /// Red-proof: change `.contains` to require ALL groups be port-level
    /// and this goes red.
    func testBatchNeedsHoldWhenAnyGroupIsPortLevel() {
        let hub = snap(id: 1, loc: 0x0110_0000, name: "Hub")
        let child = snap(id: 2, loc: 0x0111_0000, name: "Mouse")
        let inTreeGroup = onlyChangeGroup(previous: [hub], current: [hub, child])
        let portLevelGroup = onlyChangeGroup(previous: [], current: [snap(id: 3, loc: 0x0210_0000, name: "Dock")])

        XCTAssertTrue(NotificationDecision.batchNeedsCablePlausibilityHold(
            removedGroups: [],
            addedGroups: [inTreeGroup, portLevelGroup],
            previousLocationIDs: [0x0110_0000],
            currentLocationIDs: [0x0110_0000, 0x0111_0000, 0x0210_0000]
        ))
    }

    /// A batch with ONLY in-tree groups never needs the hold.
    func testBatchWithOnlyInTreeGroupsNeedsNoHold() {
        let hub = snap(id: 1, loc: 0x0110_0000, name: "Hub")
        let child = snap(id: 2, loc: 0x0111_0000, name: "Mouse")
        let inTreeGroup = onlyChangeGroup(previous: [hub], current: [hub, child])
        XCTAssertFalse(NotificationDecision.batchNeedsCablePlausibilityHold(
            removedGroups: [],
            addedGroups: [inTreeGroup],
            previousLocationIDs: [0x0110_0000],
            currentLocationIDs: [0x0110_0000, 0x0111_0000]
        ))
    }

    // MARK: - Composition: byte-identical when no label

    /// `deviceNotificationContents` with no cable label produces the exact
    /// same title as before this feature, and an empty subtitle.
    ///
    /// Red-proof: hardcode `cableLabelSubtitle` to return a non-empty
    /// placeholder and this goes red.
    func testDeviceContentsUnchangedWithNoCableLabel() {
        let added = onlyChangeGroup(previous: [], current: [snap(id: 1, loc: 0x0210_0000, name: "Test Hub")])
        let contents = NotificationDecision.deviceNotificationContents(
            removedGroups: [], addedGroups: [added], singleDeviceBody: { _ in nil }
        )
        XCTAssertEqual(contents.first?.title, "Connected: Test Hub")
        XCTAssertEqual(contents.first?.subtitle, "")
    }

    /// With a cable label, the title stays plain (single line, no
    /// truncation risk) and the name lands verbatim in the subtitle.
    ///
    /// Red-proof: swap the label argument so subtitle is asserted against
    /// the wrong string and this goes red.
    func testDeviceContentsCarriesCableLabelInSubtitleWhenProvided() {
        let added = onlyChangeGroup(previous: [], current: [snap(id: 1, loc: 0x0210_0000, name: "Test Hub")])
        let contents = NotificationDecision.deviceNotificationContents(
            removedGroups: [], addedGroups: [added], addedCableLabel: "Apple TB 1m", singleDeviceBody: { _ in nil }
        )
        XCTAssertEqual(contents.first?.title, "Connected: Test Hub")
        XCTAssertEqual(contents.first?.subtitle, "Apple TB 1m")
    }

    // MARK: - Fixture helpers

    private func snap(id: UInt64, loc: UInt32, name: String) -> USBDeviceChangeGrouper.Snapshot {
        USBDeviceChangeGrouper.Snapshot(id: id, locationID: loc, name: name)
    }

    /// Runs `USBDeviceChangeGrouper.diff` and returns the single resulting
    /// added group (there must be exactly one), since `ChangeGroup` has no
    /// public initializer for a test in a different module to construct
    /// directly.
    private func onlyChangeGroup(
        previous: [USBDeviceChangeGrouper.Snapshot],
        current: [USBDeviceChangeGrouper.Snapshot]
    ) -> USBDeviceChangeGrouper.ChangeGroup {
        let (added, _) = USBDeviceChangeGrouper.diff(previous: previous, current: current)
        precondition(added.count == 1, "fixture must produce exactly one added group")
        return added[0]
    }
}
