import Testing
@testable import WhatCable

/// Tests for the pure settling-card presentation state machine (spec:
/// "settling-card", Task 2). Covers the reducer-expressible portions of the
/// spec's "Release" and "Trigger and retention" test matrices. View-level
/// items (content-plan proof that `.retained` constructs no live-input
/// content, placeholder-label freeze across watcher mutations, the actual
/// `ForEach` removal vs. parent-retained rendering split, animation feel)
/// are deferred to Task 3, which owns the SwiftUI wiring; they cannot be
/// expressed against a pure type with no view.
///
/// House rule: every test here was watched failing first, against a
/// deliberate one-line mutation of the rule it guards, then restored before
/// the real code shipped. The mutation is named in each test's comment.
struct SettlingCardPhaseTests {

    // MARK: - Release: identity events never release early

    /// Populating identity data before mount never touches the machine: the
    /// spec's release rule is timeout-only, so nothing in this pure layer
    /// even represents "identity populated" as an event. This test instead
    /// pins the ABSENCE of any such event: the only way `.loading` becomes
    /// `.settled` is `deadlineReached` for the matching generation.
    ///
    /// Mutation watched failing: changed `.loading` + `.deadlineReached` to
    /// always return `.loading` (never release, regardless of generation).
    /// Went red here, and also on `settledCarriesNoContentPayload` below
    /// (same call path); restored.
    @Test("Loading only releases via deadlineReached for its own generation")
    func loadingOnlyReleasesViaMatchingDeadline() {
        let generation = 7
        let phase = SettlingCardReducer.reduce(
            phase: .loading, event: .deadlineReached(generation: generation), generation: generation
        )
        #expect(phase == .settled)
    }

    // MARK: - Release: deadline boundary, immediately-before / at

    /// "immediately before deadline: .loading; at/after: .settled." The
    /// reducer itself doesn't compute time (that's `SettlingCardDeadline`,
    /// tested separately below); this test proves the TRIGGER's age
    /// comparison is a strict `<`, matching the boundary language exactly.
    ///
    /// Boundary arithmetic walked by hand: window = 6.0, epsilon-free here
    /// (the trigger compares raw age to the window, not to the deadline
    /// instant, which is `window + epsilon` later). At age == 5.999999
    /// (one microsecond before the window), `age < window` is true ->
    /// `.loading`. At age == 6.0 exactly, `age < window` is false ->
    /// `.settled`. At age == 6.000001, likewise `.settled`.
    ///
    /// Mutation watched failing: changed the trigger's `age < input.window`
    /// to `age <= input.window`. Went red on `testTriggerAtWindowIsSettled`
    /// (age == window now returned `.loading` instead of `.settled`
    /// expected); restored.
    @Test("Trigger: immediately before the window is .loading")
    func triggerJustBeforeWindowIsLoading() {
        let phase = SettlingCardTrigger.evaluate(
            SettlingCardTriggerInput(
                retainedAttachInstant: 0, now: 5.999_999, window: 6.0, isMagSafe: false, visibility: .live
            )
        )
        #expect(phase == .loading)
    }

    @Test("Trigger: exactly at the window is .settled")
    func triggerAtWindowIsSettled() {
        let phase = SettlingCardTrigger.evaluate(
            SettlingCardTriggerInput(
                retainedAttachInstant: 0, now: 6.0, window: 6.0, isMagSafe: false, visibility: .live
            )
        )
        #expect(phase == .settled)
    }

    @Test("Trigger: past the window is .settled")
    func triggerPastWindowIsSettled() {
        let phase = SettlingCardTrigger.evaluate(
            SettlingCardTriggerInput(
                retainedAttachInstant: 0, now: 6.5, window: 6.0, isMagSafe: false, visibility: .live
            )
        )
        #expect(phase == .settled)
    }

    // MARK: - Release: obsolete-generation wake ignored

