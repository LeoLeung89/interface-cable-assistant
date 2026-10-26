import XCTest
@testable import WhatCableNotifications
import WhatCableCore

/// Issue #570 part B: the notification hold that waits (up to 5.0s) for a
/// saved cable's e-marker identity to resolve before labelling a device
/// notification title. Direct tests of `DeviceDiffSequencer`'s hold-stage
/// machinery, driven by `ManualClock`, mirroring `DeviceDiffSequencerTests`'
/// own style and helpers (duplicated here rather than shared, since that
/// file's helpers are `private`).
///
/// Post-review fix: every test that needs the hold to actually engage now
/// primes `hasSavedCables: true` directly, via `feed(...)`, rather than
/// priming an unrelated attached cable to sidestep an `attachedLabelled`
/// emptiness check. That older pattern is exactly what masked the bug this
/// file's `testFlagshipSoleSavedCableCurrentlyUnpluggedHoldsAndLabels`
/// exists to pin: a user's ONE saved cable, currently unplugged, has an
/// empty attached map at connect time by construction (the e-marker hasn't
/// resolved yet), so any test that always primed a non-empty attached map
/// could never have caught a regression back to reading emptiness as "no
/// saved cables exist".
@MainActor
final class DeviceDiffSequencerCableLabelHoldTests: XCTestCase {
    /// Top-level device (no hub parent): `locationID`'s hub-path has
    /// exactly one non-zero nibble, so `isPortLevelChange` finds no
    /// ancestor to walk at all and this always reads as port-level. `bus`
    /// varies the top byte so two of these never collide on the same
    /// locationID within one test.
    private func portLevelDevice(id: UInt64, bus: UInt8 = 0x02, name: String = "Test Hub") -> USBDevice {
        USBDevice(
            id: id, locationID: (UInt32(bus) << 24) | 0x0010_0000, vendorID: 0, productID: 0,
            vendorName: nil, productName: name, serialNumber: nil,
            usbVersion: nil, speedRaw: 3, busPowerMA: nil, currentMA: nil,
            rawProperties: [:]
        )
    }

    /// A stable hub (present in both previous and current) plus a child
    /// device attached under it: the child's own `ChangeGroup` root has a
    /// SURVIVING ancestor (the hub), so this is always an in-tree change.
    private func hubDevice(id: UInt64, bus: UInt8 = 0x03) -> USBDevice {
        USBDevice(
            id: id, locationID: (UInt32(bus) << 24) | 0x0010_0000, vendorID: 0, productID: 0,
            vendorName: nil, productName: "Hub", serialNumber: nil,
            usbVersion: nil, speedRaw: 3, busPowerMA: nil, currentMA: nil,
            rawProperties: [:]
        )
    }
    private func childDevice(id: UInt64, bus: UInt8 = 0x03, name: String = "Mouse") -> USBDevice {
        USBDevice(
            id: id, locationID: (UInt32(bus) << 24) | 0x0011_0000, vendorID: 0, productID: 0,
            vendorName: nil, productName: name, serialNumber: nil,
            usbVersion: nil, speedRaw: 3, busPowerMA: nil, currentMA: nil,
            rawProperties: [:]
        )
    }

    private final class PostedLog {
        var entries: [(NotificationCategory, NotificationContent)] = []
    }

    private func makeSequencer(
        clock: ManualClock,
        posted: PostedLog,
        notifyOnChanges: @escaping () -> Bool = { true }
    ) -> DeviceDiffSequencer<ManualClock> {
        DeviceDiffSequencer(
            clock: clock,
            currentDevices: { [] },
            currentChargerSources: { [] },
            notifyOnChanges: notifyOnChanges,
            post: { category, content, _ in posted.entries.append((category, content)) },
            launchToken: "test-launch"
        )
    }

    private func flush(_ clock: ManualClock) async {
        await clock.settle()
    }

    /// Builds a `CableLabelFeed`, the shape `updateLabelledCables(_:)` now
    /// takes. `hasSavedCables` and `attachedLabelled` are independent
    /// parameters on purpose: this is the exact seam the post-review fix
    /// added, so a test can assert "saved cables exist" without needing
    /// anything currently attached.
    private func feed(hasSavedCables: Bool, _ attachedLabelled: [String: String] = [:]) -> NotificationDecision.CableLabelFeed {
        NotificationDecision.CableLabelFeed(hasSavedCables: hasSavedCables, attachedLabelled: attachedLabelled)
    }

    // MARK: - Flagship scenario (post-review fix)

    /// THE scenario the coordinator flagged: a user has exactly ONE saved
    /// cable, and it is currently UNPLUGGED. At plug time the attached map
    /// is `[:]` (and stays `[:]` until the e-marker resolves), so the hold
    /// must engage on `hasSavedCables` alone, never on the attached map
    /// being non-empty.
    ///
    /// Red-proof: revert the gate at `DeviceDiffSequencer.swift`'s
    /// `resolveDevicePost` back to
    /// `!(knownLabelledCables == nil || knownLabelledCables?.isEmpty == true)`
    /// (the pre-fix, attached-map-emptiness check) and this test goes red:
    /// the connect posts unlabelled immediately instead of holding, because
    /// `knownLabelledCables` reads `[:]` at settle time on this exact
    /// scenario.
    func testFlagshipSoleSavedCableCurrentlyUnpluggedHoldsAndLabels() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [:]

        // The ONE saved cable is unplugged: hasSavedCables true, nothing
        // attached. This is the exact state the old gate misread as "no
        // saved cables exist anywhere".
        sequencer.updateLabelledCables(feed(hasSavedCables: true, [:]))

        sequencer.runNowOrDelayForRecentChargerPost([portLevelDevice(id: 1, name: "Cable Device")])
        await flush(clock)
        XCTAssertTrue(posted.entries.isEmpty, "must hold: hasSavedCables is true even though nothing is attached yet")

        await clock.advance(by: .seconds(2))
        await flush(clock)
        XCTAssertTrue(posted.entries.isEmpty, "still held 2s in, before the label arrives")

