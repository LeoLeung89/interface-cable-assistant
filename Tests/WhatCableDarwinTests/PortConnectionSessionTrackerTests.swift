import Foundation
import Testing
@testable import WhatCableCore
@testable import WhatCableDarwinBackend

/// `PortConnectionSessionTracker` is a pure type (no IOKit, no `Date`), so it
/// is exercised directly against hand-built `AppleHPMInterface` fixtures and
/// an injected fake clock. See the type's doc comment for the full
/// transition-rule matrix these tests pin.
@Suite("PortConnectionSessionTracker")
struct PortConnectionSessionTrackerTests {
    /// A hand-advanced fake monotonic clock. Tests move it forward
    /// explicitly rather than sleeping, so age assertions are exact and
    /// instant to run.
    final class FakeClock {
        private(set) var seconds: TimeInterval
        init(_ start: TimeInterval = 0) { seconds = start }
        func advance(by delta: TimeInterval) { seconds += delta }
        func now() -> TimeInterval { seconds }
    }

    private func makeTracker(_ clock: FakeClock) -> PortConnectionSessionTracker {
        PortConnectionSessionTracker(now: clock.now)
    }

    /// Minimal `AppleHPMInterface` fixture: only the fields the tracker
    /// reads (`id`, `connectionActive`, `plugEventCount`, `connectionCount`)
    /// vary per call; everything else is a fixed placeholder.
    private func makePort(
        id: UInt64,
        connectionActive: Bool?,
        plugEventCount: Int? = nil,
        connectionCount: Int? = nil
    ) -> AppleHPMInterface {
        AppleHPMInterface(
            id: id, serviceName: "Port-USB-C@1", className: "AppleHPMInterfaceType10",
            portDescription: "Port-USB-C@1", portTypeDescription: "USB-C",
            portNumber: 1, connectionActive: connectionActive,
            activeCable: nil, opticalCable: nil, usbActive: nil,
            superSpeedActive: nil, usbModeType: nil, usbConnectString: nil,
            transportsSupported: [], transportsActive: [], transportsProvisioned: [],
            plugOrientation: nil, plugEventCount: plugEventCount, connectionCount: connectionCount,
            overcurrentCount: nil, pinConfiguration: [:], powerCurrentLimits: [],
            firmwareVersion: nil, bootFlagsHex: nil,
            rawProperties: [:]
        )
    }

    // MARK: - First observation of an already-active port

    @Test("First observation of an already-active port leaves age unknown")
    func firstObservationOfAlreadyActivePortIsUnknown() {
        let clock = FakeClock()
        let tracker = makeTracker(clock)

        tracker.observe([makePort(id: 1, connectionActive: true, plugEventCount: 5)])
        clock.advance(by: 30)

        #expect(tracker.connectionAge(for: 1) == nil)
    }

    /// Relaunch mid-connection, then a #536 churn round-trip with the SAME
    /// token. The first-ever observation was already active, so age was
    /// never known (per the test above). The churn round-trip must NOT
    /// manufacture a stamp: restamping "now" would claim a possibly-hours-
    /// old connection was "just plugged in", which is exactly the wrong
    /// claim the nil-on-first-observation rule exists to prevent. Same
    /// token can't be a new plug (the counter increments per plug), so the
    /// only honest answer is to keep staying unknown.
    @Test("Relaunch mid-connection, then a churn round trip with the same token, still leaves age unknown")
    func relaunchMidConnectionThenChurnRoundTripStaysUnknown() {
        let clock = FakeClock()
        let tracker = makeTracker(clock)

        // First-ever observation: already active, unknown start.
        tracker.observe([makePort(id: 1, connectionActive: true, plugEventCount: 5)])
        let firstGeneration = tracker.sessionGeneration(for: 1)
        clock.advance(by: 10)
        #expect(tracker.connectionAge(for: 1) == nil)

        // #536 churn: the port drops out for a moment...
        tracker.observe([makePort(id: 1, connectionActive: false, plugEventCount: 5)])
        clock.advance(by: 1)

        // ...and comes back with the SAME token. This cannot be a new plug.
        tracker.observe([makePort(id: 1, connectionActive: true, plugEventCount: 5)])

        #expect(tracker.connectionAge(for: 1) == nil, "same-token churn must not manufacture a stamp")
        #expect(tracker.sessionGeneration(for: 1) == firstGeneration, "generation must not bump when age stays unknown")
    }