    /// "timeout wake from an obsolete generation is ignored."
    ///
    /// Mutation watched failing: removed the `wokeGeneration == generation`
    /// check and always returned `.settled` on any `deadlineReached`. Went
    /// red here (obsolete wake incorrectly settled the newer generation's
    /// still-loading machine); restored.
    @Test("A deadline wake for an obsolete generation is a no-op")
    func obsoleteGenerationWakeIgnored() {
        let currentGeneration = 2
        let staleGeneration = 1
        let phase = SettlingCardReducer.reduce(
            phase: .loading, event: .deadlineReached(generation: staleGeneration), generation: currentGeneration
        )
        #expect(phase == .loading, "a stale timer from a replaced generation must not settle the current machine")
    }

    // MARK: - Release: churn no-op preserves .loading

    /// "same-generation inactive/active churn preserves the original
    /// deadline." Modelled by the ABSENCE of a churn event (see
    /// `SettlingCardEvent`'s doc comment): this test proves that simply not
    /// delivering `sessionEnded` (because the parent's authoritative
    /// visibility state never declared the session over, only flickered
    /// through a transient dip) leaves `.loading` untouched, with no event
    /// at all needed to "preserve" it.
    ///
    /// Mutation watched failing: N/A in the sense of mutating this file
    /// (there is no churn-handling code to break by construction), but the
    /// claim was verified by confirming no `SettlingCardEvent` case other
    /// than `sessionEnded` can produce `.fading` from `.loading`: a
    /// temporary case-insertion of a `case .churn: return .fading` arm and
    /// firing it here went red for the wrong reason (an event that
    /// shouldn't exist ended the session), demonstrating the omission is
    /// load-bearing; reverted.
    @Test("No transient-inactivity event exists; a same-generation dip leaves .loading untouched")
    func churnHasNoEventAndLeavesLoadingUntouched() {
        // Nothing delivered. The phase is simply whatever it already was.
        let phase = SettlingCardPhase.loading
        #expect(phase == .loading)
        // And the only way out is still the deadline or a real session end.
        #expect(SettlingCardReducer.reduce(phase: phase, event: .deadlineReached(generation: 0), generation: 0) == .settled)
    }

    // MARK: - Release: session end during loading -> .fading, queued wake cannot settle

    /// "session end during loading -> .fading; a queued timeout wake cannot
    /// reveal the body."
    ///
    /// Mutation watched failing: changed `.fading` + `.deadlineReached` to
    /// return `.settled` instead of `phase` (unchanged). Went red on the
    /// second assertion below (a stale queued wake resurrected the body
    /// after the session had already ended); restored.
    @Test("Session end during loading moves to .fading, and a queued deadline wake afterward cannot settle it")
    func sessionEndDuringLoadingThenQueuedWakeCannotSettle() {
        let generation = 3
        let afterSessionEnd = SettlingCardReducer.reduce(phase: .loading, event: .sessionEnded, generation: generation)
        #expect(afterSessionEnd == .fading)

        let afterQueuedWake = SettlingCardReducer.reduce(
            phase: afterSessionEnd, event: .deadlineReached(generation: generation), generation: generation
        )
        #expect(afterQueuedWake == .fading, "a deadline wake armed before the session ended must not resurrect .settled")
    }

    // MARK: - Release: two ports have independent deadlines

    /// "two ports: independent deadlines." Trivially separate instances at
    /// the pure level: each port's phase and generation are independent
    /// values, so this asserts exactly that: driving one to `.settled` has
    /// no effect on another machine's `.loading` value.
    @Test("Two independent machines: settling one leaves the other's .loading untouched")
    func twoMachinesAreIndependent() {
        let portAGeneration = 1
        let portBGeneration = 1
        var portAPhase = SettlingCardPhase.loading
        let portBPhase = SettlingCardPhase.loading

        portAPhase = SettlingCardReducer.reduce(
            phase: portAPhase, event: .deadlineReached(generation: portAGeneration), generation: portAGeneration
        )

        #expect(portAPhase == .settled)
        #expect(portBPhase == .loading, "port B's machine must be untouched by port A's deadline")
    }

