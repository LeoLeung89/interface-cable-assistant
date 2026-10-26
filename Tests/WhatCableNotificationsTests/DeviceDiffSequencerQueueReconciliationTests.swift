import XCTest
@testable import WhatCableNotifications
import WhatCableCore

/// fix2 (adversarial finding 2): `deviceQueue` used to be strict,
/// uncoalescing FIFO, so sustained device flapping grew an unbounded
/// backlog and replayed stale connect/disconnect notifications long after
/// the churn ended. This file exercises the fix: a bounded two-slot queue
/// (front + one reconciliation tail), a coalesced job's delta re-derived at
/// FIRE time from its endpoint snapshots (never from the stale groups it
/// was first created with), an exact-identity reconnect synthesis with a
/// taint veto, unlabelled coalesced posts, and an off-settle sweep of every
/// pending/held device job.
///
/// Two-slot scoping, as the spec puts it: a coalescing test needs a front
/// AND a tail to exist, then a THIRD settle to actually merge something
/// into the tail. Every test below drives one throwaway "warm-up" settle
/// first purely to establish a recent `lastDevicePostTime`, so the settles
/// that matter queue instead of firing synchronously.
///
/// Helpers duplicated from `DeviceDiffSequencerCableLabelHoldTests` rather
/// than shared (that file's own helpers are `private`), matching this test
/// target's existing convention.
@MainActor
final class DeviceDiffSequencerQueueReconciliationTests: XCTestCase {
    private func device(id: UInt64, bus: UInt8, name: String, vendorName: String? = nil) -> USBDevice {
        USBDevice(
            id: id, locationID: (UInt32(bus) << 24) | 0x0010_0000, vendorID: 0, productID: 0,
            vendorName: vendorName, productName: name, serialNumber: nil,
            usbVersion: nil, speedRaw: 3, busPowerMA: nil, currentMA: nil,
            rawProperties: [:]
        )
    }

    /// Same physical port (`locationID`) as another `device(id:bus:...)`
    /// call, but a caller-chosen `id`: used to fabricate a device
    /// "returning" at the same location, sometimes with the SAME id (to
    /// force an endpoint-empty delta on purpose, the only way an id-keyed
    /// diff can ever read a real intermediate flap as "nothing changed"),
    /// sometimes with a different one.
    private func deviceAt(bus: UInt8, id: UInt64, name: String, vendorName: String? = nil) -> USBDevice {
        device(id: id, bus: bus, name: name, vendorName: vendorName)
    }

    /// A device nested one level under whatever `device(id:bus:...)`/
    /// `deviceAt(bus:...)` device shares the same `bus`: a genuine child
    /// locationID (`0x0011_0000`, not the top-level `0x0010_0000` the two
    /// helpers above use), so a settle that adds/removes this alongside an
    /// already-known parent at the same `bus` reads as an IN-TREE change
    /// (never eligible for the cable-plausibility hold), mirroring
    /// `DeviceDiffSequencerCableLabelHoldTests`'s own `childDevice` helper.
    private func childDevice(id: UInt64, bus: UInt8, name: String) -> USBDevice {
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

    private final class ToggleBox {
        var value = true
    }

    private func makeSequencer(
        clock: ManualClock,
        posted: PostedLog,
        notifyOnChanges: ToggleBox = ToggleBox()
    ) -> DeviceDiffSequencer<ManualClock> {
        DeviceDiffSequencer(
            clock: clock,
            currentDevices: { [] },
            currentChargerSources: { [] },
            notifyOnChanges: { notifyOnChanges.value },
            post: { category, content, _ in posted.entries.append((category, content)) },
            launchToken: "test-launch"
        )
    }

    private func flush(_ clock: ManualClock) async {
        await clock.settle()
    }

    /// Drains a front-then-tail pair fully. `ManualClock.advance(by:)`
    /// moves `_now` in one jump and only resumes waiters already registered
    /// AGAINST THE OLD `_now`; the tail's own spacing wait is scheduled
    /// only once the front actually fires (relative to the ALREADY-ADVANCED
    /// clock), so a single big jump misses it. Advancing in `window`-sized
    /// steps, repeated enough times to cover every item the two-slot queue
    /// can ever hold, cascades through both waits correctly.
    private func drainQueueFully(_ clock: ManualClock, window: Duration, steps: Int = 4) async {
        for _ in 0..<steps {
            await clock.advance(by: window)
            await clock.settle()
        }
    }

    private func feed(hasSavedCables: Bool, _ attachedLabelled: [String: String] = [:]) -> NotificationDecision.CableLabelFeed {
        NotificationDecision.CableLabelFeed(hasSavedCables: hasSavedCables, attachedLabelled: attachedLabelled)
    }

    private func snapshot(for device: USBDevice) -> USBDeviceChangeGrouper.Snapshot {
        USBDeviceChangeGrouper.Snapshot(id: device.id, locationID: device.locationID, name: device.productName ?? "USB device")
    }

    // MARK: - Test 1: sustained flap, queue never exceeds two slots

    /// Sustained one-root flap, faster than the presentation gap drains:
    /// the queue must never grow past two slots, and the flap must produce
    /// at most one reconciled post beyond the front's own.
    ///
    /// Red-proof: revert `enqueueDevicePost` to unconditional append (drop
    /// the `count >= 2` merge check) and this goes red -- the queue depth
    /// assertion trips within the first few iterations of the loop.
    func testSustainedFlapQueueNeverExceedsTwoSlots() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.deferredDeviceDiffPresentationGapWindow = .milliseconds(100)
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [:]
        sequencer.updateLabelledCables(feed(hasSavedCables: false))

        sequencer.runNowOrDelayForRecentChargerPost([device(id: 100, bus: 0x09, name: "Warm-up")])
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 1)
        let baseline = posted.entries.count

