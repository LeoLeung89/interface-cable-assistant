import Foundation
import WhatCableCore

// MARK: - Content plan

/// What a settling card's body should construct, derived from its
/// `SettlingCardPhase` plus whether this session's machine has ever reached
/// `.settled` (`hasRevealed`). Pure: no SwiftUI, no IOKit.
/// `SettlingPortCardHost` (Task 3's SwiftUI host, not this file) switches on
/// this to decide whether to construct `PortCard` at all, so `.placeholder`
/// and `.retained` NEVER build `PortCard.summary`, diagnostics, device
/// trees, power details, plugin builders, or e-marker content (spec:
/// "Placeholder invariance" and "Parent-owned retention and removal").
///
/// `hasRevealed` exists because `.fading` alone doesn't say whether the card
/// was showing the placeholder or the live body when the session ended
/// (spec: both `.loading -> .fading` and `.settled -> .fading` are real
/// transitions). `.fading` keeps showing whatever was already up while its
/// own exit motion plays; only `.retained` swaps to the disconnected
/// content.
public enum SettlingCardContentPlan: Equatable, Sendable {
    /// The stable placeholder: snapshotted port label, spinner, "Reading
    /// cable details...". No live-input content constructed.
    case placeholder
    /// The full live `PortCard` body, built from the latest inputs.
    case liveBody
    /// The disconnected-card content (parent-retained path). No live-input
    /// content constructed.
    case retained

    /// - Parameters:
    ///   - phase: the card's current `SettlingCardPhase`.
    ///   - hasRevealed: whether this session's machine has ever reached
    ///     `.settled`.
    public static func plan(phase: SettlingCardPhase, hasRevealed: Bool) -> SettlingCardContentPlan {
        switch phase {
        case .loading:
            return .placeholder
        case .settled:
            return .liveBody
        case .fading:
            return hasRevealed ? .liveBody : .placeholder
        case .retained:
            return .retained
        }
    }
}

// MARK: - Visibility resolution

/// Resolves the parent's `portVisibilityStates[serviceName]` lookup (which
/// is `nil` on the first frame, before the periodic tick has run) into the
/// `SettlingCardVisibility` the trigger and the session-end check need.
///
/// Mirrors `ContentView.mainContent`'s existing nil-fallback EXACTLY (spec,
/// "Implementation cautions": "A temporarily missing visibility entry ...
/// must NOT be read as transient .fading; follow the parent's existing
/// immediate-liveness handling"):
///
///     switch portVisibilityStates[port.serviceName] {
///     case .hidden: return false
///     case .live, .fading: return true
///     case nil: return isPortLive(port, ...)
///     }
///
/// Pure, so it's testable without SwiftUI (`SettlingCardVisibility` has no
/// "unknown" case at all — see its doc comment in `SettlingCardPhase.swift`
/// — which is what forces this resolution to happen here, before the
/// trigger ever sees the value).
public enum SettlingCardVisibilityResolver {
    public static func resolve(
        _ state: PortVisibilityState?,
        isPortLiveNow: @autoclosure () -> Bool
    ) -> SettlingCardVisibility {
        switch state {
        case .hidden:
            return .ended
        case .live:
            return .live
        case .fading:
            return .transientFadingGrace
        case nil:
            // Not yet evaluated by the periodic tick (e.g. the very first
            // frame). Falls back to the immediate liveness signal, which is
            // a live-or-not verdict, never a "transient/fading" one.
            return isPortLiveNow() ? .live : .ended
        }
    }