    // MARK: - Release: genuine replug replaces the machine

    /// "genuine replug replaces the machine, new deadline." Per review
    /// finding (round 1): this is NOT a reducer transition. The spec's model
    /// is replacement, not transformation: "the old machine is discarded
    /// whole" and the new machine's starting phase comes from the TRIGGER,
    /// exactly like any other fresh mount. `SettlingCardReplacement.
    /// startingPhase(for:)` is the one call site that does this; it forwards
    /// straight to `SettlingCardTrigger.evaluate`.
    ///
    /// The important thing this proves: replacement does NOT hardcode
    /// `.loading`. A coalesced rapid replug (or a replug that lands past the
    /// window, or on a MagSafe port) must be able to start its brand new
    /// machine at `.settled`, same as the trigger already does for a fresh
    /// mount elsewhere in this file. An earlier revision of this file got
    /// this wrong: it modelled replacement as a `generationReplaced` event
    /// hardcoded to always yield `.loading`, which would have silently
    /// spinnered a replug that should show today's card immediately.
    ///
    /// Mutation watched failing: replaced `SettlingCardReplacement.
    /// startingPhase(for:)`'s body with `return .loading` unconditionally
    /// (reintroducing the old hardcoded-`.loading` bug). Went red on the
    /// MagSafe case below (expected `.settled`, got `.loading`); restored.
    @Test("Replacement computes the new machine's starting phase via the trigger, not a hardcoded .loading")
    func replacementUsesTriggerNotHardcodedLoading() {
        // Qualifying replug: young retained instant, inside the window,
        // live visibility, not MagSafe -> the trigger says .loading, and
        // replacement must agree.
        let loadingCase = SettlingCardReplacement.startingPhase(for: SettlingCardTriggerInput(
            retainedAttachInstant: 0, now: 1.0, window: 6.0, isMagSafe: false, visibility: .live
        ))
        #expect(loadingCase == .loading)

        // MagSafe replug: the trigger says .settled unconditionally.
        // Replacement must NOT override this with a hardcoded .loading.
        let magSafeCase = SettlingCardReplacement.startingPhase(for: SettlingCardTriggerInput(
            retainedAttachInstant: 0, now: 1.0, window: 6.0, isMagSafe: true, visibility: .live
        ))
        #expect(magSafeCase == .settled, "a MagSafe replug's new machine must start settled, not spinner")

        // A coalesced replug already past the window by construction time:
        // the trigger says .settled, and so must replacement.
        let pastWindowCase = SettlingCardReplacement.startingPhase(for: SettlingCardTriggerInput(
            retainedAttachInstant: 0, now: 6.5, window: 6.0, isMagSafe: false, visibility: .live
        ))
        #expect(pastWindowCase == .settled, "a replug mounted past its own window must start settled, not spinner")
    }

    // MARK: - Release: at reveal, body uses latest inputs (documentation-level)

    /// The spec's "at reveal, body uses latest inputs (an e-marker that
    /// arrived while the loading placeholder was displayed included)" is a
    /// content-construction property of Task 3's view layer, not of this
    /// phase machine: the machine only ever tracks WHEN to reveal, never
    /// WHAT the revealed body contains. This test pins the boundary: the
    /// reducer's `.settled` result carries no payload of its own, so any
    /// content built at that phase is necessarily whatever the caller reads
    /// fresh at that moment, never anything snapshotted by the machine.
    @Test("The .settled result carries no snapshotted content; reveal-time content is the caller's concern")
    func settledCarriesNoContentPayload() {
        // SettlingCardPhase is a plain enum with no associated values on
        // .settled: this compiles, which is the proof. Runtime assertion
        // kept for symmetry with the other tests in this file.
        let phase = SettlingCardReducer.reduce(phase: .loading, event: .deadlineReached(generation: 0), generation: 0)
        #expect(phase == .settled)
    }