        var nextID: UInt64 = 200
        var present = false
        for _ in 0..<20 {
            present.toggle()
            nextID += 1
            let devices: [USBDevice] = present
                ? [device(id: 100, bus: 0x09, name: "Warm-up"), device(id: nextID, bus: 0x02, name: "Flapper")]
                : [device(id: 100, bus: 0x09, name: "Warm-up")]
            sequencer.runNowOrDelayForRecentChargerPost(devices)
            await flush(clock)
            XCTAssertLessThanOrEqual(sequencer.deviceQueueDepthForTesting, 2, "queue must never grow past front + one reconciliation tail")
        }

        await drainQueueFully(clock, window: .milliseconds(100))

        XCTAssertLessThanOrEqual(posted.entries.count - baseline, 2, "at most the front's own post plus one reconciled post")
    }

    // MARK: - Test 2: A -> absent -> A, coalesced reconnect synthesis

    /// Three settles: front occupies the queue (unrelated content), a
    /// second settle removes A (creates the tail), a third settle brings A
    /// back at the SAME location, reusing the SAME registry id on purpose
    /// (the only way an id-keyed diff can read the round trip as an
    /// endpoint-empty delta -- see this file's own header comment). The
    /// merged tail must synthesize exactly one "Reconnected: A" post.
    ///
    /// Red-proof: make `synthesizedReconnectGroups(for:)` always return
    /// `nil` (skip synthesis outright) and this goes red -- the tail fires
    /// nothing instead of the reconnect.
    func testThreeSettlesAAbsentASynthesizesOneReconnect() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.deferredDeviceDiffPresentationGapWindow = .milliseconds(100)
        sequencer.didPrimeBaseline = true
        let a = deviceAt(bus: 0x02, id: 1, name: "A")
        sequencer.knownDevices = [a.id: snapshot(for: a)]
        sequencer.updateLabelledCables(feed(hasSavedCables: false))

        // Warm-up: fires synchronously, establishes lastDevicePostTime.
        sequencer.runNowOrDelayForRecentChargerPost([a, device(id: 10, bus: 0x09, name: "Warm-up")])
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 1)

        // Front: unrelated connect, queues (front slot).
        sequencer.runNowOrDelayForRecentChargerPost([a, device(id: 10, bus: 0x09, name: "Warm-up"), device(id: 11, bus: 0x0A, name: "Front Device")])
        await flush(clock)
        XCTAssertEqual(sequencer.deviceQueueDepthForTesting, 1)

        // Tail created: A removed.
        sequencer.runNowOrDelayForRecentChargerPost([device(id: 10, bus: 0x09, name: "Warm-up"), device(id: 11, bus: 0x0A, name: "Front Device")])
        await flush(clock)
        XCTAssertEqual(sequencer.deviceQueueDepthForTesting, 2)

        // Merges into the tail: A returns, SAME id as before.
        sequencer.runNowOrDelayForRecentChargerPost([
            device(id: 10, bus: 0x09, name: "Warm-up"), device(id: 11, bus: 0x0A, name: "Front Device"), deviceAt(bus: 0x02, id: 1, name: "A"),
        ])
        await flush(clock)
        XCTAssertEqual(sequencer.deviceQueueDepthForTesting, 2, "still bounded at two: the third settle merged into the tail rather than taking a third slot")

        await drainQueueFully(clock, window: .milliseconds(100))

        XCTAssertEqual(posted.entries.count, 3)
        XCTAssertEqual(posted.entries[1].1.title, "Connected: Front Device")
        XCTAssertEqual(posted.entries[2].1.title, "Reconnected: A", "the coalesced tail must synthesize exactly one reconnect presentation")
    }

    // MARK: - Test 3: absent -> A -> absent, coalesced job fires nothing

    /// Mirror of test 2 with the opposite net effect: A appears then
    /// disappears again within the tail's own span, ending absent just as
    /// it started. The endpoint delta is empty, no flap signature qualifies
    /// (A was never present at either endpoint), so the tail must fire
    /// NOTHING -- and, critically, must not stamp `lastDevicePostTime`: the
    /// very next real job must still space against the front's own post,
    /// not against the tail's no-op.
    ///
    /// Red-proof: stamp `lastDevicePostTime` unconditionally on every fire
    /// (including a coalesced job that posts nothing) and this goes red --
    /// the trailing job no longer fires synchronously the instant the tail
    /// resolves to nothing, because it now thinks a post just went out.
    func testThreeSettlesAbsentAAbsentFiresNothingAndDoesNotStamp() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.deferredDeviceDiffPresentationGapWindow = .milliseconds(100)
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [:]
        sequencer.updateLabelledCables(feed(hasSavedCables: false))

        sequencer.runNowOrDelayForRecentChargerPost([device(id: 10, bus: 0x09, name: "Warm-up")])
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 1)

        // Front: unrelated connect, queues.
        sequencer.runNowOrDelayForRecentChargerPost([device(id: 10, bus: 0x09, name: "Warm-up"), device(id: 11, bus: 0x0A, name: "Front Device")])
        await flush(clock)

        // Tail created: A appears.
        sequencer.runNowOrDelayForRecentChargerPost([
            device(id: 10, bus: 0x09, name: "Warm-up"), device(id: 11, bus: 0x0A, name: "Front Device"), deviceAt(bus: 0x02, id: 30, name: "A"),
        ])
        await flush(clock)

        // Merges into the tail: A disappears again.
        sequencer.runNowOrDelayForRecentChargerPost([device(id: 10, bus: 0x09, name: "Warm-up"), device(id: 11, bus: 0x0A, name: "Front Device")])
        await flush(clock)

        // t=100ms: front fires ("Connected: Front Device"), stamping
        // lastDevicePostTime, and schedules the tail's own 100ms wait.
        await clock.advance(by: .milliseconds(100))
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 2)
        XCTAssertEqual(posted.entries[1].1.title, "Connected: Front Device")

        // t=200ms: the tail's wait elapses. Its endpoint delta is empty and
        // no flap signature qualifies (A never touched either endpoint), so
        // it fires nothing.
        await clock.advance(by: .milliseconds(100))
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 2, "the coalesced job derives nothing to post")

        // Right now, with NO further clock advance, a genuinely new job
        // must post SYNCHRONOUSLY: the front's real post was already a full
        // 100ms ago at this instant, so the spacing floor is already
        // satisfied against it -- correct behaviour never waits again just
        // because the tail's no-op sat in between.
        sequencer.runNowOrDelayForRecentChargerPost([
            device(id: 10, bus: 0x09, name: "Warm-up"), device(id: 11, bus: 0x0A, name: "Front Device"), device(id: 40, bus: 0x0B, name: "Trailing Device"),
        ])
        await flush(clock)

        XCTAssertEqual(posted.entries.count, 3, "must post immediately: the trailing job spaces from the front's ACTUAL post, not from the tail's no-op")
        XCTAssertEqual(posted.entries[2].1.title, "Connected: Trailing Device")
    }

    // MARK: - Test 4: A -> absent -> B, atomic swap

    /// A removed, a DIFFERENT-named device B added at the same location,
    /// within the tail's span. The endpoint delta is genuinely non-empty
    /// (different ids, different names, so no reconnect pairing applies
    /// either), so this must fall straight through to the ordinary
    /// removed+added composition -- both halves posting from the SAME
    /// coalesced fire, never split across two separate jobs.
    ///
    /// Red-proof: after deriving the delta, drop any removed/added group
    /// pair that shares a `rootLocationID` (a pairwise per-root
    /// cancellation, the exact design Codex rejected) and this goes red --
    /// both "Disconnected: A" and "Connected: B" vanish.
    func testThreeSettlesAAbsentBAtomicSwap() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.deferredDeviceDiffPresentationGapWindow = .milliseconds(100)
        sequencer.didPrimeBaseline = true
        let a = deviceAt(bus: 0x02, id: 1, name: "A")
        sequencer.knownDevices = [a.id: snapshot(for: a)]
        sequencer.updateLabelledCables(feed(hasSavedCables: false))

        sequencer.runNowOrDelayForRecentChargerPost([a, device(id: 10, bus: 0x09, name: "Warm-up")])
        await flush(clock)

        sequencer.runNowOrDelayForRecentChargerPost([a, device(id: 10, bus: 0x09, name: "Warm-up"), device(id: 11, bus: 0x0A, name: "Front Device")])
        await flush(clock)

        // Tail created: A removed.
        sequencer.runNowOrDelayForRecentChargerPost([device(id: 10, bus: 0x09, name: "Warm-up"), device(id: 11, bus: 0x0A, name: "Front Device")])
        await flush(clock)

        // Merges into the tail: B, a different device, appears at A's OLD
        // physical port.
        sequencer.runNowOrDelayForRecentChargerPost([
            device(id: 10, bus: 0x09, name: "Warm-up"), device(id: 11, bus: 0x0A, name: "Front Device"), deviceAt(bus: 0x02, id: 99, name: "B"),
        ])
        await flush(clock)

        await drainQueueFully(clock, window: .milliseconds(100))

        XCTAssertEqual(posted.entries.count, 4)
        XCTAssertEqual(posted.entries[1].1.title, "Connected: Front Device")
        XCTAssertEqual(posted.entries[2].1.title, "Disconnected: A")
        XCTAssertEqual(posted.entries[3].1.title, "Connected: B")
    }

    // MARK: - Test 5: A -> B -> A at one location, taint veto

    /// A removed, B (a DIFFERENT device) added at the SAME location, then B
    /// removed and A returns with the SAME id it started with. The endpoint
    /// delta reads empty (A's id at both ends matches), and A's own removal
    /// qualifies on its own -- but B's occupancy in between taints that
    /// location, so nothing may synthesize. This is the exact counterexample
    /// Codex found against a bare "removed signature" rule.
    ///
    /// Red-proof: remove the taint-veto check (`allObservedSignatures`
    /// containing a different `rootName` at the same location) and this
    /// goes red -- the tail wrongly synthesizes "Reconnected: A" even
    /// though B occupied the port in between.
    func testAToBToAAtOneLocationVetoesSynthesis() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.deferredDeviceDiffPresentationGapWindow = .milliseconds(100)
        sequencer.didPrimeBaseline = true
        let a = deviceAt(bus: 0x02, id: 1, name: "A")
        sequencer.knownDevices = [a.id: snapshot(for: a)]
        sequencer.updateLabelledCables(feed(hasSavedCables: false))

        sequencer.runNowOrDelayForRecentChargerPost([a, device(id: 10, bus: 0x09, name: "Warm-up")])
        await flush(clock)

        sequencer.runNowOrDelayForRecentChargerPost([a, device(id: 10, bus: 0x09, name: "Warm-up"), device(id: 11, bus: 0x0A, name: "Front Device")])
        await flush(clock)

        // Tail created: A removed, B added at A's location.
        sequencer.runNowOrDelayForRecentChargerPost([
            device(id: 10, bus: 0x09, name: "Warm-up"), device(id: 11, bus: 0x0A, name: "Front Device"), deviceAt(bus: 0x02, id: 50, name: "B"),
        ])
        await flush(clock)

        // Merges into the tail: B removed, A returns with the SAME id it
        // originally had.
        sequencer.runNowOrDelayForRecentChargerPost([
            device(id: 10, bus: 0x09, name: "Warm-up"), device(id: 11, bus: 0x0A, name: "Front Device"), deviceAt(bus: 0x02, id: 1, name: "A"),
        ])
        await flush(clock)

        await drainQueueFully(clock, window: .milliseconds(100))

        XCTAssertEqual(posted.entries.count, 2, "the tail must synthesize nothing: B's presence in between taints A's own qualifying signature")
        XCTAssertEqual(posted.entries[1].1.title, "Connected: Front Device")
    }

    // MARK: - Test 6: multiple qualifying signatures, silence

    /// Two INDEPENDENT locations each do their own clean round trip within
    /// the same coalesced span (A at location 1, C at location 2, each
    /// reusing its own original id). Both individually qualify and neither
    /// is tainted, so more than one signature qualifies overall -- the
    /// conservative rule says synthesize nothing rather than guess.
    ///
    /// Red-proof: relax the qualifying check from `count == 1` to "take the
    /// first" and this goes red -- the tail wrongly posts a reconnect for
    /// whichever of the two happens to come first.
    func testMultipleQualifyingSignaturesStaysSilent() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.deferredDeviceDiffPresentationGapWindow = .milliseconds(100)
        sequencer.didPrimeBaseline = true
        let a = deviceAt(bus: 0x02, id: 1, name: "A")
        let c = deviceAt(bus: 0x03, id: 2, name: "C")
        sequencer.knownDevices = [a.id: snapshot(for: a), c.id: snapshot(for: c)]
        sequencer.updateLabelledCables(feed(hasSavedCables: false))

        sequencer.runNowOrDelayForRecentChargerPost([a, c, device(id: 10, bus: 0x09, name: "Warm-up")])
        await flush(clock)

        sequencer.runNowOrDelayForRecentChargerPost([a, c, device(id: 10, bus: 0x09, name: "Warm-up"), device(id: 11, bus: 0x0A, name: "Front Device")])
        await flush(clock)

        // Tail created: both A and C removed at once.
        sequencer.runNowOrDelayForRecentChargerPost([device(id: 10, bus: 0x09, name: "Warm-up"), device(id: 11, bus: 0x0A, name: "Front Device")])
        await flush(clock)

        // Merges into the tail: both A and C come back, SAME ids as before.
        sequencer.runNowOrDelayForRecentChargerPost([
            device(id: 10, bus: 0x09, name: "Warm-up"), device(id: 11, bus: 0x0A, name: "Front Device"),
            deviceAt(bus: 0x02, id: 1, name: "A"), deviceAt(bus: 0x03, id: 2, name: "C"),
        ])
        await flush(clock)

        await drainQueueFully(clock, window: .milliseconds(100))

        XCTAssertEqual(posted.entries.count, 2, "two roots both qualify: the conservative rule stays silent rather than picking one")
        XCTAssertEqual(posted.entries[1].1.title, "Connected: Front Device")
    }

    // MARK: - Test P2 (Codex fix-round): nested device under a new ancestor still taints

    /// Codex's exact counterexample: `USBDeviceChangeGrouper` folds a
    /// changed device beneath a simultaneously changed ancestor, so a
    /// device that arrives NESTED under a brand-new parent shows up only in
    /// that parent's `memberNames`, never as its own `ChangeGroup` root.
    /// Group-based taint evidence alone therefore never learns that
    /// device's (location, name) identity at all.
    ///
    /// A sits at location X. An intermediate settle adds a brand-new
    /// ancestor H at a shallower location, with B nested one level under H
    /// at EXACTLY location X (A's own former spot) -- B becomes a MEMBER of
    /// H's group, never a root of its own. A later settle removes H+B
    /// (again folded as one group, B a member) and A returns with its
    /// ORIGINAL id, so the endpoint delta reads empty and A's own removal
    /// signature qualifies on its own. Group-based taint evidence would
    /// only ever see (H's location, "H"), never (X, "B"), so it would
    /// wrongly read location X as untainted and synthesize "Reconnected: A"
    /// -- even though a different device (B) sat at X in between.
    ///
    /// Red-proof: revert `mergeIntoTail` to fold `allObservedSignatures`
    /// from `ChangeGroup`s only (drop the snapshot-based fold added for
    /// this fix) and this goes red -- the tail wrongly synthesizes
    /// "Reconnected: A" despite B's presence at A's own location.
    func testNestedDeviceUnderNewAncestorStillTaintsEvenThoughItNeverBecomesAGroupRoot() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.deferredDeviceDiffPresentationGapWindow = .milliseconds(100)
        sequencer.didPrimeBaseline = true
        let a = childDevice(id: 1, bus: 0x02, name: "A")
        sequencer.knownDevices = [a.id: snapshot(for: a)]
        sequencer.updateLabelledCables(feed(hasSavedCables: false))

        // Warm-up: fires synchronously, establishes lastDevicePostTime.
        sequencer.runNowOrDelayForRecentChargerPost([a, device(id: 10, bus: 0x09, name: "Warm-up")])
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 1)

        // Front: unrelated, queues.
        sequencer.runNowOrDelayForRecentChargerPost([a, device(id: 10, bus: 0x09, name: "Warm-up"), device(id: 11, bus: 0x0A, name: "Front Device")])
        await flush(clock)

        // Tail created: A removed.
        sequencer.runNowOrDelayForRecentChargerPost([device(id: 10, bus: 0x09, name: "Warm-up"), device(id: 11, bus: 0x0A, name: "Front Device")])
        await flush(clock)

        // Merges into the tail: a brand-new ancestor H arrives, with B
        // nested one level under it at EXACTLY A's own former location
        // (same bus, the `childDevice` locationID convention). Both H and B
        // are new in this same settle, so B folds as a MEMBER of H's
        // ChangeGroup, never its own root.
        let h = deviceAt(bus: 0x02, id: 2, name: "H")
        let b = childDevice(id: 3, bus: 0x02, name: "B")
        sequencer.runNowOrDelayForRecentChargerPost([
            device(id: 10, bus: 0x09, name: "Warm-up"), device(id: 11, bus: 0x0A, name: "Front Device"), h, b,
        ])
        await flush(clock)

        // Merges into the tail again: H+B both leave (again one group, B a
        // member), and A returns with the SAME id it started with, so the
        // endpoint delta reads empty.
        sequencer.runNowOrDelayForRecentChargerPost([
            device(id: 10, bus: 0x09, name: "Warm-up"), device(id: 11, bus: 0x0A, name: "Front Device"), childDevice(id: 1, bus: 0x02, name: "A"),
        ])
        await flush(clock)

        await drainQueueFully(clock, window: .milliseconds(100))

        XCTAssertEqual(posted.entries.count, 2, "no reconnect must synthesize: B occupied A's own location in between, even though B never became a ChangeGroup root")
        XCTAssertEqual(posted.entries[1].1.title, "Connected: Front Device")
    }

    // MARK: - Test 7: multi-root burst in one batch, unaffected

    /// A single settle with SIX roots connecting at once (no coalescing
    /// involved: the queue is empty, so this fires synchronously as one
    /// ordinary, non-coalesced job) must post exactly as today -- nothing
    /// coalesced, nothing discarded.
    ///
    /// Red-proof: truncate a non-coalesced job's `addedGroups` to the first
    /// 3 before composing (reintroducing a per-root cap) and this goes red
    /// -- three of the six device names go missing from the posted body.
    func testMultiRootBurstPostsAllSixUnaffected() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [:]
        sequencer.updateLabelledCables(feed(hasSavedCables: false))

        let roots = (1...6).map { device(id: UInt64($0), bus: UInt8($0), name: "Root \($0)") }
        sequencer.runNowOrDelayForRecentChargerPost(roots)
        await flush(clock)

        XCTAssertEqual(posted.entries.count, 1)
        XCTAssertEqual(posted.entries[0].1.title, "USB devices connected")
        for root in roots {
            XCTAssertTrue(posted.entries[0].1.body.contains(root.productName!), "\(root.productName!) must survive the burst, uncapped")
        }
    }

    // MARK: - Test 8: two quick distinct plugs, front + tail only, no merge

    /// Front and tail exist, but NO third settle ever arrives to merge
    /// anything into the tail (the ruling's own regression fence): both
    /// must keep firing as two distinct, individually LABELLED posts,
    /// byte-identical to what this file's pre-fix2 behaviour already did.
    ///
    /// Red-proof: lower the merge threshold from `deviceQueue.count >= 2` to
    /// `>= 1` (merge starting at depth two total, i.e. as soon as a front
    /// alone exists) and this goes red -- the second post's label vanishes,
    /// because a merge unconditionally drops captured labels.
    func testTwoQuickDistinctPlugsKeepBothLabelsNoMerge() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.deferredDeviceDiffPresentationGapWindow = .milliseconds(100)
        sequencer.didPrimeBaseline = true
        let hub = deviceAt(bus: 0x03, id: 500, name: "Hub")
        let child = childDevice(id: 501, bus: 0x03, name: "Mouse")
        sequencer.knownDevices = [hub.id: snapshot(for: hub)]
        // Establish a non-nil baseline with no event of its own.
        sequencer.updateLabelledCables(feed(hasSavedCables: true, [:]))

        // Warm-up: an in-tree change, always posts immediately, never
        // touches the hold/label machinery.
        sequencer.runNowOrDelayForRecentChargerPost([hub, child])
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 1)

        // Plug A: a NEW port-level device, its label already peeked and
        // consumed via the pre-episode grace slot (the event is delivered
        // BEFORE the episode opens, so it lands in grace and is claimed the
        // instant `runNowOrDelayForRecentChargerPost` opens a fresh one).
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["cable-a": "Cable A"]))
        let plugA = deviceAt(bus: 0x02, id: 600, name: "Plug A")
        sequencer.runNowOrDelayForRecentChargerPost([hub, child, plugA])
        await flush(clock)
        XCTAssertEqual(sequencer.deviceQueueDepthForTesting, 1, "queues as the front, carrying its own captured label")

        // Plug B: a second NEW port-level device, own distinct label,
        // appended as the tail (front + tail = exactly two, no merge).
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["cable-a": "Cable A", "cable-b": "Cable B"]))
        let plugB = deviceAt(bus: 0x04, id: 700, name: "Plug B")
        sequencer.runNowOrDelayForRecentChargerPost([hub, child, plugA, plugB])
        await flush(clock)
        XCTAssertEqual(sequencer.deviceQueueDepthForTesting, 2, "appended as a plain tail, not merged")

        await drainQueueFully(clock, window: .milliseconds(100))

        XCTAssertEqual(posted.entries.count, 3)
        XCTAssertEqual(posted.entries[1].1.title, "Connected: Plug A")
        XCTAssertEqual(posted.entries[1].1.subtitle, "Cable A")
        XCTAssertEqual(posted.entries[2].1.title, "Connected: Plug B", "must keep its OWN label: never merged, so never coalesced-and-unlabelled")
        XCTAssertEqual(posted.entries[2].1.subtitle, "Cable B")
    }

    // MARK: - Test 9: a labelled job merged into a tail fires unlabelled

    /// A tail that already captured a label (from its OWN settle) absorbs a
    /// further, unrelated settle via a genuine merge: the final post must
    /// carry NO label at all, whatever the merge's own content turns out to
    /// be.
    ///
    /// Red-proof, verified precisely (both single-guard mutations were
    /// actually tried, not assumed): the two "never labelled" guards are
    /// structurally coupled, so NEITHER alone turns this red.
    /// `mergeIntoTail` sets `coalesced = true` and `capturedLabel = nil` in
    /// the SAME step, so a coalesced job's `capturedLabel` is always nil by
    /// construction; `fireDevicePostJob`'s coalesced branch then hardcodes
    /// `addedCableLabel: nil, removedCableLabel: nil` on top, never reading
    /// `job.capturedLabel` at all. Reverting ONLY the merge-time drop (keep
    /// the newest label instead of dropping both) stays GREEN, because the
    /// fire-time hardcode still passes `nil` regardless. Reverting ONLY the
    /// fire-time hardcode (read `job.capturedLabel` instead) ALSO stays
    /// GREEN, because the merge-time drop has already guaranteed there is
    /// nothing but `nil` to read. Only reverting BOTH together turns this
    /// red -- the final post then carries "(Cable A)" even though it was
    /// coalesced.
    func testLabelledJobMergedIntoTailFiresUnlabelled() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.deferredDeviceDiffPresentationGapWindow = .milliseconds(100)
        sequencer.didPrimeBaseline = true
        let hub = deviceAt(bus: 0x03, id: 700, name: "Hub")
        sequencer.knownDevices = [hub.id: snapshot(for: hub)]
        sequencer.updateLabelledCables(feed(hasSavedCables: true, [:]))

        // Warm-up: an in-tree change (a real child locationID under the
        // already-known hub), never eligible for the hold, always posts
        // (or queues) immediately.
        let mouse = childDevice(id: 701, bus: 0x03, name: "Mouse")
        sequencer.runNowOrDelayForRecentChargerPost([hub, mouse])
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 1)

        // Front: a SECOND in-tree change (an unrelated child under the same
        // stable hub), again never eligible for the hold, so it queues as
        // an ordinary job rather than getting stuck on the label gate.
        let keyboard = childDevice(id: 702, bus: 0x03, name: "Keyboard")
        sequencer.runNowOrDelayForRecentChargerPost([hub, mouse, keyboard])
        await flush(clock)
        XCTAssertEqual(sequencer.deviceQueueDepthForTesting, 1)

        // Tail created: A connects (port-level), its label already peeked
        // via the grace slot -- captured immediately, no hold.
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["cable-a": "Cable A"]))
        let a = deviceAt(bus: 0x02, id: 900, name: "A")
        sequencer.runNowOrDelayForRecentChargerPost([hub, mouse, keyboard, a])
        await flush(clock)
        XCTAssertEqual(sequencer.deviceQueueDepthForTesting, 2)

        // Merges into the tail: an unrelated device Z connects too, again
        // in-tree (a further child under the stable hub) so its OWN settle
        // goes straight to `enqueueDevicePost` rather than starting a
        // second, unrelated hold of its own.
        let z = childDevice(id: 950, bus: 0x03, name: "Z")
        sequencer.runNowOrDelayForRecentChargerPost([hub, mouse, keyboard, a, z])
        await flush(clock)

        await drainQueueFully(clock, window: .milliseconds(100))

        XCTAssertEqual(posted.entries.count, 3)
        XCTAssertEqual(posted.entries[1].1.title, "Connected: Keyboard")
        XCTAssertEqual(posted.entries[2].1.title, "USB devices connected", "coalesced: merged multi-root title, no cable label anywhere")
        XCTAssertFalse(posted.entries[2].1.title.contains("Cable A"), "the tail's own captured label must not survive the merge")
        XCTAssertEqual(posted.entries[2].1.subtitle, "", "coalesced merge drops the label entirely: the subtitle must be empty, not just absent from the title")
    }

    // MARK: - Test 10/11: notifications-off sweeps pending device work

    /// An off-settle while ONE front is sleeping clears the queue outright;
    /// re-enabling notifications afterward produces no catch-up post.
    ///
    /// Red-proof: make the off-settle sweep a no-op (leave `deviceQueue`
    /// untouched) and this goes red -- the front's post appears once
    /// notifications come back on and the clock advances.
    func testOffSettleWhileFrontSleepsClearsTheQueue() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let toggle = ToggleBox()
        let sequencer = makeSequencer(clock: clock, posted: posted, notifyOnChanges: toggle)
        sequencer.deferredDeviceDiffPresentationGapWindow = .milliseconds(100)
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [:]
        sequencer.updateLabelledCables(feed(hasSavedCables: false))

        sequencer.runNowOrDelayForRecentChargerPost([device(id: 10, bus: 0x09, name: "Warm-up")])
        await flush(clock)
        XCTAssertEqual(posted.entries.count, 1)

        // Front: queues.
        sequencer.runNowOrDelayForRecentChargerPost([device(id: 10, bus: 0x09, name: "Warm-up"), device(id: 11, bus: 0x0A, name: "Front Device")])
        await flush(clock)
        XCTAssertEqual(sequencer.deviceQueueDepthForTesting, 1)

        toggle.value = false
        // A settle that OBSERVES the off state: any content works, the
        // sweep is unconditional once notifyOnChanges reads false here.
        sequencer.runNowOrDelayForRecentChargerPost([device(id: 10, bus: 0x09, name: "Warm-up"), device(id: 11, bus: 0x0A, name: "Front Device"), device(id: 20, bus: 0x0B, name: "Off-settle noise")])
        await flush(clock)
        XCTAssertEqual(sequencer.deviceQueueDepthForTesting, 0, "the off-settle must sweep the queue")

        toggle.value = true
        await clock.advance(by: .seconds(5))
        await flush(clock)

        XCTAssertEqual(posted.entries.count, 1, "no catch-up post: the front's job was swept, not merely delayed")
    }

    /// An off-settle while a front AND a tail both exist clears both, again
    /// with no catch-up post once notifications come back on.
    ///
    /// Red-proof: same as above, sweeping being a no-op leaves both jobs
    /// intact and they eventually post once re-enabled.
    func testOffSettleWhileFrontAndTailExistClearsBoth() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let toggle = ToggleBox()
        let sequencer = makeSequencer(clock: clock, posted: posted, notifyOnChanges: toggle)
        sequencer.deferredDeviceDiffPresentationGapWindow = .milliseconds(100)
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [:]
        sequencer.updateLabelledCables(feed(hasSavedCables: false))

        sequencer.runNowOrDelayForRecentChargerPost([device(id: 10, bus: 0x09, name: "Warm-up")])
        await flush(clock)

        sequencer.runNowOrDelayForRecentChargerPost([device(id: 10, bus: 0x09, name: "Warm-up"), device(id: 11, bus: 0x0A, name: "Front Device")])
        await flush(clock)

        sequencer.runNowOrDelayForRecentChargerPost([device(id: 10, bus: 0x09, name: "Warm-up"), device(id: 11, bus: 0x0A, name: "Front Device"), device(id: 12, bus: 0x0C, name: "Tail Device")])
        await flush(clock)
        XCTAssertEqual(sequencer.deviceQueueDepthForTesting, 2)

        toggle.value = false
        sequencer.runNowOrDelayForRecentChargerPost([device(id: 10, bus: 0x09, name: "Warm-up"), device(id: 11, bus: 0x0A, name: "Front Device"), device(id: 12, bus: 0x0C, name: "Tail Device"), device(id: 21, bus: 0x0D, name: "Off-settle noise")])
        await flush(clock)
        XCTAssertEqual(sequencer.deviceQueueDepthForTesting, 0)

        toggle.value = true
        await clock.advance(by: .seconds(5))
        await flush(clock)

        XCTAssertEqual(posted.entries.count, 1, "warm-up only: neither the swept front nor the swept tail ever catches up")
    }

    // MARK: - Test 12: a no-content settle during pending work leaves the chain intact

    /// A no-op settle (the SAME device list, nothing changed) arriving
    /// while a front and a tail are already pending must merge harmlessly
    /// into the tail (design 1's "empty enabled diffs still enqueue" case,
    /// pre-existing behaviour) without corrupting what the tail eventually
    /// posts.
    func testNoContentSettleDuringPendingWorkLeavesChainIntact() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.deferredDeviceDiffPresentationGapWindow = .milliseconds(100)
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [:]
        sequencer.updateLabelledCables(feed(hasSavedCables: false))

        sequencer.runNowOrDelayForRecentChargerPost([device(id: 10, bus: 0x09, name: "Warm-up")])
        await flush(clock)

        sequencer.runNowOrDelayForRecentChargerPost([device(id: 10, bus: 0x09, name: "Warm-up"), device(id: 11, bus: 0x0A, name: "Front Device")])
        await flush(clock)

        let p = deviceAt(bus: 0x02, id: 300, name: "P")
        sequencer.runNowOrDelayForRecentChargerPost([device(id: 10, bus: 0x09, name: "Warm-up"), device(id: 11, bus: 0x0A, name: "Front Device"), p])
        await flush(clock)
        XCTAssertEqual(sequencer.deviceQueueDepthForTesting, 2)

        // No-op settle: the exact same device list, nothing changed.
        sequencer.runNowOrDelayForRecentChargerPost([device(id: 10, bus: 0x09, name: "Warm-up"), device(id: 11, bus: 0x0A, name: "Front Device"), p])
        await flush(clock)
        XCTAssertEqual(sequencer.deviceQueueDepthForTesting, 2, "a no-op settle merges harmlessly rather than taking a new slot")

        await drainQueueFully(clock, window: .milliseconds(100))

        XCTAssertEqual(posted.entries.count, 3)
        XCTAssertEqual(posted.entries[1].1.title, "Connected: Front Device")
        XCTAssertEqual(posted.entries[2].1.title, "Connected: P", "the no-op settle must not have altered what the tail posts")
    }

    // MARK: - Test 12b: an off-settle cancels a HELD batch outright

    /// A batch held on the cable-plausibility gate (no label yet) must
    /// never post, not even at its own 5s cap, once an off-settle observes
    /// notifications disabled.
    ///
    /// Red-proof: leave the held batch alone in the sweep (skip clearing
    /// `heldDeviceBatch`/cancelling its deadline task) and this goes red --
    /// it posts unlabelled at the cap regardless.
    func testOffSettleCancelsAHeldBatchOutright() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let toggle = ToggleBox()
        let sequencer = makeSequencer(clock: clock, posted: posted, notifyOnChanges: toggle)
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [:]
        sequencer.updateLabelledCables(feed(hasSavedCables: true))

        sequencer.runNowOrDelayForRecentChargerPost([deviceAt(bus: 0x02, id: 1, name: "Cable Device")])
        await flush(clock)
        XCTAssertTrue(posted.entries.isEmpty, "held, no label yet")

        toggle.value = false
        sequencer.runNowOrDelayForRecentChargerPost([deviceAt(bus: 0x02, id: 1, name: "Cable Device")])
        await flush(clock)

        toggle.value = true
        await clock.advance(by: .seconds(10))
        await flush(clock)

        XCTAssertTrue(posted.entries.isEmpty, "the held batch must never post, not even at its own cap")
    }

    // MARK: - Test 12c: episode teardown on that cancellation

    /// After an off-settle cancels a held batch, re-enabling notifications
    /// and then delivering a fresh pre-episode label event must let the
    /// NEXT genuinely eligible plug claim it. This only holds if the
    /// cancellation properly closes the held episode: leaving
    /// `heldDeviceBatchEpisodeID` set (but the batch itself gone) would
    /// route the next label event into that dead slot instead of the grace
    /// slot, and the new episode would never see it.
    ///
    /// Red-proof: omit the `closeHeldEpisode()` call from the sweep and
    /// this goes red -- the new plug posts unlabelled instead of picking up
    /// the fresh event.
    func testEpisodeTeardownOnCancellationLetsTheNextEpisodeClaimTheLabel() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let toggle = ToggleBox()
        let sequencer = makeSequencer(clock: clock, posted: posted, notifyOnChanges: toggle)
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [:]
        sequencer.updateLabelledCables(feed(hasSavedCables: true))

        sequencer.runNowOrDelayForRecentChargerPost([deviceAt(bus: 0x02, id: 1, name: "Cable Device")])
        await flush(clock)
        XCTAssertTrue(posted.entries.isEmpty, "held")

        toggle.value = false
        sequencer.runNowOrDelayForRecentChargerPost([deviceAt(bus: 0x02, id: 1, name: "Cable Device")])
        await flush(clock)

        toggle.value = true

        // A pre-episode label event: delivered with no device episode open
        // at all, so it lands in the bounded grace slot.
        sequencer.updateLabelledCables(feed(hasSavedCables: true, ["fresh-cable": "Fresh Cable"]))

        // A NEW, genuinely eligible plug: opens a fresh episode, which
        // claims the grace event immediately (well within its window).
        sequencer.runNowOrDelayForRecentChargerPost([deviceAt(bus: 0x02, id: 1, name: "Cable Device"), deviceAt(bus: 0x03, id: 2, name: "New Device")])
        await flush(clock)

        XCTAssertEqual(posted.entries.count, 1)
        XCTAssertEqual(posted.entries[0].1.title, "Connected: New Device", "a properly closed held episode must not swallow the next event")
        XCTAssertEqual(posted.entries[0].1.subtitle, "Fresh Cable")
    }

    // MARK: - Test 13: latest body wins

    /// A device present at fire time gets its notification body from the
    /// NEWEST body map recorded across the coalesced span, not the one
    /// captured when the tail was first created.
    ///
    /// Red-proof: on merge, keep the tail's ORIGINAL `bodyMap` instead of
    /// overwriting it with the incoming job's, and this goes red -- the
    /// posted body carries the stale vendor string.
    func testLatestBodyWins() async {
        let clock = ManualClock()
        let posted = PostedLog()
        let sequencer = makeSequencer(clock: clock, posted: posted)
        sequencer.deferredDeviceDiffPresentationGapWindow = .milliseconds(100)
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [:]
        sequencer.updateLabelledCables(feed(hasSavedCables: false))

        sequencer.runNowOrDelayForRecentChargerPost([device(id: 10, bus: 0x09, name: "Warm-up")])
        await flush(clock)

        sequencer.runNowOrDelayForRecentChargerPost([device(id: 10, bus: 0x09, name: "Warm-up"), device(id: 11, bus: 0x0A, name: "Front Device")])
        await flush(clock)

        // Tail created: P connects, first reported with vendor "Old Vendor".
        let pOld = device(id: 900, bus: 0x02, name: "P", vendorName: "Old Vendor")
        sequencer.runNowOrDelayForRecentChargerPost([device(id: 10, bus: 0x09, name: "Warm-up"), device(id: 11, bus: 0x0A, name: "Front Device"), pOld])
        await flush(clock)

        // Merges into the tail: the SAME device P (same id, still present),
        // but this settle's own body map reports a DIFFERENT vendor string.
        let pNew = device(id: 900, bus: 0x02, name: "P", vendorName: "New Vendor")
        sequencer.runNowOrDelayForRecentChargerPost([device(id: 10, bus: 0x09, name: "Warm-up"), device(id: 11, bus: 0x0A, name: "Front Device"), pNew])
        await flush(clock)

        await drainQueueFully(clock, window: .milliseconds(100))

        XCTAssertEqual(posted.entries.count, 3)
        XCTAssertEqual(posted.entries[1].1.title, "Connected: Front Device")
        XCTAssertEqual(posted.entries[2].1.title, "Connected: P")
        XCTAssertTrue(posted.entries[2].1.body.contains("New Vendor"), "body must come from the newest body map")
        XCTAssertFalse(posted.entries[2].1.body.contains("Old Vendor"), "the stale body map must not survive the merge")
    }

    // MARK: - Test 14: derivation parity

    /// `DeviceDiffSequencer.deriveDeviceDelta` is the single pure function
    /// `diffDevices` and a coalesced job's fire-time reconciliation are both
    /// WRITTEN to call (verified by reading the source, not by this test).
    /// What THIS test proves: the helper's own arithmetic is correct --
    /// its ENTIRE returned value (groups, ordering included, both endpoint
    /// location sets, and body lookups) matches an INDEPENDENTLY
    /// hand-derived expectation, computed straight from
    /// `USBDeviceChangeGrouper.diff` and `NotificationDecision.thunderboltInvolved`,
    /// never by comparing two calls to the factored function itself (which
    /// would prove nothing about drift). It does NOT, by itself, prove the
    /// two call sites stay factored through this function going forward --
    /// a future edit that reintroduces an inline `USBDeviceChangeGrouper.diff`
    /// call at either site would not be caught here; that invariant is a
    /// property of the source, checked by reading `diffDevices` and
    /// `fireDevicePostJob`, not by any assertion this test makes.
    ///
    /// Red-proof: fork the logic -- change `deriveDeviceDelta`'s call to
    /// `USBDeviceChangeGrouper.diff` to swap its `previous`/`current`
    /// arguments -- and this goes red -- the derived `addedGroups`/
    /// `removedGroups` no longer match the independently-derived
    /// expectation.
    func testDerivationParityAgainstIndependentlyHandDerivedExpectation() {
        let previous = [
            USBDeviceChangeGrouper.Snapshot(id: 1, locationID: 0x0210_0000, name: "A"),
            USBDeviceChangeGrouper.Snapshot(id: 2, locationID: 0x0310_0000, name: "B"),
        ]
        let current = [
            USBDeviceChangeGrouper.Snapshot(id: 2, locationID: 0x0310_0000, name: "B"),
            USBDeviceChangeGrouper.Snapshot(id: 3, locationID: 0x0410_0000, name: "C"),
        ]
        let previousTB: Set<Int64> = [100]
        let currentTB: Set<Int64> = [100, 200]
        let bodyMap: [UInt64: String] = [3: "USB 3.x · Some Vendor"]

        let derivation = DeviceDiffSequencer<ManualClock>.deriveDeviceDelta(
            previousSnapshots: previous, currentSnapshots: current,
            previousTBSwitchIDs: previousTB, currentTBSwitchIDs: currentTB,
            bodyMap: bodyMap
        )

        // Independently hand-derived: straight calls to the raw primitives,
        // not a second invocation of `deriveDeviceDelta`.
        let expected = USBDeviceChangeGrouper.diff(previous: previous, current: current)
        let expectedTBInvolved = NotificationDecision.thunderboltInvolved(previous: previousTB, current: currentTB)

        XCTAssertEqual(derivation.addedGroups, expected.added)
        XCTAssertEqual(derivation.removedGroups, expected.removed)
        XCTAssertEqual(derivation.previousLocationIDs, Set(previous.map(\.locationID)))
        XCTAssertEqual(derivation.currentLocationIDs, Set(current.map(\.locationID)))
        XCTAssertEqual(derivation.thunderboltInvolved, expectedTBInvolved)
        XCTAssertEqual(derivation.singleDeviceBody(3), bodyMap[3])
        XCTAssertNil(derivation.singleDeviceBody(999), "a rootID absent from the body map must read nil, not crash or default")
    }
}