    // MARK: - false/nil -> true with a new token

    @Test("false to true with a new token stamps a fresh session and age advances")
    func falseToTrueWithNewTokenStamps() {
        let clock = FakeClock()
        let tracker = makeTracker(clock)

        tracker.observe([makePort(id: 1, connectionActive: false, plugEventCount: 1)])
        #expect(tracker.connectionAge(for: 1) == nil)

        tracker.observe([makePort(id: 1, connectionActive: true, plugEventCount: 2)])
        #expect(tracker.connectionAge(for: 1) == 0)

        clock.advance(by: 3.5)
        #expect(tracker.connectionAge(for: 1) == 3.5)
    }

    // MARK: - Churn round trip (#536): false -> true, token unchanged

    @Test("Churn round trip reuses the retained stamp; age is nil while inactive, then continuous")
    func churnRoundTripReusesStamp() {
        let clock = FakeClock()
        let tracker = makeTracker(clock)

        // Start from an inactive first observation so the plug below is a
        // real false -> true transition, not "first observation already
        // active" (which stamps nothing, covered by a separate test).
        tracker.observe([makePort(id: 1, connectionActive: false, plugEventCount: 7)])

        // Genuine plug: stamp at t=0.
        tracker.observe([makePort(id: 1, connectionActive: true, plugEventCount: 7)])
        clock.advance(by: 4)
        #expect(tracker.connectionAge(for: 1) == 4)

        // Attribution churn: port reports inactive for a moment (#536).
        tracker.observe([makePort(id: 1, connectionActive: false, plugEventCount: 7)])
        #expect(tracker.connectionAge(for: 1) == nil, "age must be nil while the port is inactive")

        clock.advance(by: 1)

        // Same token comes back active: the ORIGINAL stamp (t=0) is reused,
        // not a fresh one at t=5.
        tracker.observe([makePort(id: 1, connectionActive: true, plugEventCount: 7)])
        #expect(tracker.connectionAge(for: 1) == 5, "age must reflect the original stamp, not the churn return")
    }

    // MARK: - Coalesced replug: true -> true, token changed

    @Test("true to true with a changed token restamps and bumps the generation")
    func coalescedReplugRestamps() {
        let clock = FakeClock()
        let tracker = makeTracker(clock)

        // Start inactive so the first `true` observation is a real stamp
        // (first-observation-already-active stamps nothing; see above).
        tracker.observe([makePort(id: 1, connectionActive: false, plugEventCount: 1)])
        tracker.observe([makePort(id: 1, connectionActive: true, plugEventCount: 1)])
        let firstGeneration = tracker.sessionGeneration(for: 1)
        clock.advance(by: 10)
        #expect(tracker.connectionAge(for: 1) == 10)

        // No false observation ever seen; the token just changed under an
        // always-true reading (a rapid replug the watcher coalesced).
        tracker.observe([makePort(id: 1, connectionActive: true, plugEventCount: 2)])

        #expect(tracker.connectionAge(for: 1) == 0, "a coalesced replug must reset the age")
        #expect(tracker.sessionGeneration(for: 1) != firstGeneration, "generation must change on restamp")
    }

    // MARK: - false -> true with a changed token (plain new plug, not a churn case)

    @Test("false to true with a changed token restamps rather than reusing")
    func falseToTrueWithChangedTokenRestamps() {
        let clock = FakeClock()
        let tracker = makeTracker(clock)

        tracker.observe([makePort(id: 1, connectionActive: false, plugEventCount: 1)])
        tracker.observe([makePort(id: 1, connectionActive: true, plugEventCount: 1)])
        clock.advance(by: 8)
        tracker.observe([makePort(id: 1, connectionActive: false, plugEventCount: 1)])
        clock.advance(by: 2)

        // Different token on the return: a genuinely different cable/plug,
        // not the same #536 churn session.
        tracker.observe([makePort(id: 1, connectionActive: true, plugEventCount: 2)])

        #expect(tracker.connectionAge(for: 1) == 0, "a changed token must restamp, not reuse the old stamp")
    }

    // MARK: - Vanished id pruned