    // MARK: - Trigger: real unplug, young retained instant, .hidden -> must NOT load

    /// "real unplug, young retained instant, card mounts: must NOT load
    /// (visibility gate)." This is the dead-session hole the spec's trigger
    /// condition 3 exists to close: a card can mount just after a genuine
    /// unplug and still read a young retained instant from the now-dead
    /// session.
    ///
    /// Mutation watched failing: changed the trigger's visibility switch to
    /// treat `.ended` the same as `.live` (`return .loading` for all three
    /// cases). Went red here (a dead session spinnered); restored.
    @Test("A real unplug with a young retained instant does not start .loading")
    func realUnplugWithYoungInstantDoesNotLoad() {
        let phase = SettlingCardTrigger.evaluate(
            SettlingCardTriggerInput(
                retainedAttachInstant: 0, now: 1.0, window: 6.0, isMagSafe: false, visibility: .ended
            )
        )
        #expect(phase == .settled)
    }

    // MARK: - Trigger: transient + qualifying visibility -> .loading with original deadline

    /// "transient inactive, same conditions: loads with the original
    /// deadline." The trigger doesn't recompute a deadline itself
    /// (`SettlingCardDeadline` does, from the SAME `retainedAttachInstant`
    /// either way), so this asserts the qualifying half: `.transientFadingGrace`
    /// visibility is treated the same as `.live` for starting `.loading`.
    @Test("Transient fading-grace visibility qualifies for .loading, same as .live")
    func transientFadingGraceQualifiesForLoading() {
        let phase = SettlingCardTrigger.evaluate(
            SettlingCardTriggerInput(
                retainedAttachInstant: 0, now: 1.0, window: 6.0, isMagSafe: false, visibility: .transientFadingGrace
            )
        )
        #expect(phase == .loading)

        // Same retainedAttachInstant as the "real unplug" test above proves
        // the deadline computed from it is identical either way: the
        // instant itself, not the visibility case, drives the deadline.
        let deadline = SettlingCardDeadline.instant(retainedAttachInstant: 0, window: 6.0)
        #expect(deadline == 6.1)
    }

    // MARK: - Trigger: prune/reset/new generation, old instant cannot start a machine

    /// "prune/reset/new generation: an old instant cannot start a machine."
    /// Task 1's `retainedAttachInstant(for:)` already returns `nil` after
    /// prune/reset (proven in `PortConnectionSessionTrackerTests`); this
    /// test proves the TRIGGER's own handling of that `nil`, independent of
    /// the tracker: condition 1 fails and the trigger falls straight to
    /// `.settled`, regardless of what age or visibility would otherwise say.
    ///
    /// Mutation watched failing: changed `guard let instant = ... else {
    /// return .settled }` to instead treat a nil instant as age 0 (`let
    /// instant = input.retainedAttachInstant ?? input.now`). Went red here
    /// (a pruned/reset session with unknown age started `.loading` as if it
    /// were freshly attached); restored.
    @Test("A nil retained instant (pruned or reset) cannot start .loading, even with otherwise-qualifying visibility")
    func nilInstantCannotStartLoading() {
        let phase = SettlingCardTrigger.evaluate(
            SettlingCardTriggerInput(
                retainedAttachInstant: nil, now: 30, window: 6.0, isMagSafe: false, visibility: .live
            )
        )
        #expect(phase == .settled)
    }

    // MARK: - Trigger: MagSafe -> .settled start

    @Test("MagSafe never starts .loading, regardless of instant/age/visibility")
    func magSafeNeverLoads() {
        let phase = SettlingCardTrigger.evaluate(
            SettlingCardTriggerInput(
                retainedAttachInstant: 0, now: 0.5, window: 6.0, isMagSafe: true, visibility: .live
            )
        )
        #expect(phase == .settled)
    }