    /// Resolves visibility for a settling card's `SettlingPortCardHost` row.
    /// Identical to `resolve` except for one addition: a stale `.hidden`
    /// entry is overridden by a live-now signal (issue #585, symptom 2).
    ///
    /// Correction (adversarial review): this does NOT run only at mount.
    /// `settlingVisibility` is a plain `let` at the `ContentView` call site,
    /// recomputed on EVERY body evaluation of that row, not just the one
    /// that constructs a fresh `SettlingCardIdentity`. The name describes
    /// the bug this closes, not the calling frequency.
    ///
    /// `portVisibilityStates` is a separate `@State` dictionary updated only
    /// in `ContentView`'s `.onChange` handlers, which run AFTER the body
    /// evaluation that reads `portWatcher.ports` and derives the new
    /// `SettlingCardIdentity` generation. Plugging into an already-visible
    /// EMPTY port bumps the generation on that same evaluation, but
    /// `portVisibilityStates[port.serviceName]` still holds the OLD
    /// `.hidden` entry from when the port had nothing in it; the dictionary
    /// hasn't caught up yet. Feeding that stale `.hidden` straight into
    /// `resolve` folds it to `.ended`, so the fresh machine's trigger sees
    /// visibility already ended, its "port is live" condition fails, and it
    /// starts `.settled` instead of `.loading`: the spinner-then-reveal
    /// choreography (PR #579) never runs, and the old incremental fill-in
    /// shows instead. That is the frame this override exists to fix; on
    /// every OTHER render it is harmless, not merely unneeded, because
    /// `portVisibilityStates` catching up (or the port genuinely going live)
    /// makes the override a no-op path to the same answer `resolve` would
    /// already give, and any extra `sessionResumed` this causes downstream
    /// (`SettlingPortCardHost`'s `onChange(of: settlingVisibility)`) is
    /// itself a no-op everywhere except `phase == .retained`
    /// (`SettlingCardReducer`'s totality: `.sessionResumed` only moves
    /// `.retained`).
    ///
    /// Only `.hidden` is special-cased. `.live` and `.fading` carry real
    /// policy (the #536 charger-grace window) that a same-frame live signal
    /// must never second-guess; a `.hidden` entry with the live signal ALSO
    /// false stays `.ended`, exactly as `resolve` already does (the
    /// dead-session race the plain `nil` branch closes).
    public static func resolveAtMount(
        _ state: PortVisibilityState?,
        isPortLiveNow: Bool
    ) -> SettlingCardVisibility {
        if case .hidden = state, isPortLiveNow {
            return resolve(nil, isPortLiveNow: isPortLiveNow)
        }
        return resolve(state, isPortLiveNow: isPortLiveNow)
    }
}

// MARK: - Opacity

/// The card's effective opacity, folding together what used to be TWO
/// independent SwiftUI transactions: the parent's `.fading`-vs-not dimming
/// (formerly a plain `.opacity(...)` modifier at the `ForEach` call site,
/// driven by `portVisibilityStates`) and the child's own internal exit fade
/// (driven by `SettlingCardPhase`). Per-task-review finding (round 1): those
/// two, animated by separate transactions matched only by a shared
/// duration, could skew relative to each other on any start-frame lag, and
/// during that skew the outgoing live content could read BRIGHTER than the
/// `.fading` dimmed value the instant the parent's raw visibility state
/// jumped from `.fading` to `.hidden` (its old mapping treated anything
/// that wasn't `.fading` as full opacity, `.hidden` included) while the
/// child's own fade was still only partway through. Spec's Implementation
/// caution 2: "the old live card is never momentarily revealed at full
/// opacity".
///
/// This is now the ONE function computing the ONE opacity value
/// `SettlingPortCardHost` applies to itself, so there is nothing left to
/// skew: both the visibility signal and the phase are read at the same
/// point, in the same render, and any animation over the result comes from
/// a single transaction (see `SettlingPortCardHost.body`).
///
/// Deliberately capped at `dimmed` (never `full`) for EITHER of two
/// independent reasons, so a caller can't reach `full` by racing them:
/// `phase == .fading` capping it directly, or `visibility != .live` capping
/// it regardless of what `phase` currently reads (this second cap is what
/// closes the theoretical same-frame gap between `settlingVisibility`
/// changing and this view's own `.onChange`-driven `sessionEnded` event
/// having run yet: the value is already safe before that event fires, not
/// only after).
public enum SettlingCardOpacity {
    /// The parent's original dimmed value for a charger-only port whose
    /// power attribution just flapped away (#536), preserved unchanged.
    public static let dimmed: Double = 0.5
    public static let full: Double = 1.0
    /// Fully hidden: the card's own exit fade (`.fading`), so old content
    /// never lingers, even dimmed, while `.retained` content swaps in
    /// underneath it.
    public static let hidden: Double = 0.0