    @Test("A vanished port id is pruned; reappearing later is a fresh first observation")
    func vanishedIDIsPruned() {
        let clock = FakeClock()
        let tracker = makeTracker(clock)

        tracker.observe([makePort(id: 1, connectionActive: false, plugEventCount: 1)])
        tracker.observe([makePort(id: 1, connectionActive: true, plugEventCount: 1)])
        clock.advance(by: 20)
        #expect(tracker.connectionAge(for: 1) == 20)

        // Port entry id disappears from the registry entirely (not just
        // inactive: it's absent from the observed list).
        tracker.observe([])

        // It comes back active with the SAME token. Because its state was
        // pruned, this must be treated as a brand new first observation
        // (age unknown), not a churn reuse of the old stamp.
        tracker.observe([makePort(id: 1, connectionActive: true, plugEventCount: 1)])
        #expect(tracker.connectionAge(for: 1) == nil)
    }

    // MARK: - reset()

    @Test("reset() clears all tracked session state")
    func resetClearsAllState() {
        let clock = FakeClock()
        let tracker = makeTracker(clock)

        tracker.observe([makePort(id: 1, connectionActive: false, plugEventCount: 1)])
        tracker.observe([makePort(id: 1, connectionActive: true, plugEventCount: 1)])
        clock.advance(by: 5)
        #expect(tracker.connectionAge(for: 1) == 5)

        tracker.reset()
        #expect(tracker.connectionAge(for: 1) == nil)
        #expect(tracker.sessionGeneration(for: 1) == nil)

        // Confirm reset() really means "fresh tracker", not just "cleared
        // age": the same token reappearing active is once again an unknown
        // first observation, not a reuse of the pre-reset session.
        tracker.observe([makePort(id: 1, connectionActive: true, plugEventCount: 1)])
        #expect(tracker.connectionAge(for: 1) == nil)
    }

    // MARK: - Both tokens nil: plain transition stamping fallback

    @Test("A machine with no plugEventCount or connectionCount still stamps on false to true")
    func nilTokenMachineFallsBackToTransitionStamping() {
        let clock = FakeClock()
        let tracker = makeTracker(clock)

        tracker.observe([makePort(id: 1, connectionActive: false)])
        #expect(tracker.connectionAge(for: 1) == nil)

        tracker.observe([makePort(id: 1, connectionActive: true)])
        #expect(tracker.connectionAge(for: 1) == 0)

        clock.advance(by: 2)
        #expect(tracker.connectionAge(for: 1) == 2)

        // The accepted limitation: on a machine with no session token at
        // all, a #536 churn round trip cannot be told apart from a genuine
        // replug, so it is NOT reused (unlike the known-token case in
        // `churnRoundTripReusesStamp`). This is the part of the fallback
        // that a "just fall through when there's no prior stamp" shortcut
        // would silently get right by accident; exercising a SECOND
        // false->true transition (where a prior stamp genuinely exists)
        // is what actually pins the `.none` restamp-always behaviour.
        tracker.observe([makePort(id: 1, connectionActive: false)])
        #expect(tracker.connectionAge(for: 1) == nil)

        clock.advance(by: 1)
        tracker.observe([makePort(id: 1, connectionActive: true)])
        #expect(tracker.connectionAge(for: 1) == 0, "nil-token churn must restamp, not reuse")
    }

    // MARK: - Startup seeding (drain's inactive baseline), Codex gate finding

    /// Pins why `AppleHPMInterfaceWatcher.drain(iterator:)` (the initial
    /// matching-notification path run at `start()`) must feed the tracker
    /// too, not just `refresh()`. Without an inactive baseline observation
    /// first, a port whose FIRST-EVER observation is the plug itself (e.g.
    /// the user plugs in before `refresh()` has run once) looks to the
    /// tracker exactly like "already active on first sight" (an app
    /// relaunch mid-connection), and the age stays unknown for the whole
    /// connection: "Reading cable details..." never shows. Seeding an
    /// inactive baseline first (what `drain()` now does) turns the plug
    /// into a genuine false -> true transition, which stamps normally.
    @Test("A seeded inactive baseline lets a later plug stamp; without it the same plug stays unknown forever")
    func seededBaselineLetsLaterPlugStamp() {
        let clock = FakeClock()

        // Counterfactual: no baseline at all (the pre-fix drain() behaviour,
        // which never called observe()). The plug is this port's first-ever
        // observation, already active: age is unknown for good.
        let unseededTracker = makeTracker(clock)
        unseededTracker.observe([makePort(id: 1, connectionActive: true, plugEventCount: 3)])
        clock.advance(by: 5)
        #expect(unseededTracker.connectionAge(for: 1) == nil, "sanity: this is the bug shape the fix removes")

        // Fixed behaviour: drain() seeds an inactive baseline before the
        // user ever plugs anything in.
        let seededTracker = makeTracker(clock)
        seededTracker.observe([makePort(id: 1, connectionActive: false, plugEventCount: 3)])

        // The user plugs in; refresh() (via the interest-notification
        // callback) observes the same port now active.
        seededTracker.observe([makePort(id: 1, connectionActive: true, plugEventCount: 3)])
        #expect(seededTracker.connectionAge(for: 1) == 0, "the seeded baseline must let this stamp")

        clock.advance(by: 5)
        #expect(seededTracker.connectionAge(for: 1) == 5, "age must advance now that it's known")
    }