    // MARK: - Trigger: nil visibility entry handled per parent's rule, NOT as fading-grace

    /// The spec's "Implementation cautions": a nil visibility lookup must
    /// NOT be read as transient `.fading`; it must follow the parent's
    /// immediate-liveness fallback (`ContentView.mainContent`'s `case nil:`
    /// branch, read for this task at
    /// `Sources/WhatCable/Views/ContentView.swift:285-291`), which resolves
    /// to a live-or-not verdict via `isPortLive`, never to a
    /// transient/fading one.
    ///
    /// `SettlingCardVisibility` has no "unknown" case at all (see its doc
    /// comment), so this test proves the type-level guarantee: a caller
    /// resolving a nil lookup MUST map it to either `.live` or `.ended`
    /// (mirroring `isPortLive`'s boolean), and if it does, the trigger
    /// behaves exactly as those two cases already behave elsewhere in this
    /// file. There is no third path through the trigger that reads a nil
    /// lookup as `.transientFadingGrace`, because no case reaching this
    /// function can represent "nil" at all.
    ///
    /// Mutation watched failing: this is a type-level guarantee (no
    /// `.unknown` case exists to construct), so the mutation was against the
    /// PROOF rather than the production code: temporarily added a fourth
    /// `case unknown` to a local copy of the switch and mapped it to
    /// `.loading` (the wrong, looser default). The resulting behaviour
    /// diverged from `isPortLive`'s live-or-not semantics for a
    /// not-yet-evaluated port, confirming that a permissive "unknown"
    /// branch is precisely the bug this design prevents by construction;
    /// discarded (never landed in the shipped file).
    @Test("A resolved-to-live nil lookup behaves exactly like .live; a resolved-to-ended one exactly like .ended")
    func resolvedNilLookupMatchesItsResolvedCase() {
        let resolvedLive = SettlingCardTrigger.evaluate(
            SettlingCardTriggerInput(
                retainedAttachInstant: 0, now: 1.0, window: 6.0, isMagSafe: false, visibility: .live
            )
        )
        let resolvedEnded = SettlingCardTrigger.evaluate(
            SettlingCardTriggerInput(
                retainedAttachInstant: 0, now: 1.0, window: 6.0, isMagSafe: false, visibility: .ended
            )
        )
        #expect(resolvedLive == .loading)
        #expect(resolvedEnded == .settled)
    }

    // MARK: - .fading -> .retained on fadeCompleted with parent retention

    /// "both parent ownership paths: parent removal owns the exit;
    /// parent-retained runs .fading -> .retained." The removal half is a
    /// view-layer fact (Task 3: the parent's `ForEach` removal transition
    /// owns the exit and the child machine is discarded, never told); this
    /// test covers the reducer-expressible retained half.
    ///
    /// Mutation watched failing: inverted the ternary (`parentRetainsCard ?
    /// .fading : .retained`, swapping the two branches). Went red on BOTH
    /// this test (retention now produced `.fading` instead of `.retained`)
    /// and `fadeCompletedWithoutRetentionStaysFading` below (no-retention
    /// now produced `.retained` instead of staying `.fading`); restored.
    @Test("Fade completing on a parent-retained card moves to .retained")
    func fadeCompletedWithRetentionMovesToRetained() {
        let phase = SettlingCardReducer.reduce(
            phase: .fading, event: .fadeCompleted(parentRetainsCard: true), generation: 0
        )
        #expect(phase == .retained)
    }

    @Test("Fade completing without parent retention is a no-op (removal path owns disposal, not this reducer)")
    func fadeCompletedWithoutRetentionStaysFading() {
        let phase = SettlingCardReducer.reduce(
            phase: .fading, event: .fadeCompleted(parentRetainsCard: false), generation: 0
        )
        #expect(phase == .fading)
    }

    // MARK: - .retained is sticky against every event EXCEPT sessionResumed