    public static func effectiveOpacity(
        visibility: SettlingCardVisibility,
        phase: SettlingCardPhase
    ) -> Double {
        switch phase {
        case .fading:
            return hidden
        case .retained, .loading, .settled:
            // `.retained` shares the `.loading`/`.settled` rule (owner
            // ruling, issue #585): task 1 made `.retained` render the SAME
            // content as a launch-time disconnected card (phase `.settled`,
            // visibility `.ended`), so it must also render at the SAME
            // opacity, `dimmed`, not `full`. The old `.retained`-only
            // mapping (`visibility == .transientFadingGrace ? dimmed :
            // full`) predated that fix, back when `.retained` showed its
            // own separate placeholder rather than the real card; folding
            // it into this shared arm removes the special case rather than
            // duplicating the rule.
            // Capped at `dimmed` the instant the AUTHORITATIVE visibility
            // says anything other than confirmed-live, even before this
            // machine's own `phase` has caught up via its `onChange`-driven
            // `sessionEnded` event. This is what makes the function
            // race-free rather than merely "usually fast enough": the cap
            // does not depend on which of (`visibility` changing, `phase`
            // reacting to it) SwiftUI happens to commit first.
            return visibility == .live ? full : dimmed
        }
    }
}

// MARK: - Deadline task arming

/// Whether the generation-scoped deadline `.task` should be sleeping right
/// now: `.loading` AND the authoritative visibility hasn't already declared
/// the session over. Per-branch-review finding (round 2, Codex gate,
/// finding 1): the deadline task used to be a bare `.task { }`, keyed to
/// nothing but the view's own identity, so it never got cancelled by a
/// same-generation `sessionEnded` — only by a full generation replacement.
/// A queued wake could then land in the narrow window between the deadline
/// firing and this view's own `onChange`-driven `sessionEnded` handling,
/// briefly settling (and constructing `PortCard`) before immediately fading.
///
/// `SettlingPortCardHost` now keys its `.task(id:)` on this predicate (via
/// `visibilityEnded`, part of the id), so a transition INTO "ended" cancels
/// the currently-sleeping task as part of the SAME view update that also
/// fires `onChange(of: settlingVisibility)`, instead of leaving the old
/// task to run to completion unbothered. Extracted here, pure, so the
/// predicate itself has a test independent of `.task(id:)`'s SwiftUI
/// lifecycle (which this file can't harness).
public enum SettlingCardDeadlineArming {
    public static func isArmed(phase: SettlingCardPhase, visibility: SettlingCardVisibility) -> Bool {
        phase == .loading && visibility != .ended
    }
}

// MARK: - Fade watchdog

/// Whether the fade-completion watchdog should still fire: purely
/// `phase == .fading`. Per-branch-review addendum (round 2, adversarial
/// gate, finding 4): `.fading -> .retained` normally happens via
/// `withAnimation`'s completion handler (see `SettlingPortCardHost.send`),
/// which depends on Core Animation actually delivering that completion for
/// a view that can be off-screen (the popover's `NSHostingController` is
/// created once and never torn down on close/reopen). If that completion
/// is ever dropped, the machine would stick at `.fading` forever, and
/// `SettlingCardOpacity.effectiveOpacity` holds a `.fading` card fully
/// invisible with no other event able to move it (the reducer only leaves
/// `.fading` on `fadeCompleted`).
///
/// `SettlingPortCardHost` arms a second `.task(id: phase)` that fires
/// `fadeCompleted(parentRetainsCard: true)` after a bounded fallback
/// interval (`CardMotion.fadeWatchdogInterval`) if this predicate is still
/// true when it wakes, i.e. the normal completion path never ran. First
/// delivery wins by construction: if the normal path already fired,
/// `phase` is already `.retained` and this predicate is false, both before
/// the watchdog sleeps (skipping it entirely, since the `.task(id: phase)`
/// identity itself changed and cancelled the sleeping watchdog) and, as
/// defence in depth, in the post-sleep guard. A duplicate `fadeCompleted`
/// delivery is separately a no-op at the reducer level regardless (pinned
/// by `SettlingCardPhaseTests.retainedIsStickyAgainstEveryReducerEvent`,
/// Task 2), so this predicate is belt, and the reducer's totality is
/// braces.
public enum SettlingCardFadeWatchdog {
    public static func shouldFire(phase: SettlingCardPhase) -> Bool {
        phase == .fading
    }
}