    // MARK: - retainedAttachInstant(for:): retained across transient inactive

    /// Stamped, currently active: the retained accessor must agree with the
    /// active-only accessor. Both read the same underlying stamp while the
    /// port is live.
    @Test("Retained instant matches the active accessor's value while the port is active")
    func retainedInstantMatchesActiveAccessorWhileActive() {
        let clock = FakeClock()
        let tracker = makeTracker(clock)

        tracker.observe([makePort(id: 1, connectionActive: false, plugEventCount: 1)])
        tracker.observe([makePort(id: 1, connectionActive: true, plugEventCount: 1)])
        clock.advance(by: 3)

        #expect(tracker.retainedAttachInstant(for: 1) == tracker.attachInstant(for: 1))
        #expect(tracker.retainedAttachInstant(for: 1) == 0)
    }

    /// Stamped, transiently inactive (a #536 churn dip on the same token):
    /// the active-only accessor goes nil, but the retained accessor must
    /// still return the original stamp. This is the whole reason the
    /// accessor exists: a settling-card timer must not lose its deadline
    /// during a churn dip.
    @Test("Retained instant survives a transient inactive interval that the active accessor loses")
    func retainedInstantSurvivesTransientInactive() {
        let clock = FakeClock()
        let tracker = makeTracker(clock)

        tracker.observe([makePort(id: 1, connectionActive: false, plugEventCount: 7)])
        tracker.observe([makePort(id: 1, connectionActive: true, plugEventCount: 7)])
        clock.advance(by: 4)

        // Attribution churn: same token drops out for a moment.
        tracker.observe([makePort(id: 1, connectionActive: false, plugEventCount: 7)])

        #expect(tracker.attachInstant(for: 1) == nil, "sanity: the active-only accessor loses the stamp")
        #expect(tracker.retainedAttachInstant(for: 1) == 0, "the retained accessor must keep the original stamp")
    }

    /// Never-stamped session: first observation arrived already active (a
    /// relaunch mid-connection), so age has been unknown from the start.
    /// The retained accessor must report the same "unknown", not
    /// manufacture a stamp.
    @Test("Retained instant is nil for a never-stamped (first-observation-active) session")
    func retainedInstantNilForNeverStamped() {
        let clock = FakeClock()
        let tracker = makeTracker(clock)

        tracker.observe([makePort(id: 1, connectionActive: true, plugEventCount: 5)])
        clock.advance(by: 30)

        #expect(tracker.retainedAttachInstant(for: 1) == nil)
    }

    /// A vanished port id is pruned from tracked state entirely. The
    /// retained accessor must return nil for it, same as the active-only
    /// accessor, not stale state from before the prune.
    @Test("Retained instant is nil for a pruned port id")
    func retainedInstantNilForPrunedID() {
        let clock = FakeClock()
        let tracker = makeTracker(clock)

        tracker.observe([makePort(id: 1, connectionActive: false, plugEventCount: 1)])
        tracker.observe([makePort(id: 1, connectionActive: true, plugEventCount: 1)])
        clock.advance(by: 20)
        #expect(tracker.retainedAttachInstant(for: 1) == 0, "sanity: the retained instant is the stamp, not the elapsed age")

        // Port entry id disappears from the registry entirely.
        tracker.observe([])

        #expect(tracker.retainedAttachInstant(for: 1) == nil)
    }