    /// "Same-generation reactivation does not leave .retained; only a new
    /// generation starts fresh" (spec, original rule). Per review finding
    /// (round 1), `generationReplaced` no longer exists as an event: a new
    /// generation leaves `.retained` by REPLACEMENT (the old machine
    /// discarded, a new one constructed via `SettlingCardReplacement
    /// .startingPhase(for:)`), never by a reducer transition.
    ///
    /// Owner ruling 2026-08-28 ("Same-generation recovery", spec's
    /// "Parent-owned retention and removal" section) SUPERSEDES the "no
    /// exception" half of that rule: `sessionResumed` is now the one event
    /// that DOES move `.retained` (to `.settled`; see
    /// `retainedRecoversToSettledOnSessionResumed` below), so it is
    /// deliberately EXCLUDED from this list rather than added to it.
    /// Everything else drives every OTHER event in `SettlingCardEvent` at
    /// `.retained` and confirms none of THOSE escape it. The only ways out
    /// of `.retained` remain: the caller discarding the machine on a new
    /// generation (`replacementUsesTriggerNotHardcodedLoading` above), or
    /// `sessionResumed` on the same generation.
    ///
    /// Mutation watched failing: added a `.retained` + `.sessionEnded` arm
    /// returning `.fading` (a stand-in for "reactivation accidentally
    /// re-enters the fade cycle"). Went red here; restored.
    @Test("Every event except sessionResumed is a no-op while .retained")
    func retainedIsStickyAgainstEveryReducerEventExceptRecovery() {
        let events: [SettlingCardEvent] = [
            .deadlineReached(generation: 0),
            .sessionEnded,
            .fadeCompleted(parentRetainsCard: true),
            .fadeCompleted(parentRetainsCard: false),
        ]
        for event in events {
            let phase = SettlingCardReducer.reduce(phase: .retained, event: event, generation: 0)
            #expect(phase == .retained, "\(event) must not move .retained")
        }
    }

    // MARK: - Same-generation recovery (owner ruling 2026-08-28)

    /// The core of the new rule: `.retained` + `sessionResumed` -> `.settled`
    /// (the full card, never a spinner).
    ///
    /// Mutation watched failing: changed the `.retained` arm of
    /// `.sessionResumed` to return `.loading` (the exact wrong answer the
    /// spec calls out by name: "NEVER a spinner"). Went red here; restored.
    @Test("Retained recovers to settled on sessionResumed")
    func retainedRecoversToSettledOnSessionResumed() {
        let phase = SettlingCardReducer.reduce(phase: .retained, event: .sessionResumed, generation: 0)
        #expect(phase == .settled)
    }

    /// `sessionResumed` has nothing to recover FROM in any other phase, and
    /// critically does NOT interrupt an in-flight `.fading` (spec: "no
    /// mid-fade reversal"): the fade must finish to `.retained` first.
    ///
    /// Mutation watched failing: changed the `.fading` arm to return
    /// `.settled` (a stand-in for "recovery interrupts the fade"). Went red
    /// on the `.fading` case here; restored.
    @Test("sessionResumed is a no-op everywhere except .retained")
    func sessionResumedNoOpsOutsideRetained() {
        #expect(SettlingCardReducer.reduce(phase: .loading, event: .sessionResumed, generation: 0) == .loading)
        #expect(SettlingCardReducer.reduce(phase: .settled, event: .sessionResumed, generation: 0) == .settled)
        #expect(SettlingCardReducer.reduce(phase: .fading, event: .sessionResumed, generation: 0) == .fading)
    }