// MARK: - Visible-port membership (ForEach animation gating)

/// Whether a port would appear in `ContentView.mainContent`'s
/// `visiblePorts` under "Hide empty ports", mirroring that filter's
/// non-`nil` branches exactly (`.hidden` -> false, `.live`/`.fading` ->
/// true; `hideEmptyPorts == false` -> always true, every port renders
/// regardless of state).
///
/// Per-branch-review finding (round 2, Codex gate, finding 3): the
/// membership-change gate `recomputePortVisibility` uses to decide whether
/// to animate its `portVisibilityStates` write used to compare raw
/// `.hidden`-ness directly, ignoring `hideEmptyPorts` entirely. With the
/// setting OFF, `visiblePorts` never changes membership no matter what any
/// port's visibility state does (`mainContent` falls straight through to
/// `portWatcher.ports`, unfiltered), so a `.live` <-> `.hidden` flip in
/// that mode can never actually add or remove a `ForEach` row, yet the old
/// gate still animated the write as if it might have. Comparing the
/// ACTUAL, setting-aware visible membership (this function) instead of raw
/// hidden-ness closes that gap by construction: with `hideEmptyPorts` off,
/// this always returns `true`, so old and new never differ, and the gate
/// correctly never fires.
///
/// `nil` is treated as visible regardless of `hideEmptyPorts`. This
/// function is used ONLY to detect whether a `ForEach` membership CHANGE
/// happened (to decide whether to animate the state write), never to
/// decide what actually renders (`mainContent`'s own filter, with its
/// richer structural-tunnel-aware nil fallback, is unchanged and remains
/// the single source of truth for that); a `nil` entry only occurs for a
/// port that has no visibility verdict yet (e.g. it just appeared this
/// tick), which is a membership change either way it's read.
public enum SettlingCardVisibleMembership {
    public static func isVisible(state: PortVisibilityState?, hideEmptyPorts: Bool) -> Bool {
        guard hideEmptyPorts else { return true }
        switch state {
        case .hidden:
            return false
        case .live, .fading, nil:
            return true
        }
    }

    /// The actual VISIBLE-PORT ID SET a `portVisibilityStates`-shaped
    /// dictionary produces under `hideEmptyPorts`. Generic over the key type
    /// so it works for `ContentView`'s `[String: PortVisibilityState]`
    /// (keyed by `port.serviceName`) without depending on that type here.
    public static func visibleIDs<Key: Hashable>(
        from states: [Key: PortVisibilityState], hideEmptyPorts: Bool
    ) -> Set<Key> {
        Set(states.compactMap { key, state in
            isVisible(state: state, hideEmptyPorts: hideEmptyPorts) ? key : nil
        })
    }