        // The e-marker resolves: the sole saved cable's key appears.
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["the-one-cable": "Apple TB 1m"]))
        await flush(clock)

        XCTAssertEqual(posted.entries.count, 1)
        XCTAssertEqual(posted.entries.first?.1.title, "Connected: Cable Device")
        XCTAssertEqual(posted.entries.first?.1.subtitle, "Apple TB 1m")
    }

    // MARK: - Hold-then-label

    /// Label arrives 4.9s into the hold -> labelled post then, immediately
    /// (no further wait). At 5.0s with no label -> unlabelled post. Two
    /// scenarios in one test, matching the spec's own pairing.
    ///
    /// Red-proof: change `cablePlausibilityHoldWindow` handling to always
    /// post unlabelled and the first assertion goes red; change the
    /// deadline task to never fire and the second assertion goes red.
    func testHoldThenLabelAt49SecondsAndUnlabelledAtCap() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [:]
        sequencer.updateLabelledCables(feed(hasSavedCables: true))

        sequencer.runNowOrDelayForRecentChargerPost([portLevelDevice(id: 1, name: "Cable Device")])
        await flush(clock)
        XCTAssertTrue(posted.entries.isEmpty, "port-level connect with no label yet must hold, not post immediately")

        await clock.advance(by: .milliseconds(4900))
        await flush(clock)
        XCTAssertTrue(posted.entries.isEmpty, "must still be held just before the label arrives")

        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["new-cable": "Apple TB 1m"]))
        await flush(clock)

        XCTAssertEqual(posted.entries.count, 1)
        XCTAssertEqual(posted.entries.first?.1.title, "Connected: Cable Device")
        XCTAssertEqual(posted.entries.first?.1.subtitle, "Apple TB 1m")

        await clock.advance(by: .seconds(10))
    }

    func testUnlabelledPostAtFiveSecondCap() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [:]
        sequencer.updateLabelledCables(feed(hasSavedCables: true))

        sequencer.runNowOrDelayForRecentChargerPost([portLevelDevice(id: 1, name: "Cable Device")])
        await flush(clock)
        XCTAssertTrue(posted.entries.isEmpty)

        await clock.advance(by: .milliseconds(4999))
        await flush(clock)
        XCTAssertTrue(posted.entries.isEmpty, "must not fire one millisecond before the cap")

        await clock.advance(by: .milliseconds(1))
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 1)
        XCTAssertEqual(posted.entries.first?.1.title, "Connected: Cable Device", "no label ever arrived, so the cap posts plain content")
    }

    // MARK: - Cable-plausibility gate

    /// An in-tree change (surviving ancestor) posts immediately even with a
    /// saved cable attached and baseline non-empty: the v2 blocker A
    /// scenario. Byte-identical to today, no label ever attempted.
    func testInTreeChangePostsImmediatelyEvenWithSavedCableAttached() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [hubDevice(id: 10).id: snapshot(for: hubDevice(id: 10))]
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["existing-cable": "Existing Cable"]))

        sequencer.runNowOrDelayForRecentChargerPost([hubDevice(id: 10), childDevice(id: 11)])
        await flush(clock)

        XCTAssertEqual(posted.entries.count, 1, "in-tree change must post immediately, never held")
        XCTAssertEqual(posted.entries.first?.1.title, "Connected: Mouse")
    }

    /// A port-level tree change holds.
    func testPortLevelChangeHolds() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [:]
        sequencer.updateLabelledCables(feed(hasSavedCables: true))

        sequencer.runNowOrDelayForRecentChargerPost([portLevelDevice(id: 1)])
        await flush(clock)
        XCTAssertTrue(posted.entries.isEmpty, "port-level change must hold")

        await clock.advance(by: .seconds(10))
    }

    /// A mixed batch (one in-tree group, one port-level group in the SAME
    /// settle window) holds: the batch-level trigger fires the moment ANY
    /// group in it is port-level.
    func testMixedBatchHolds() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [hubDevice(id: 10).id: snapshot(for: hubDevice(id: 10))]
        sequencer.updateLabelledCables(feed(hasSavedCables: true))

        // hubDevice(10) already known (surviving); childDevice(11) arrives
        // under it (in-tree); portLevelDevice(1) arrives with no parent at
        // all (port-level). Both added in the same settle.
        sequencer.runNowOrDelayForRecentChargerPost([hubDevice(id: 10), childDevice(id: 11), portLevelDevice(id: 1)])
        await flush(clock)

        XCTAssertTrue(posted.entries.isEmpty, "a mixed batch containing any port-level group must hold as a whole")

        await clock.advance(by: .seconds(10))
    }

    // MARK: - Flush-never-drop

    /// A second diff settling during a hold flushes the held batch FIRST
    /// (unlabelled, since no label arrived), then the new diff's own
    /// content follows. Total posts = both, zero lost.
    func testFlushNeverDrop() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.deferredDeviceDiffPresentationGapWindow = .milliseconds(30)
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [:]
        sequencer.updateLabelledCables(feed(hasSavedCables: true))

        sequencer.runNowOrDelayForRecentChargerPost([portLevelDevice(id: 1, bus: 0x02, name: "First Device")])
        await flush(clock)
        XCTAssertTrue(posted.entries.isEmpty, "first connect must hold")

        // A second, unrelated device settles while the first is still held.
        sequencer.knownDevices = [portLevelDevice(id: 1, bus: 0x02, name: "First Device").id:
            snapshot(for: portLevelDevice(id: 1, bus: 0x02, name: "First Device"))]
        sequencer.runNowOrDelayForRecentChargerPost([
            portLevelDevice(id: 1, bus: 0x02, name: "First Device"),
            hubDevice(id: 20, bus: 0x04)
        ])
        await flush(clock)

        XCTAssertEqual(posted.entries.count, 1, "held first batch must flush unlabelled the moment the second diff settles")
        XCTAssertEqual(posted.entries[0].1.title, "Connected: First Device")

        // The second diff is itself a port-level change (a fresh top-level
        // hub with no surviving ancestor), so it holds too rather than
        // posting a second immediate content -- proving nothing was lost
        // (the first batch's content did post) without needing a second
        // gap-delayed post in this test.
        await clock.advance(by: .seconds(10))
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 2, "the second diff's own content must also eventually post, never dropped")
    }

    // MARK: - Device-vs-device presentation gap

    /// After a flush, an immediately-following NON-held post waits the
    /// presentation gap before actually posting.
    func testFlushFollowedByImmediatePostWaitsPresentationGap() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.deferredDeviceDiffPresentationGapWindow = .milliseconds(30)
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [:]
        sequencer.updateLabelledCables(feed(hasSavedCables: true))

        sequencer.runNowOrDelayForRecentChargerPost([portLevelDevice(id: 1, bus: 0x02, name: "First Device")])
        await flush(clock)
        XCTAssertTrue(posted.entries.isEmpty)

        // The second diff is an IN-TREE change (a device inside an already
        // surviving hub), so its own decision is "post immediately" -- the
        // exact shape that must wait the presentation gap after the flush.
        sequencer.knownDevices = [
            portLevelDevice(id: 1, bus: 0x02, name: "First Device").id: snapshot(for: portLevelDevice(id: 1, bus: 0x02, name: "First Device")),
            hubDevice(id: 30, bus: 0x05).id: snapshot(for: hubDevice(id: 30, bus: 0x05))
        ]
        sequencer.runNowOrDelayForRecentChargerPost([
            portLevelDevice(id: 1, bus: 0x02, name: "First Device"),
            hubDevice(id: 30, bus: 0x05),
            childDevice(id: 31, bus: 0x05)
        ])
        await flush(clock)

        XCTAssertEqual(posted.entries.count, 1, "the flush lands immediately")
        XCTAssertEqual(posted.entries[0].1.title, "Connected: First Device")

        await clock.advance(by: .milliseconds(29))
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 1, "must not land one millisecond before the presentation gap elapses")

        await clock.advance(by: .milliseconds(1))
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 2, "after the gap, the second (in-tree) post lands too")
        XCTAssertEqual(posted.entries[1].1.title, "Connected: Mouse")
    }

    // MARK: - Reconnect exemption

    /// An `isReconnectPair` diff posts immediately with saved cables
    /// attached: never held, and per the "label structurally cannot
    /// resolve" reasoning, never labelled either.
    func testReconnectPairPostsImmediatelyNeverHeld() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.didPrimeBaseline = true
        let original = portLevelDevice(id: 1, name: "Flapping Device")
        sequencer.knownDevices = [original.id: snapshot(for: original)]
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["existing-cable": "Existing Cable"]))

        // Same locationID, same name, different id: a reconnect pair.
        let reconnected = USBDevice(
            id: 2, locationID: original.locationID, vendorID: 0, productID: 0,
            vendorName: nil, productName: "Flapping Device", serialNumber: nil,
            usbVersion: nil, speedRaw: 3, busPowerMA: nil, currentMA: nil,
            rawProperties: [:]
        )
        sequencer.runNowOrDelayForRecentChargerPost([reconnected])
        await flush(clock)

        XCTAssertEqual(posted.entries.count, 1, "reconnect must post immediately, never held")
        XCTAssertEqual(posted.entries.first?.1.title, "Reconnected: Flapping Device")
    }

    // MARK: - No hold when provider nil / no saved cables anywhere / charger category

    func testNoHoldWhenProviderNeverCalled() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [:]
        // `updateLabelledCables` never called: knownLabelledCables stays nil.

        sequencer.runNowOrDelayForRecentChargerPost([portLevelDevice(id: 1, name: "Cable Device")])
        await flush(clock)

        XCTAssertEqual(posted.entries.count, 1, "unavailable feature must post immediately, no hold")
        XCTAssertEqual(posted.entries.first?.1.title, "Connected: Cable Device")
        XCTAssertEqual(posted.entries.first?.1.subtitle, "", "free build: no label source at all, so the subtitle must never carry one")
        XCTAssertNil(sequencer.knownLabelledCables)
    }

    /// `hasSavedCables: false` (no saved cables anywhere, the provider's
    /// own fact) must skip the hold, exactly like a nil feed. This is the
    /// scenario that used to be tested by passing `[:]` for the attached
    /// map alone (wrong: see the flagship test above); it is now expressed
    /// with the correct signal.
    func testNoHoldWhenNoSavedCablesAnywhere() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [:]
        sequencer.updateLabelledCables(feed(hasSavedCables: false))

        sequencer.runNowOrDelayForRecentChargerPost([portLevelDevice(id: 1, name: "Cable Device")])
        await flush(clock)

        XCTAssertEqual(posted.entries.count, 1, "no saved cables anywhere must post immediately, no hold")
        XCTAssertEqual(posted.entries.first?.1.title, "Connected: Cable Device")
    }

    /// Charger posts are never held: `reconcileChargers`'s own posting path
    /// is untouched by this stage.
    func testChargerPostsAreNeverHeld() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.didPrimeBaseline = true
        sequencer.knownChargerLabels = [:]
        sequencer.updateLabelledCables(feed(hasSavedCables: true))

        sequencer.reconcileChargers()
        await flush(clock)

        // The always-empty live charger set means nothing was added, so no
        // content posts either way; the point is nothing here should ever
        // touch the hold machinery. Assert the hold stays untouched.
        XCTAssertTrue(posted.entries.isEmpty)
    }

    // MARK: - Direction match

    /// A connect diff labels only from an appeared key: a vanished key
    /// during the hold must not label a connect batch.
    func testConnectDiffIgnoresVanishedKeyDuringHold() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [:]
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["existing-cable": "Existing Cable", "other": "Other Cable"]))

        sequencer.runNowOrDelayForRecentChargerPost([portLevelDevice(id: 1, name: "Cable Device")])
        await flush(clock)
        XCTAssertTrue(posted.entries.isEmpty)

        // "other" vanishing is a REMOVED-direction event; this batch is a
        // connect (added-eligible), so it must not consume it.
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["existing-cable": "Existing Cable"]))
        await flush(clock)
        XCTAssertTrue(posted.entries.isEmpty, "a vanished-key event must not label a connect batch")

        await clock.advance(by: .seconds(5))
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 1)
        XCTAssertEqual(posted.entries.first?.1.title, "Connected: Cable Device", "cap posts unlabelled; the mismatched event was correctly ignored")
    }

    /// A disconnect diff only labels from a vanished key: an appeared key
    /// during the hold must not label a disconnect batch.
    func testDisconnectDiffIgnoresAppearedKeyDuringHold() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.didPrimeBaseline = true
        let device = portLevelDevice(id: 1, name: "Cable Device")
        sequencer.knownDevices = [device.id: snapshot(for: device)]
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["existing-cable": "Existing Cable"]))

        sequencer.runNowOrDelayForRecentChargerPost([])
        await flush(clock)
        XCTAssertTrue(posted.entries.isEmpty)

        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["existing-cable": "Existing Cable", "new-appeared": "New Cable"]))
        await flush(clock)
        XCTAssertTrue(posted.entries.isEmpty, "an appeared-key event must not label a disconnect batch")

        await clock.advance(by: .seconds(5))
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 1)
        XCTAssertEqual(posted.entries.first?.1.title, "Disconnected: Cable Device")
    }

    // MARK: - Baseline poison regression

    /// An unlabelled/missed connect (cap expires before the cable's data
    /// arrives) must not poison the following disconnect: once the label
    /// data DOES arrive (even after the connect already posted unlabelled),
    /// `knownLabelledCables` reflects it, and the later disconnect still
    /// labels correctly when the cable's key vanishes for real.
    func testBaselinePoisonRegression() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [:]
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["existing-cable": "Existing Cable"]))

        let connecting = portLevelDevice(id: 1, name: "Late Cable Device")
        sequencer.runNowOrDelayForRecentChargerPost([connecting])
        await flush(clock)
        XCTAssertTrue(posted.entries.isEmpty, "held, waiting for the label")

        // Cap expires with no label: posts unlabelled.
        await clock.advance(by: .seconds(5))
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 1)
        XCTAssertEqual(posted.entries[0].1.title, "Connected: Late Cable Device")

        // The cable's e-marker data arrives LATE, after the connect already
        // posted unlabelled. This is a genuine transition (key appears).
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["existing-cable": "Existing Cable", "late-cable": "Apple TB 2m"]))
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 1, "the late arrival alone posts nothing new; nothing is held to consume it")

        // Now the device disconnects for real; the cable's key vanishes
        // from the live snapshot in the SAME push that reports the
        // disconnect's settle. The disconnect must hold and then label
        // correctly from the true baseline, not a stale one poisoned by
        // the connect's own (unlabelled) settle.
        sequencer.knownDevices = [connecting.id: snapshot(for: connecting)]
        sequencer.runNowOrDelayForRecentChargerPost([])
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 1, "disconnect must hold, waiting for the vanish event")

        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["existing-cable": "Existing Cable"]))
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 1, "the flush enqueues, but the device-post spacing floor still holds it: the connect posted moments ago (5s mark, no further clock advance since)")

        // Spacing-floor gate-fixes fix 1: this second post is a DIFFERENT
        // settled batch from the connect's, so it queues behind the
        // spacing window rather than posting immediately.
        await clock.advance(by: sequencer.deferredDeviceDiffPresentationGapWindow)
        await flush(clock)

        XCTAssertEqual(posted.entries.count, 2)
        XCTAssertEqual(posted.entries[1].1.title, "Disconnected: Late Cable Device", "the disconnect must still label correctly from the live baseline, unpoisoned by the earlier unlabelled connect")
        XCTAssertEqual(posted.entries[1].1.subtitle, "Apple TB 2m")
    }

    // MARK: - Licence mid-hold

    /// Lock mid-hold -> unlabelled at cap, no stale name.
    func testLockMidHoldPostsUnlabelledAtCap() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [:]
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["existing-cable": "Existing Cable"]))

        sequencer.runNowOrDelayForRecentChargerPost([portLevelDevice(id: 1, name: "Cable Device")])
        await flush(clock)
        XCTAssertTrue(posted.entries.isEmpty)

        // The licence locks mid-hold (a push to nil produces no event: one
        // side of the comparison is nil, so `cableLabelChange` never runs).
        sequencer.updateLabelledCables(nil)
        await flush(clock)
        XCTAssertTrue(posted.entries.isEmpty, "still held; the lock alone doesn't flush anything")

        await clock.advance(by: .seconds(5))
        await flush(clock)

        XCTAssertEqual(posted.entries.count, 1)
        XCTAssertEqual(posted.entries[0].1.title, "Connected: Cable Device", "locked at flush time: no stale name may survive to the post")
        XCTAssertEqual(posted.entries[0].1.subtitle, "", "locked mid-hold: no stale name may leak into the subtitle either")
    }

    /// Unlock mid-hold: a fresh non-nil snapshot flowing through
    /// `updateLabelledCables` after a lock can still label the held post.
    func testUnlockMidHoldCanStillLabel() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [:]
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["existing-cable": "Existing Cable"]))

        sequencer.runNowOrDelayForRecentChargerPost([portLevelDevice(id: 1, name: "Cable Device")])
        await flush(clock)
        XCTAssertTrue(posted.entries.isEmpty)

        // Locks mid-hold.
        sequencer.updateLabelledCables(nil)
        await flush(clock)
        XCTAssertTrue(posted.entries.isEmpty)

        // Unlocks again, and the cable's own data resolves in this same
        // fresh (post-unlock) snapshot.
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["existing-cable": "Existing Cable"]))
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["existing-cable": "Existing Cable", "new-cable": "Apple TB 1m"]))
        await flush(clock)

        XCTAssertEqual(posted.entries.count, 1)
        XCTAssertEqual(posted.entries[0].1.title, "Connected: Cable Device", "unlocking mid-hold must still allow a label to land")
        XCTAssertEqual(posted.entries[0].1.subtitle, "Apple TB 1m")
    }

    // MARK: - Device-post spacing floor (gate-fixes fix 1)

    /// Two diffs settling close together (well within the spacing window)
    /// post exactly one window apart, FIFO: the second never jumps ahead of
    /// the wait the floor imposes, and doesn't fire early just because it
    /// settled soon after the first.
    ///
    /// Red-proof: make `drainDeviceQueueIfPossible` fire immediately
    /// regardless of `delay` (drop the floor) and this goes red -- the
    /// second post would land at the 50ms mark instead of the 200ms mark.
    func testTwoDiffsSpacedApartFireExactlySpacingApartFIFO() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.deferredDeviceDiffPresentationGapWindow = .milliseconds(200)
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [:]
        // No saved cables anywhere: the gate never holds, so both diffs
        // enqueue immediately and this test isolates the spacing floor from
        // the cable-plausibility hold entirely.
        sequencer.updateLabelledCables(feed(hasSavedCables: false))

        sequencer.runNowOrDelayForRecentChargerPost([portLevelDevice(id: 1, bus: 0x02, name: "First Device")])
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 1, "the first-ever device post fires synchronously, no prior post to space against")
        XCTAssertEqual(posted.entries[0].1.title, "Connected: First Device")

        await clock.advance(by: .milliseconds(50))
        sequencer.knownDevices = [portLevelDevice(id: 1, bus: 0x02, name: "First Device").id:
            snapshot(for: portLevelDevice(id: 1, bus: 0x02, name: "First Device"))]
        sequencer.runNowOrDelayForRecentChargerPost([
            portLevelDevice(id: 1, bus: 0x02, name: "First Device"),
            portLevelDevice(id: 2, bus: 0x06, name: "Second Device"),
        ])
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 1, "must not fire until the full spacing window has elapsed since the first post")

        await clock.advance(by: .milliseconds(149))
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 1, "must not fire one millisecond early (150ms elapsed since the first post; the window is 200ms)")

        await clock.advance(by: .milliseconds(1))
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 2, "fires exactly at the 200ms spacing mark")
        XCTAssertEqual(posted.entries[1].1.title, "Connected: Second Device")
    }

    /// Three rapid diffs, settled back-to-back with no clock advance
    /// between them, fire in strict FIFO order, each spaced exactly one
    /// window after the previous ACTUAL post (not the previous settle).
    ///
    /// Red-proof: after firing the front of the queue, fire every remaining
    /// queued job immediately instead of re-checking the spacing floor for
    /// each (mutation: "post third immediately") and this goes red -- device
    /// C would post at the 100ms mark (alongside B) instead of the 200ms
    /// mark.
    func testThreeRapidDiffsFireInStrictFIFOOrder() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.deferredDeviceDiffPresentationGapWindow = .milliseconds(100)
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [:]
        sequencer.updateLabelledCables(feed(hasSavedCables: false))

        sequencer.runNowOrDelayForRecentChargerPost([portLevelDevice(id: 1, bus: 0x02, name: "Device A")])
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 1)

        sequencer.knownDevices = [portLevelDevice(id: 1, bus: 0x02, name: "Device A").id:
            snapshot(for: portLevelDevice(id: 1, bus: 0x02, name: "Device A"))]
        sequencer.runNowOrDelayForRecentChargerPost([
            portLevelDevice(id: 1, bus: 0x02, name: "Device A"),
            portLevelDevice(id: 2, bus: 0x06, name: "Device B"),
        ])
        await flush(clock)

        sequencer.knownDevices[portLevelDevice(id: 2, bus: 0x06, name: "Device B").id] =
            snapshot(for: portLevelDevice(id: 2, bus: 0x06, name: "Device B"))
        sequencer.runNowOrDelayForRecentChargerPost([
            portLevelDevice(id: 1, bus: 0x02, name: "Device A"),
            portLevelDevice(id: 2, bus: 0x06, name: "Device B"),
            portLevelDevice(id: 3, bus: 0x07, name: "Device C"),
        ])
        await flush(clock)

        XCTAssertEqual(posted.entries.count, 1, "only device A fires synchronously; B and C both queue behind it, FIFO")

        await clock.advance(by: .milliseconds(100))
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 2, "device B fires at the first spacing mark")
        XCTAssertEqual(posted.entries[1].1.title, "Connected: Device B")

        await clock.advance(by: .milliseconds(99))
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 2, "device C must not fire one millisecond before its OWN spacing mark")

        await clock.advance(by: .milliseconds(1))
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 3, "device C fires at the second spacing mark, 200ms after A")
        XCTAssertEqual(posted.entries[2].1.title, "Connected: Device C")
    }

    // MARK: - Fire-time composition (gate-fixes fix 1, closes Codex 3)

    /// A job enqueued with a usable label already peeked, then queued
    /// behind the spacing floor: if the feed goes nil (licence locks)
    /// BEFORE the job actually fires, the post that eventually goes out
    /// must be unlabelled, because the label decision is made at FIRE time,
    /// not when the job was enqueued.
    ///
    /// Red-proof: move the label composition from `fireDevicePostJob` into
    /// the "usable label already present" branch of `resolveDevicePost`
    /// (composing and consuming `pendingCableLabelEvent` at ENQUEUE time,
    /// baking the label into the job before the lock has a chance to land)
    /// and this goes red -- the post fires labelled despite the lock.
    func testFeedGoesNilDuringQueueWaitPostsUnlabelled() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.deferredDeviceDiffPresentationGapWindow = .milliseconds(200)
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [:]
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["existing-cable": "Existing Cable"]))

        // An unrelated first device post, purely to force the SECOND one
        // onto the spaced queue instead of firing synchronously. An
        // IN-TREE change (a child arriving under an already-known,
        // surviving hub) so it posts immediately regardless of
        // `hasSavedCables`, never touching the hold gate at all.
        sequencer.knownDevices = [hubDevice(id: 10).id: snapshot(for: hubDevice(id: 10))]
        sequencer.runNowOrDelayForRecentChargerPost([hubDevice(id: 10), childDevice(id: 11)])
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 1)

        // A saved cable's e-marker resolves right as a SECOND device
        // connects: the "usable label already present" peek in
        // resolveDevicePost finds a match and enqueues WITHOUT holding.
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["existing-cable": "Existing Cable", "new-cable": "Apple TB 1m"]))
        sequencer.knownDevices = [
            hubDevice(id: 10).id: snapshot(for: hubDevice(id: 10)),
            childDevice(id: 11).id: snapshot(for: childDevice(id: 11)),
        ]
        sequencer.runNowOrDelayForRecentChargerPost([
            hubDevice(id: 10), childDevice(id: 11),
            portLevelDevice(id: 2, bus: 0x06, name: "Second Device"),
        ])
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 1, "queued behind the spacing floor, not yet fired")

        // The licence locks BEFORE the queued job actually fires.
        sequencer.updateLabelledCables(nil)

        await clock.advance(by: .milliseconds(200))
        await flush(clock)

        XCTAssertEqual(posted.entries.count, 2)
        XCTAssertEqual(
            posted.entries[1].1.title, "Connected: Second Device",
            "no label: the lock landed before this job actually fired, and fire-time composition re-checks the licence guard fresh"
        )
        XCTAssertEqual(posted.entries[1].1.subtitle, "", "queued job locked before firing: subtitle must stay empty too")
    }

    // MARK: - Wrong-name regression (gate-fixes fix 3, closes Codex 4)

    /// Lock, unlock, then an UNRELATED same-direction change must never
    /// inherit a STALE, never-consumed pre-lock event's name. The event has
    /// to be genuinely UNCONSUMED at lock time to be a meaningful trap: a
    /// wrong-direction event (here, a REMOVE while the only thing holding
    /// is a CONNECT) sits in `pendingCableLabelEvent` unconsumed, because
    /// nothing eligible for its direction ever showed up before the lock.
    ///
    /// Red-proof: remove the `if feed == nil { pendingCableLabelEvent = nil }`
    /// clearing in `updateLabelledCables` and this goes red -- Device Two's
    /// disconnect, settling AFTER the unlock, wrongly matches the stale
    /// pre-lock REMOVE-direction event and posts "Disconnected: Device Two
    /// (Old Cable)" instead of holding and posting unlabelled at the cap.
    func testLockUnlockThenUnrelatedChangeNeverInheritsTheOldName() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [:]
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["old-cable": "Old Cable"]))

        // Device One CONNECTS (addedEligible only) and holds: nothing
        // eligible for a REMOVE has happened yet, so no event exists at all.
        sequencer.runNowOrDelayForRecentChargerPost([portLevelDevice(id: 1, name: "Device One")])
        await flush(clock)
        XCTAssertTrue(posted.entries.isEmpty, "held, waiting for a label")

        // "old-cable" now VANISHES: a genuine REMOVE-direction event. It
        // does NOT match Device One's hold (addedEligible only, this event
        // is wasAdded: false), so it sits UNCONSUMED in
        // `pendingCableLabelEvent` -- exactly the stale event this test
        // targets.
        sequencer.updateLabelledCables(feed(hasSavedCables: true, [:]))
        await flush(clock)
        XCTAssertTrue(posted.entries.isEmpty, "the vanish event doesn't match Device One's connect direction, so it's left stale, not consumed")

        // Locks. Without the fix, the stale REMOVE event survives this.
        sequencer.updateLabelledCables(nil)
        // Unlocks. No saved cables reported now (this call's own previous
        // was nil, so it produces no NEW event either).
        sequencer.updateLabelledCables(feed(hasSavedCables: true, [:]))

        // A genuinely UNRELATED device now DISCONNECTS (removedEligible):
        // the exact direction the stale event matches. This settle first
        // flushes Device One's own still-pending hold (unlabelled: nothing
        // ever matched its connect direction), then evaluates itself.
        sequencer.knownDevices = [portLevelDevice(id: 1, name: "Device One").id: snapshot(for: portLevelDevice(id: 1, name: "Device One"))]
        sequencer.runNowOrDelayForRecentChargerPost([])
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 1, "Device One's own hold flushes unlabelled first")
        XCTAssertEqual(posted.entries[0].1.title, "Connected: Device One")

        await clock.advance(by: .seconds(5))
        await flush(clock)

        XCTAssertEqual(posted.entries.count, 2)
        XCTAssertEqual(
            posted.entries[1].1.title, "Disconnected: Device One",
            "must post UNLABELLED at the cap, never inheriting the stale pre-lock REMOVE event meant for a different (long-vanished) cable"
        )
    }

    // MARK: - Capture-time binding (gate-fixes P2, follow-up finding)

    /// Codex's exact scenario. Device A's hold flushes with NO matching
    /// event and gets queued behind the spacing floor (capturedLabel: nil).
    /// While it waits, an UNRELATED cable ("Cable B") publishes a
    /// SAME-DIRECTION event. Device A's job must not pick that event up
    /// when it finally fires: capture-time binding fixed the label (none)
    /// the instant the job was created, before "Cable B" ever existed.
    ///
    /// Red-proof: revert `fireDevicePostJob` to read `pendingCableLabelEvent`
    /// live (fire-time global consumption, the pre-P2-fix design) instead
    /// of `job.capturedLabel`, and this goes red -- Device A's post carries
    /// "Cable B"'s name.
    func testQueuedJobWithNoCapturedEventDoesNotPickUpALaterUnrelatedEvent() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.deferredDeviceDiffPresentationGapWindow = .milliseconds(200)
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [:]
        sequencer.updateLabelledCables(feed(hasSavedCables: true))

        // An unrelated first post (in-tree, never holds), purely to
        // establish `lastDevicePostTime` so what follows queues behind the
        // spacing floor instead of firing immediately.
        sequencer.knownDevices = [hubDevice(id: 10).id: snapshot(for: hubDevice(id: 10))]
        sequencer.runNowOrDelayForRecentChargerPost([hubDevice(id: 10), childDevice(id: 11)])
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 1)

        // Device A connects (top-level, addedEligible) and holds: no event
        // exists at all yet.
        sequencer.knownDevices[hubDevice(id: 10).id] = snapshot(for: hubDevice(id: 10))
        sequencer.knownDevices[childDevice(id: 11).id] = snapshot(for: childDevice(id: 11))
        sequencer.runNowOrDelayForRecentChargerPost([
            hubDevice(id: 10), childDevice(id: 11),
            portLevelDevice(id: 1, bus: 0x02, name: "Device A"),
        ])
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 1, "Device A holds: no event yet")

        // A SECOND settle with NO actual change (the exact same device
        // list) still supersedes Device A's hold: `resolveDevicePost`
        // unconditionally flushes whatever is held FIRST, before it even
        // looks at this settle's own (empty) added/removed groups.
        // `flushHeldDeviceBatch` captures NO match (still no event exists)
        // and enqueues Device A's job with `capturedLabel: nil`; with a
        // prior post already recent, it queues behind the spacing floor
        // rather than firing immediately.
        sequencer.knownDevices[portLevelDevice(id: 1, bus: 0x02, name: "Device A").id] =
            snapshot(for: portLevelDevice(id: 1, bus: 0x02, name: "Device A"))
        sequencer.runNowOrDelayForRecentChargerPost([
            hubDevice(id: 10), childDevice(id: 11),
            portLevelDevice(id: 1, bus: 0x02, name: "Device A"),
        ])
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 1, "Device A's flush is queued behind the spacing floor, not yet fired")

        // WHILE Device A's job sits queued, an UNRELATED cable's e-marker
        // resolves: a genuine SAME-DIRECTION (added) event. Nothing is
        // currently held, so it just sits as `pendingCableLabelEvent`,
        // dangling, unconsumed.
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["cable-b": "Cable B"]))

        await clock.advance(by: .milliseconds(200))
        await flush(clock)

        XCTAssertEqual(posted.entries.count, 2)
        XCTAssertEqual(
            posted.entries[1].1.title, "Connected: Device A",
            "must post UNLABELLED: Device A's job captured no event before \"Cable B\" ever existed"
        )
        XCTAssertEqual(posted.entries[1].1.subtitle, "", "an unrelated cable's label sitting unconsumed must never leak into Device A's subtitle")
    }

    /// The positive twin: Device A's job DOES capture its own matching
    /// event at flush time, then queues behind the spacing floor. While it
    /// waits, an unrelated "Cable B" event arrives. Device A's job still
    /// posts with ITS OWN captured name (not B's, not unlabelled).
    ///
    /// fix1 (episode-scoped ownership): this replaces
    /// `testQueuedJobKeepsItsOwnCapturedEventAndTheUnrelatedOneSurvivesForTheNextDiff`.
    /// That test's ending -- "Cable B"'s event survives, untouched,
    /// indefinitely, for whatever diff eventually turns out to be eligible
    /// for it -- was itself the stale-binding bug this fix closes: a
    /// pre-fix1 `pendingCableLabelEvent` had no expiry at all, so it really
    /// would sit there forever no matter how much later or how unrelated
    /// the next eligible diff was. Under episode-scoped ownership, "Cable
    /// B"'s event arrives while NO device episode is open (Device A's own
    /// episode already closed the moment its batch flushed), so it lands in
    /// the bounded `graceCableLabelEvent` slot, not the owned one, and is
    /// claimable only by the very next episode to open within
    /// `deviceSettleWindow` of its own arrival. Device C's episode here
    /// opens well OUTSIDE that window, so the event has already expired by
    /// the time Device C settles, and Device C posts unlabelled instead of
    /// inheriting "Cable B"'s name.
    func testQueuedJobKeepsItsOwnCapturedEventAndTheUnrelatedOneExpiresInstead() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.deferredDeviceDiffPresentationGapWindow = .milliseconds(200)
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [:]
        sequencer.updateLabelledCables(feed(hasSavedCables: true))

        // Unrelated first post, to establish `lastDevicePostTime`.
        sequencer.knownDevices = [hubDevice(id: 10).id: snapshot(for: hubDevice(id: 10))]
        sequencer.runNowOrDelayForRecentChargerPost([hubDevice(id: 10), childDevice(id: 11)])
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 1)

        // Device A connects and holds.
        sequencer.knownDevices[hubDevice(id: 10).id] = snapshot(for: hubDevice(id: 10))
        sequencer.knownDevices[childDevice(id: 11).id] = snapshot(for: childDevice(id: 11))
        sequencer.runNowOrDelayForRecentChargerPost([
            hubDevice(id: 10), childDevice(id: 11),
            portLevelDevice(id: 1, bus: 0x02, name: "Device A"),
        ])
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 1)

        // "Cable A"'s e-marker resolves: matches Device A's hold, captured
        // and consumed immediately, enqueued (queues behind the spacing
        // floor, since a prior post is recent).
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["cable-a": "Cable A"]))
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 1, "Device A's job is queued, captured with \"Cable A\" already bound")

        // WHILE Device A's job waits, an UNRELATED cable's event arrives.
        // No device episode is open at this instant (Device A's own episode
        // already closed the moment its batch flushed above), so this lands
        // in the bounded pre-episode grace slot, timestamped now.
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["cable-a": "Cable A", "cable-b": "Cable B"]))

        await clock.advance(by: .milliseconds(200))
        await flush(clock)

        XCTAssertEqual(posted.entries.count, 2)
        XCTAssertEqual(
            posted.entries[1].1.title, "Connected: Device A",
            "Device A's own captured event must survive, uncorrupted by the later unrelated one"
        )
        XCTAssertEqual(posted.entries[1].1.subtitle, "Cable A")

        // Let "Cable B"'s grace event expire: well past `deviceSettleWindow`
        // (1500ms default) since it arrived, with no episode ever opening
        // to claim it in that time.
        await clock.advance(by: .milliseconds(1400))
        await flush(clock)

        // A NEW, genuinely eligible diff (Device C) now settles, well
        // outside "Cable B"'s claim window. Red-proof: drop the
        // `deviceSettleWindow` bound in `claimGraceCableLabelEventIfEligible`
        // (always claim regardless of elapsed time) and this test goes red
        // -- Device C would post "Connected: Device C (Cable B)" instead.
        sequencer.knownDevices[portLevelDevice(id: 1, bus: 0x02, name: "Device A").id] =
            snapshot(for: portLevelDevice(id: 1, bus: 0x02, name: "Device A"))
        sequencer.runNowOrDelayForRecentChargerPost([
            hubDevice(id: 10), childDevice(id: 11),
            portLevelDevice(id: 1, bus: 0x02, name: "Device A"),
            portLevelDevice(id: 2, bus: 0x06, name: "Device C"),
        ])
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 2, "no captured event: \"Cable B\" already expired, so Device C holds instead of enqueuing immediately")

        await clock.advance(by: .seconds(5))
        await flush(clock)

        XCTAssertEqual(posted.entries.count, 3)
        XCTAssertEqual(
            posted.entries.last?.1.title, "Connected: Device C",
            "\"Cable B\"'s event expired rather than surviving indefinitely: Device C posts unlabelled, never inheriting a stranger's name"
        )
    }

    // MARK: - Episode lifecycle (fix1: episode-scoped cable label events)

    /// Diff-less flap: a labelled-cables change with NO device episode open
    /// at all (a bare TB renegotiation flap, not tied to any settling or
    /// held device diff) lands in the bounded pre-episode grace slot, not an
    /// owned one. Once `deviceSettleWindow` has elapsed since it arrived
    /// with nothing claiming it, it has expired: a plug settling after that
    /// point must not be labelled by it.
    ///
    /// Red-proof: remove the `grace.arrivedAt.duration(to: clock.now) <=
    /// deviceSettleWindow` bound in `claimGraceCableLabelEventIfEligible`
    /// (always claim regardless of elapsed time) and this goes red -- the
    /// plug below would post "Connected: Late Plug (Flap Cable)" instead of
    /// unlabelled.
    func testDiffLessFlapGraceSlotExpiresAfterDeviceSettleWindow() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [:]
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["existing-cable": "Existing Cable"]))

        // No device episode is open anywhere near this call: a bare
        // labelled-cables flap, with no device diff involved at all.
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["existing-cable": "Existing Cable", "flap-cable": "Flap Cable"]))

        // Past `deviceSettleWindow` (1500ms default) since the flap, with
        // nothing having opened to claim it.
        await clock.advance(by: .milliseconds(1501))
        await flush(clock)

        sequencer.runNowOrDelayForRecentChargerPost([portLevelDevice(id: 1, name: "Late Plug")])
        await flush(clock)
        XCTAssertTrue(posted.entries.isEmpty, "holds: no captured event, since the flap's grace event already expired")

        await clock.advance(by: .seconds(5))
        await flush(clock)

        XCTAssertEqual(posted.entries.count, 1)
        XCTAssertEqual(posted.entries[0].1.title, "Connected: Late Plug", "must post unlabelled: the expired flap event must never attach to an unrelated later plug")
    }

    /// Ordering permutation A (the flagship grace case): a labelled-cables
    /// change arrives FIRST, with no device episode open yet, then the raw
    /// device publish that opens the matching episode arrives shortly
    /// after, still WITHIN `deviceSettleWindow` of the event's own arrival.
    /// The streams have no ordering guarantee (issue #570 part B's own
    /// framing), so this ordering is a real, accepted case, not just a
    /// timing coincidence to tolerate: the newly-opened episode must claim
    /// the grace event and label its post.
    ///
    /// Red-proof: make `openDeviceEpisodeIfNeeded()` skip
    /// `claimGraceCableLabelEventIfEligible(for:)` entirely (drop the claim)
    /// and this goes red -- the connect would post unlabelled at the 5s cap
    /// instead of labelled, immediately, on the settle that claimed it.
    func testOrderingPermutationAGraceSlotClaimsWithinWindow() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [:]
        sequencer.updateLabelledCables(feed(hasSavedCables: true))

        // The label arrives first, with nothing open to receive it yet.
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["early-cable": "Early Cable"]))

        // Well within `deviceSettleWindow` (1500ms default) of the event's
        // own arrival.
        await clock.advance(by: .milliseconds(500))
        await flush(clock)

        sequencer.runNowOrDelayForRecentChargerPost([portLevelDevice(id: 1, name: "Early Plug")])
        await flush(clock)

        XCTAssertEqual(posted.entries.count, 1, "the newly-opened episode must claim the grace event and post immediately, not hold")
        XCTAssertEqual(posted.entries[0].1.title, "Connected: Early Plug")
        XCTAssertEqual(posted.entries[0].1.subtitle, "Early Cable")
    }

    /// New episode during hold: an OLDER batch (Device A, still eligible)
    /// is held, awaiting a label, when a genuinely unrelated raw publish
    /// (Device B) opens a NEW episode via the charger-deferral park path (so
    /// it stays genuinely "settling", not yet resolved, while A is still
    /// held). A label for Device B's cable arrives while BOTH are alive:
    /// the currently-settling episode (B) must get it, never the older held
    /// one (A) -- "no steal in either direction". Landing B then flushes A
    /// first (flush-never-drop), unlabelled, before B's own match resolves.
    ///
    /// Red-proof: in `assignCableLabelEvent(_:)`, swap the priority so a
    /// settling episode is assigned to `heldDeviceBatchEpisodeID` whenever
    /// one is held, ahead of `settlingDeviceEpisodeID` (assign to the held
    /// episode instead of preferring settling) and this goes red -- Device
    /// A would post "Disconnected... " no, would post labelled
    /// "Connected: Device A (Cable For B)" and Device B would post
    /// unlabelled, exactly the steal this fix prevents.
    func testNewEpisodeDuringHoldPrefersSettlingAndDoesNotStealFromTheHeldBatch() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [:]
        sequencer.updateLabelledCables(feed(hasSavedCables: true))

        // Device A connects and holds: episode A, held, no event yet.
        sequencer.runNowOrDelayForRecentChargerPost([portLevelDevice(id: 1, bus: 0x02, name: "Device A")])
        await flush(clock)
        XCTAssertTrue(posted.entries.isEmpty, "Device A holds")

        // Device B settles via the charger-deferral park path, so it stays
        // genuinely SETTLING (not yet resolved) while A is still held --
        // the one construction where a settling and a held episode are
        // simultaneously alive.
        sequencer.knownDevices = [portLevelDevice(id: 1, bus: 0x02, name: "Device A").id:
            snapshot(for: portLevelDevice(id: 1, bus: 0x02, name: "Device A"))]
        sequencer.deferDeviceDiff([
            portLevelDevice(id: 1, bus: 0x02, name: "Device A"),
            portLevelDevice(id: 2, bus: 0x06, name: "Device B"),
        ])

        // A label for Device B's cable arrives while A is held AND B is
        // still settling (parked, not yet landed).
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["cable-for-b": "Cable For B"]))
        await flush(clock)
        XCTAssertTrue(posted.entries.isEmpty, "nothing has landed yet: A is still held, B is still parked")

        // Land B via the bounded deadline (no charger reconcile involved).
        await clock.advance(by: sequencer.deferredDeviceDiffDeadlineWindow)
        await flush(clock)

        // Landing B flushes A first (flush-never-drop), unlabelled: this is
        // the very first `.device` post this launch, so it fires
        // synchronously with no spacing wait.
        XCTAssertEqual(posted.entries.count, 1)
        XCTAssertEqual(posted.entries[0].1.title, "Connected: Device A", "A must flush unlabelled: the event belongs to B, not A")

        // B's own match then enqueues right behind it, but the device-post
        // spacing floor (gate-fixes fix 1) makes it wait out the
        // presentation gap since A's flush landed only moments ago.
        await clock.advance(by: sequencer.deferredDeviceDiffPresentationGapWindow)
        await flush(clock)

        XCTAssertEqual(posted.entries.count, 2)
        XCTAssertEqual(posted.entries[1].1.title, "Connected: Device B", "B must get its own event, not A")
        XCTAssertEqual(posted.entries[1].1.subtitle, "Cable For B")

        await clock.advance(by: .seconds(10))
    }

    /// Stale-binding regression (the Codex high, fix1): Device A is held
    /// with a MISMATCHED-direction event already pending against it (a
    /// vanished key, while A itself is an add-eligible connect -- so it
    /// never matched A when it arrived, and just sits there). While A is
    /// still held, an unrelated Device B settles via the charger-deferral
    /// park path and stays genuinely settling. A SAME-DIRECTION (add) event
    /// for B's own cable then arrives: `assignCableLabelEvent(_:)` assigns
    /// it to B (settling preferred), overwriting the single pending slot --
    /// A's original event is gone, replaced by B's. When B finally lands,
    /// A's held batch flushes first (flush-never-drop): the pending event
    /// at that moment is B's (add-direction), and A is ALSO add-eligible,
    /// so a direction-only check would wrongly match it. Only the owner
    /// check in `flushHeldDeviceBatch` (the event is tagged to B, not A)
    /// stops A from stealing B's label.
    ///
    /// Red-proof: drop the `event.episodeID == owningEpisodeID` comparison
    /// in `flushHeldDeviceBatch` (match on direction alone) and this goes
    /// red -- A would post "Connected: Device A (Cable Y)" instead of
    /// unlabelled, and B would post unlabelled instead of "(Cable Y)".
    func testStaleBindingRegressionOwnerCheckPreventsAHeldBatchStealingAnUnrelatedEpisodesEvent() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [:]
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["cable-x": "Cable X"]))

        // Device A connects (add-eligible) and holds: no event yet.
        sequencer.runNowOrDelayForRecentChargerPost([portLevelDevice(id: 1, bus: 0x02, name: "Device A")])
        await flush(clock)
        XCTAssertTrue(posted.entries.isEmpty, "Device A holds")

        // "cable-x" vanishes: a REMOVE-direction event. Device A is
        // add-eligible only, so this does not match and sits pending,
        // owned by A's held episode.
        sequencer.updateLabelledCables(feed(hasSavedCables: true, [:]))
        await flush(clock)
        XCTAssertTrue(posted.entries.isEmpty, "the vanish event doesn't match A's connect direction: stays pending, owned by A")

        // Device B settles via the charger-deferral park path, so it stays
        // genuinely SETTLING while A is still held.
        sequencer.knownDevices = [portLevelDevice(id: 1, bus: 0x02, name: "Device A").id:
            snapshot(for: portLevelDevice(id: 1, bus: 0x02, name: "Device A"))]
        sequencer.deferDeviceDiff([
            portLevelDevice(id: 1, bus: 0x02, name: "Device A"),
            portLevelDevice(id: 2, bus: 0x06, name: "Device B"),
        ])

        // "cable-y" appears: a SAME-DIRECTION (add) event, this time for a
        // genuinely different cable. B is the currently-settling episode,
        // so it is assigned to B, overwriting A's still-pending (and now
        // orphaned) remove-direction event.
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["cable-y": "Cable Y"]))
        await flush(clock)
        XCTAssertTrue(posted.entries.isEmpty, "nothing has landed yet")

        // Land B via the bounded deadline.
        await clock.advance(by: sequencer.deferredDeviceDiffDeadlineWindow)
        await flush(clock)

        // Landing B flushes A first. The pending event is B's, not A's own
        // (long overwritten): A must NOT steal it just because the
        // direction happens to match A's own eligibility too.
        XCTAssertEqual(posted.entries.count, 1)
        XCTAssertEqual(posted.entries[0].1.title, "Connected: Device A", "A must flush unlabelled: the pending event belongs to B, not A")

        await clock.advance(by: sequencer.deferredDeviceDiffPresentationGapWindow)
        await flush(clock)

        XCTAssertEqual(posted.entries.count, 2)
        XCTAssertEqual(posted.entries[1].1.title, "Connected: Device B", "B must get its own event")
        XCTAssertEqual(posted.entries[1].1.subtitle, "Cable Y")

        await clock.advance(by: .seconds(10))
    }

    // MARK: - Terminal-path episode close (fix1)
    //
    // Each of these closes the currently settling episode through a
    // DIFFERENT terminal path (empty diff, notifications off, reconnect
    // gate, in-tree gate), immediately after that episode has CLAIMED a
    // grace-slot event (so it genuinely owns it, not merely could-have).
    // A later, fully unrelated, otherwise-eligible connect must then NOT be
    // labelled by it: proof that closing clears the event, not just that
    // consumption is direction-gated.
    //
    // Red-proof (shared shape, one path skipped per test): comment out the
    // `closeSettlingEpisode()` call on the ONE path under test. Skipping it
    // leaves `settlingDeviceEpisodeID` stuck (never nil'd), so the very next
    // raw publish's `openDeviceEpisodeIfNeeded()` does not open a fresh
    // episode at all -- it silently reuses the dead, already-resolved one.
    // The claimed-but-never-consumed event, still tagged to that same
    // (never incremented) id, then matches trivially at the next settle's
    // "usable label already present" check, and the unrelated connect below
    // posts labelled instead of unlabelled at the cap. This is also this
    // suite's proof of the stale-binding regression itself (the Codex
    // high): a label event that outlives its own settle must never label a
    // later, unrelated one.

    /// Empty diff: two settles of the identical device list produce no
    /// added/removed groups at all, so `resolveDevicePost`'s
    /// `removedEligible || addedEligible` gate is false and the batch
    /// enqueues (never holds) immediately.
    func testEmptyDiffClosesEpisodeAndClearsItsEvent() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [:]
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["old-cable": "Old Cable"]))
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["old-cable": "Old Cable", "claimed-cable": "Claimed Cable"]))

        // Settling on an unchanged (empty) device list claims the grace
        // event, then immediately closes via the empty-diff gate.
        sequencer.runNowOrDelayForRecentChargerPost([])
        await flush(clock)
        XCTAssertTrue(posted.entries.isEmpty, "an empty diff produces no notification content at all")

        // A genuinely unrelated, otherwise-eligible connect must NOT be
        // labelled by the claimed-and-should-have-been-cleared event.
        sequencer.runNowOrDelayForRecentChargerPost([portLevelDevice(id: 1, name: "Unrelated Plug")])
        await flush(clock)
        XCTAssertTrue(posted.entries.isEmpty, "holds: no event survives the empty diff's close")

        await clock.advance(by: .seconds(5))
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 1)
        XCTAssertEqual(posted.entries[0].1.title, "Connected: Unrelated Plug", "must post unlabelled: the empty diff's own claimed event must not leak into a later, unrelated settle")
    }

    /// Notifications disabled: `diffDevices` returns before
    /// `resolveDevicePost` ever runs, so this episode's only terminal path
    /// is the `notifyOnChanges()` gate inside `diffDevices` itself.
    func testNotifyOnChangesOffClosesEpisodeAndClearsItsEvent() async {
        let clock = ManualClock()
        let posted = PostedLog()
        var notifyOnChanges = false
        let sequencer = makeSequencer(clock: clock, posted: posted, notifyOnChanges: { notifyOnChanges })
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [:]
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["old-cable": "Old Cable"]))
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["old-cable": "Old Cable", "claimed-cable": "Claimed Cable"]))

        // Notifications are off: this settle claims the grace event (the
        // episode opens regardless of `notifyOnChanges`), then closes via
        // the `notifyOnChanges()` gate before `resolveDevicePost` ever runs.
        sequencer.runNowOrDelayForRecentChargerPost([portLevelDevice(id: 1, name: "Silent Plug")])
        await flush(clock)
        XCTAssertTrue(posted.entries.isEmpty, "notifications are off: nothing posts")

        notifyOnChanges = true
        sequencer.knownDevices = [portLevelDevice(id: 1, name: "Silent Plug").id: snapshot(for: portLevelDevice(id: 1, name: "Silent Plug"))]
        sequencer.runNowOrDelayForRecentChargerPost([
            portLevelDevice(id: 1, name: "Silent Plug"),
            portLevelDevice(id: 2, bus: 0x06, name: "Unrelated Plug"),
        ])
        await flush(clock)
        XCTAssertTrue(posted.entries.isEmpty, "holds: no event survives the notify-off close")

        await clock.advance(by: .seconds(5))
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 1)
        XCTAssertEqual(posted.entries[0].1.title, "Connected: Unrelated Plug", "must post unlabelled: the notify-off episode's own claimed event must not leak into a later, unrelated settle")
    }

    /// Reconnect gate: `resolveDevicePost`'s `isReconnect` branch enqueues
    /// unconditionally and never even looks at `pendingCableLabelEvent`.
    func testReconnectGateClosesEpisodeAndClearsItsEvent() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.didPrimeBaseline = true
        let original = portLevelDevice(id: 1, name: "Flapping Device")
        sequencer.knownDevices = [original.id: snapshot(for: original)]
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["old-cable": "Old Cable"]))
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["old-cable": "Old Cable", "claimed-cable": "Claimed Cable"]))

        // Same locationID, same name, different id: a reconnect pair. This
        // settle claims the grace event, then closes via the reconnect
        // gate.
        let reconnected = USBDevice(
            id: 2, locationID: original.locationID, vendorID: 0, productID: 0,
            vendorName: nil, productName: "Flapping Device", serialNumber: nil,
            usbVersion: nil, speedRaw: 3, busPowerMA: nil, currentMA: nil,
            rawProperties: [:]
        )
        sequencer.runNowOrDelayForRecentChargerPost([reconnected])
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 1)
        XCTAssertEqual(posted.entries[0].1.title, "Reconnected: Flapping Device", "reconnects never label, structurally")
        XCTAssertEqual(posted.entries[0].1.subtitle, "", "reconnects never label, structurally: the subtitle must stay empty too")

        sequencer.knownDevices[reconnected.id] = snapshot(for: reconnected)
        sequencer.runNowOrDelayForRecentChargerPost([reconnected, portLevelDevice(id: 3, bus: 0x06, name: "Unrelated Plug")])
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 1, "holds: no event survives the reconnect gate's close")

        await clock.advance(by: .seconds(5))
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 2)
        XCTAssertEqual(posted.entries[1].1.title, "Connected: Unrelated Plug", "must post unlabelled: the reconnect's own claimed event must not leak into a later, unrelated settle")
    }

    /// In-tree gate: a change entirely inside an already-known, surviving
    /// tree has no port-level group at all, so `resolveDevicePost`'s
    /// `removedEligible || addedEligible` gate is false, same code path as
    /// the empty-diff case above but with a genuinely non-empty diff.
    func testInTreeGateClosesEpisodeAndClearsItsEvent() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [hubDevice(id: 10).id: snapshot(for: hubDevice(id: 10))]
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["old-cable": "Old Cable"]))
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["old-cable": "Old Cable", "claimed-cable": "Claimed Cable"]))

        // A child arrives under the already-known hub: in-tree, claims the
        // grace event, then closes via the in-tree gate.
        sequencer.runNowOrDelayForRecentChargerPost([hubDevice(id: 10), childDevice(id: 11)])
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 1)
        XCTAssertEqual(posted.entries[0].1.title, "Connected: Mouse", "in-tree changes never label, structurally")

        sequencer.knownDevices[childDevice(id: 11).id] = snapshot(for: childDevice(id: 11))
        sequencer.runNowOrDelayForRecentChargerPost([hubDevice(id: 10), childDevice(id: 11), portLevelDevice(id: 1, bus: 0x06, name: "Unrelated Plug")])
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 1, "holds: no event survives the in-tree gate's close")

        await clock.advance(by: .seconds(5))
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 2)
        XCTAssertEqual(posted.entries[1].1.title, "Connected: Unrelated Plug", "must post unlabelled: the in-tree gate's own claimed event must not leak into a later, unrelated settle")
    }

    // MARK: - Adversarial round 2 (P1-a, P1-b, P2)

    /// P1-a: a burst-heavy debounce must not age the grace slot past its
    /// window. A label event arrives at t=200ms, well before ANY raw
    /// publish; a burst of four publishes, 600ms apart, keeps
    /// `scheduleDeviceDiff`'s settle timer resetting with no upper bound, so
    /// the settle round doesn't actually FIRE until nearly 4 seconds later.
    /// The episode must open (and claim the grace event) at the FIRST
    /// publish of the burst, not when the settle eventually fires, so the
    /// connect still ends up labelled.
    ///
    /// Drives the REAL `scheduleDeviceDiff()` entry point (not
    /// `runNowOrDelayForRecentChargerPost` directly), since this is
    /// specifically about the debounce wrapper's own timing.
    ///
    /// Red-proof: revert `openDeviceEpisodeIfNeeded()`'s call site back to
    /// only `runNowOrDelayForRecentChargerPost`/`deferDeviceDiff` (remove it
    /// from `scheduleDeviceDiff()`) and this goes red -- the connect posts
    /// unlabelled, because by the time the episode finally opens (when the
    /// settle fires, ~3.9s after the label arrived), the grace event has
    /// long since expired against the 1500ms `deviceSettleWindow`.
    func testP1ABurstDebounceOpensEpisodeAtFirstPublishNotAtEventualSettle() async {
        let clock = ManualClock()
        let posted = PostedLog()
        var devices: [USBDevice] = []
        let sequencer = DeviceDiffSequencer(
            clock: clock,
            currentDevices: { devices },
            currentChargerSources: { [] },
            notifyOnChanges: { true },
            post: { category, content, _ in posted.entries.append((category, content)) },
            launchToken: "test-launch"
        )
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [:]
        sequencer.updateLabelledCables(feed(hasSavedCables: true))

        // t=0ms -> t=200ms: the label arrives first, nothing open yet.
        await clock.advance(by: .milliseconds(200))
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["cable-a": "Cable A"]))

        // Four raw publishes, 600ms apart, each resetting the settle timer.
        devices = [portLevelDevice(id: 1, name: "Cable Device")]
        sequencer.scheduleDeviceDiff() // publish #1 at t=200ms: opens the episode, claims the grace event immediately.
        await flush(clock)

        await clock.advance(by: .milliseconds(600)) // t=800ms
        sequencer.scheduleDeviceDiff() // publish #2: resets the debounce; episode already open, no-op.
        await flush(clock)

        await clock.advance(by: .milliseconds(600)) // t=1400ms
        sequencer.scheduleDeviceDiff() // publish #3
        await flush(clock)

        await clock.advance(by: .milliseconds(600)) // t=2000ms
        sequencer.scheduleDeviceDiff() // publish #4, the last of the burst
        await flush(clock)

        XCTAssertTrue(posted.entries.isEmpty, "nothing has settled yet: still mid-debounce")

        // The settle window (1500ms default) elapses from the LAST publish
        // (t=2000ms), so the round finally fires around t=3500ms -- well
        // past the label's own arrival at t=200ms.
        await clock.advance(by: .seconds(2))
        await flush(clock)

        XCTAssertEqual(posted.entries.count, 1)
        XCTAssertEqual(
            posted.entries[0].1.title, "Connected: Cable Device",
            "the episode opened (and claimed the grace event) at the FIRST publish of the burst, so the label survives the burst-extended settle"
        )
        XCTAssertEqual(posted.entries[0].1.subtitle, "Cable A")
    }

    /// P1-b: superseding a parked diff must not leak its event into the
    /// diff that replaces it. Device A parks (episode E, via the
    /// charger-deferral machinery); Cable A's event arrives and, with
    /// nothing settling, is assigned to E; an unrelated Device B then
    /// settles with NO charger settle pending and NO recent charger post
    /// (so `runNowOrDelayForRecentChargerPost`'s zero-delay branch runs,
    /// superseding E outright rather than landing it). B must post
    /// unlabelled, and E's event must not survive to leak into anything
    /// later either.
    ///
    /// Red-proof: dropping ONLY `closeParkedEpisode()` in
    /// `supersedeAnyParkedDiff()` does NOT turn this red (fresh episode ids
    /// plus the owner checks keep it green on their own; see
    /// `closeParkedEpisode()`'s doc comment). The mutation this test guards
    /// against is the ROOT CAUSE: skip freeing `settlingDeviceEpisodeID` at
    /// the park sites, so the superseding diff reuses the still-open id;
    /// that goes red here with B posting "Connected: Device B (Cable A)"
    /// instead of unlabelled.
    func testP1BSupersedingAParkedDiffClosesItsEpisodeInsteadOfLeakingItsEvent() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [:]
        sequencer.updateLabelledCables(feed(hasSavedCables: true))

        // Device A parks via the charger-deferral path: episode E opens and
        // is immediately handed to the park machinery.
        sequencer.deferDeviceDiff([portLevelDevice(id: 1, bus: 0x02, name: "Device A")])
        await flush(clock)
        XCTAssertTrue(posted.entries.isEmpty, "A is parked, not yet landed")

        // Cable A's event arrives: nothing is settling, so it is assigned
        // to the currently-parked episode E.
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["cable-a": "Cable A"]))
        await flush(clock)
        XCTAssertTrue(posted.entries.isEmpty)

        // An unrelated Device B settles via the REAL `.runNow` zero-delay
        // path (no charger settle pending, no recent charger post), which
        // supersedes A's still-parked diff outright rather than landing it.
        // With E's event correctly cleared, B finds no match and holds
        // (`hasSavedCables` is true and B is a fresh, port-level connect).
        sequencer.runNowOrDelayForRecentChargerPost([portLevelDevice(id: 2, bus: 0x06, name: "Device B")])
        await flush(clock)
        XCTAssertTrue(posted.entries.isEmpty, "B holds: no event survived to match it immediately")

        // B's own cap expires with nothing having ever matched it.
        await clock.advance(by: .seconds(5))
        await flush(clock)

        XCTAssertEqual(posted.entries.count, 1)
        XCTAssertEqual(
            posted.entries[0].1.title, "Connected: Device B",
            "B must post unlabelled: E's event belonged to the superseded parked diff, not to B"
        )
    }

    /// P2: a quick lock immediately followed by an unlock, with a pre-lock
    /// event still pending in the bounded GRACE slot (arrived while NO
    /// device episode was open at all, so nothing owns it yet, and nothing
    /// has closed to clear it), must not let that event survive to label a
    /// LATER, unrelated diff that settles within the grace claim window.
    /// Episode-close clearing alone cannot catch this case: an unowned
    /// grace event has no episode to close in the first place.
    ///
    /// Red-proof: drop the `if feed == nil { ... }` clearing block in
    /// `updateLabelledCables` and this goes red -- the later, unrelated
    /// connect posts "Connected: Device Two (Old Cable)" instead of
    /// unlabelled.
    func testP2QuickLockUnlockClearsAPendingGraceEventBeforeALaterDiffCanClaimIt() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [:]
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["old-cable": "Old Cable"]))

        // "new-cable" appears: a genuine ADD-direction event, arriving while
        // NO device episode is open at all. Lands in the bounded, unowned
        // grace slot.
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["old-cable": "Old Cable", "new-cable": "New Cable"]))

        // Lock, then IMMEDIATELY unlock (no clock advance between them).
        sequencer.updateLabelledCables(nil)
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["old-cable": "Old Cable", "new-cable": "New Cable"]))

        // A genuinely UNRELATED device connects, well within
        // `deviceSettleWindow` of the grace event's own arrival (no clock
        // advance at all): the exact timing "ordering permutation A" is
        // supposed to legitimately reward, EXCEPT this event should have
        // been wiped out by the lock/unlock cycle in between.
        sequencer.runNowOrDelayForRecentChargerPost([portLevelDevice(id: 2, bus: 0x06, name: "Device Two")])
        await flush(clock)

        XCTAssertTrue(posted.entries.isEmpty, "holds: the pre-lock grace event must not have survived to be claimed here")

        await clock.advance(by: .seconds(5))
        await flush(clock)

        XCTAssertEqual(posted.entries.count, 1)
        XCTAssertEqual(
            posted.entries[0].1.title, "Connected: Device Two",
            "must post UNLABELLED: the quick lock/unlock must have cleared the pre-lock grace event before a later, unrelated episode could claim it"
        )
    }

    // MARK: - Helper

    private func snapshot(for device: USBDevice) -> USBDeviceChangeGrouper.Snapshot {
        USBDeviceChangeGrouper.Snapshot(id: device.id, locationID: device.locationID, name: device.productName ?? "USB device")
    }
}