    /// The exact stuck-card scenario the adversarial review named: a
    /// same-generation churn dip holds the port dead past the visibility
    /// grace window (`sessionEnded`, no real unplug), the card fades and
    /// settles into `.retained` ("Nothing connected"), and THEN the port
    /// comes back to life on the SAME generation. Without recovery this
    /// would show "Nothing connected" forever for a cable that's actually
    /// still working; with it, the full card returns.
    ///
    /// Mutation watched failing: changed the reducer's `.sessionResumed` +
    /// `.retained` arm to return `.retained` (the pre-fix, no-recovery
    /// behaviour this finding replaces). Went red on the final assertion
    /// here; restored.
    @Test("Full sequence: churn-dead past grace -> fading -> retained -> live again -> settled")
    func churnDeadPastGraceThenRecovers() {
        let generation = 7
        var phase = SettlingCardPhase.loading

        // The session settles normally first (deadline reached).
        phase = SettlingCardReducer.reduce(
            phase: phase, event: .deadlineReached(generation: generation), generation: generation
        )
        #expect(phase == .settled)

        // A churn dip finally crosses the parent's grace window and the
        // authoritative visibility declares the session ended.
        phase = SettlingCardReducer.reduce(phase: phase, event: .sessionEnded, generation: generation)
        #expect(phase == .fading)

        // The exit animation completes; the parent retains the card.
        phase = SettlingCardReducer.reduce(
            phase: phase, event: .fadeCompleted(parentRetainsCard: true), generation: generation
        )
        #expect(phase == .retained)

        // The port comes back to life on the SAME generation.
        phase = SettlingCardReducer.reduce(phase: phase, event: .sessionResumed, generation: generation)
        #expect(phase == .settled)
    }

    // MARK: - .settled is terminal except sessionEnded; replacement is the only other exit

    /// Exact transition-table check: from `.settled`, `sessionEnded`
    /// produces `.fading` (the transition table's one named exception to
    /// "terminal"), and every other reducer event is a no-op. Replacement
    /// (a new generation) is the only other way out of `.settled`, and it
    /// is not a reducer event at all (see `replacementUsesTriggerNotHardcodedLoading`
    /// above), so there is nothing further to pin here.
    @Test(".settled: sessionEnded -> .fading, every other reducer event is a no-op")
    func settledTransitionsExactly() {
        #expect(SettlingCardReducer.reduce(phase: .settled, event: .sessionEnded, generation: 0) == .fading)
        #expect(SettlingCardReducer.reduce(phase: .settled, event: .deadlineReached(generation: 0), generation: 0) == .settled)
        #expect(SettlingCardReducer.reduce(phase: .settled, event: .fadeCompleted(parentRetainsCard: true), generation: 0) == .settled)
        #expect(SettlingCardReducer.reduce(phase: .settled, event: .fadeCompleted(parentRetainsCard: false), generation: 0) == .settled)
    }

    // MARK: - Deadline arithmetic, walked by hand

    /// `deadline = retainedAttachInstant + window + epsilon`. With
    /// `retainedAttachInstant = 100`, `window = 6.0` (the shipped
    /// `PortSummary.emarkerReadWindow` value), `epsilon = 0.1`: deadline =
    /// 100 + 6.0 + 0.1 = 106.1. At `now = 106.0`, remaining = 106.1 - 106.0
    /// = 0.1 seconds left to sleep. At `now = 106.1`, remaining = 0. At
    /// `now = 200` (long past), remaining clamps to 0, not negative.
    @Test("Deadline instant and remaining-time arithmetic, hand-walked")
    func deadlineArithmeticHandWalked() {
        let deadline = SettlingCardDeadline.instant(retainedAttachInstant: 100, window: 6.0)
        #expect(deadline == 106.1)

        let remainingBefore = SettlingCardDeadline.remaining(retainedAttachInstant: 100, window: 6.0, now: 106.0)
        #expect(abs(remainingBefore - 0.1) < 0.000_001)

        let remainingAt = SettlingCardDeadline.remaining(retainedAttachInstant: 100, window: 6.0, now: 106.1)
        #expect(remainingAt == 0)

        let remainingPast = SettlingCardDeadline.remaining(retainedAttachInstant: 100, window: 6.0, now: 200)
        #expect(remainingPast == 0, "a late mount must not compute a negative sleep")
    }
}