    /// Whether visible-port membership changed between an OLD and NEW
    /// snapshot: a set-equality comparison of `visibleIDs`, not a per-key
    /// walk scoped to the CURRENT ports only.
    ///
    /// Per-branch-review finding (round 3, Codex gate, "issue 2"): a per-key
    /// walk over only the ports present NOW treats a missing OLD entry as
    /// "visible" (via `isVisible`'s `nil` -> `true` fallback, which is
    /// correct for THAT function's own purpose: deciding whether a single
    /// state renders visible, not whether a port is NEW), so a port's FIRST
    /// appearance was silently absorbed into "already visible before, still
    /// visible now" and never registered as a membership change; a port
    /// that vanishes from the registry entirely was invisible to that walk
    /// for the same structural reason (it's not in `ports` to iterate over
    /// at all). Comparing `visibleIDs(from: old, ...)` against `visibleIDs
    /// (from: new, ...)` fixes both by construction: `visibleIDs` only ever
    /// contains keys the RESPECTIVE dictionary actually has, so a key
    /// present in one set and absent from the other (appearance or
    /// disappearance) is automatically a set difference, with no special
    /// casing needed.
    public static func membershipChanged<Key: Hashable>(
        old: [Key: PortVisibilityState], new: [Key: PortVisibilityState], hideEmptyPorts: Bool
    ) -> Bool {
        visibleIDs(from: old, hideEmptyPorts: hideEmptyPorts)
            != visibleIDs(from: new, hideEmptyPorts: hideEmptyPorts)
    }
}

// MARK: - Phase-entry recovery (round 4, supersedes the round-3 fade-completion-chained design)

/// The pure predicate behind `SettlingPortCardHost`'s `.onChange(of: phase)`
/// observer, which is now the ONLY recovery path (round 4; see
/// `SettlingCardReplacement`'s sibling history for why rounds 2 and 3 were
/// each rejected).
///
/// Round 2 (edge-triggered `sessionResumed` from `onChange(of:
/// settlingVisibility)` alone) missed the case where visibility returns to
/// `.live` WHILE still `.fading`: the reducer correctly refuses to reverse
/// an in-flight fade ("no mid-fade reversal"), so that edge is a no-op, and
/// if visibility never changes again there is no LATER edge to catch once
/// the fade finishes into `.retained`. Round 3 tried to close that by
/// chaining a recovery check onto `sendFadeCompleted()`'s `withAnimation`
/// completion closure, reading a `latestVisibility` `@State` mirror. That
/// was rejected too: the check ran inside an ANIMATION COMPLETION, and a
/// dropped completion on an off-screen `NSHostingController` (the exact
/// failure mode the fade watchdog already exists to tolerate) meant the
/// watchdog's own `fadeCompleted` send could chain the SAME recovery check
/// onto ANOTHER completion that could also drop, reproducing the stuck-card
/// bug one layer down; separately, the `latestVisibility` mirror could read
/// stale against a committed `.ended`.
///
/// This predicate is checked instead from `.onChange(of: phase)`, which
/// SwiftUI delivers from the RENDER LOOP the instant the observed value
/// actually changes, not from any animation completion. That is not
/// something this file can unit-test (it depends on SwiftUI's own delivery
/// timing), so the reasoning lives here and at the call site: an
/// `.onChange(of:)` handler is re-registered fresh on every `body`
/// evaluation, so the closure it fires always closes over the CURRENT
/// committed `settlingVisibility` prop at the moment of delivery, with no
/// equivalent to a completion closure's "captured at schedule time, stale
/// by the time it runs" problem, and no equivalent to Core Animation's
/// "completion never called" problem either: a value change either commits
/// (and fires the observer) or it doesn't happen at all.
public enum SettlingCardPhaseEntryRecovery {
    /// Whether phase-entry into `.retained` should immediately fire
    /// `.sessionResumed`, recovering the machine to `.settled`. True only
    /// for `(phase: .retained, visibility: .live)`; every other phase this
    /// observer could see is a no-op (an entry into `.settled` or
    /// `.loading` is never reachable from `.retained` by construction, but
    /// the predicate stays total over `SettlingCardPhase` rather than
    /// narrowing its signature, so a future phase added to the enum degrades
    /// to "no recovery" instead of failing to compile against this file).
    public static func shouldRecover(onEntryTo phase: SettlingCardPhase, visibility: SettlingCardVisibility) -> Bool {
        phase == .retained && visibility == .live
    }
}