    /// reset() clears all tracked session state, the retained stamp
    /// included.
    @Test("Retained instant is nil after reset()")
    func retainedInstantNilAfterReset() {
        let clock = FakeClock()
        let tracker = makeTracker(clock)

        tracker.observe([makePort(id: 1, connectionActive: false, plugEventCount: 1)])
        tracker.observe([makePort(id: 1, connectionActive: true, plugEventCount: 1)])
        clock.advance(by: 5)
        #expect(tracker.retainedAttachInstant(for: 1) == 0)

        tracker.reset()
        #expect(tracker.retainedAttachInstant(for: 1) == nil)
    }

    /// A genuine new session (different token) restamps: the retained
    /// accessor must return the NEW instant, not the old one.
    @Test("Retained instant is replaced by a new session's restamp")
    func retainedInstantReplacedByNewSessionRestamp() {
        let clock = FakeClock()
        let tracker = makeTracker(clock)

        tracker.observe([makePort(id: 1, connectionActive: false, plugEventCount: 1)])
        tracker.observe([makePort(id: 1, connectionActive: true, plugEventCount: 1)])
        #expect(tracker.retainedAttachInstant(for: 1) == 0)

        clock.advance(by: 10)
        tracker.observe([makePort(id: 1, connectionActive: false, plugEventCount: 1)])
        clock.advance(by: 2)

        // Different token on the return: a genuine new plug.
        tracker.observe([makePort(id: 1, connectionActive: true, plugEventCount: 2)])

        #expect(tracker.retainedAttachInstant(for: 1) == 12, "must reflect the new session's stamp, not the old one")
    }

    // MARK: - Monotonic clock only, never Date

    @Test("The tracker source file never references Date")
    func trackerSourceNeverReferencesDate() throws {
        // Static guard, not just a design intent: grep the tracker's own
        // source file for `Date(` and fail if it's ever reintroduced. The
        // clock is injected as `() -> TimeInterval`; wiring a wall clock
        // back in here would silently reintroduce the NTP/manual-clock-jump
        // bug the spec calls out.
        let sourceFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // .../Tests/WhatCableDarwinTests
            .deletingLastPathComponent() // .../Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Sources/WhatCableDarwinBackend/Watchers/PortConnectionSessionTracker.swift")
        let contents = try String(contentsOf: sourceFile, encoding: .utf8)
        #expect(!contents.contains("Date("), "PortConnectionSessionTracker must never construct a Date")
    }

    /// `drain(iterator:)` runs real IOKit calls (`wcDrainAllRetrying`,
    /// registry reads), so it can't be invoked directly in a unit test the
    /// way `PortConnectionSessionTracker.observe(_:)` can. This pins the
    /// WIRING instead: `AppleHPMInterfaceWatcher`'s `drain(iterator:)`
    /// function body must call `sessionTracker.observe(ports)`, the fix for
    /// the Codex gate finding that drain-only startup left a port's first
    /// plug permanently unstamped. Isolates the check to `drain`'s own body
    /// (not the whole file) so it can't pass merely because `refresh()`
    /// calls `observe` too.
    @Test("AppleHPMInterfaceWatcher.drain(iterator:) feeds the session tracker")
    func drainFeedsSessionTracker() throws {
        let sourceFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // .../Tests/WhatCableDarwinTests
            .deletingLastPathComponent() // .../Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Sources/WhatCableDarwinBackend/Watchers/AppleHPMInterfaceWatcher.swift")
        let contents = try String(contentsOf: sourceFile, encoding: .utf8)

        guard let drainRange = contents.range(of: "private func drain(iterator: io_iterator_t) {") else {
            Issue.record("Could not locate drain(iterator:) in AppleHPMInterfaceWatcher.swift")
            return
        }
        // Take everything from the function signature to the next
        // top-level `\n    }` (a line containing only the method's closing
        // brace at 4-space indent), which is how every method in this file
        // is closed. Good enough for a source-shape guard without a full
        // Swift parser.
        let afterSignature = contents[drainRange.upperBound...]
        guard let closingBraceRange = afterSignature.range(of: "\n    }") else {
            Issue.record("Could not locate the end of drain(iterator:)")
            return
        }
        let drainBody = afterSignature[..<closingBraceRange.lowerBound]

        #expect(
            drainBody.contains("sessionTracker.observe(ports)"),
            "drain(iterator:) must feed the session tracker so a plug that lands before refresh() has ever run still gets an inactive baseline to stamp against"
        )
    }
}
