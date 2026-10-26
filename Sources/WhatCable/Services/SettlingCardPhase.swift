import Foundation

// MARK: - Phase

/// The presentation phase of one settling port card, scoped to a single
/// `(portID, sessionGeneration)`. Spec: "settling-card", "Presentation state
/// machine".
///
/// Pure. No SwiftUI, no IOKit. `Sources/WhatCable/Views/ContentView.swift`
/// (Task 3, not this file) owns wiring a card's mount/unmount lifecycle,
/// the generation-scoped deadline timer, and the parent-owned removal vs.
/// retention rendering contract to this machine.
public enum SettlingCardPhase: Equatable, Sendable {
    /// The stable placeholder: snapshotted port label, spinner, "Reading
    /// cable details...". Nothing else is constructed while in this phase
    /// (see the spec's "Placeholder invariance" section; enforced by the
    /// view layer in Task 3, not by this type).
    case loading
    /// The full card body, built once from the latest inputs at reveal.
    /// Terminal per session: no event un-reveals it back to `.loading`.
    case settled
    /// The card's own exit animation is running. Reached either from
    /// `.loading` (session ended before the deadline) or from `.settled`
    /// (session ended after reveal).
    case fading
    /// A parent-retained card (kept mounted after unplug, reduced opacity)
    /// once its fade has completed. Renders the disconnected-card content
    /// with live-input rendering suppressed (spec: "Parent-owned retention
    /// and removal"). Left by either a new generation (the whole machine
    /// discarded, see `SettlingCardReplacement`), or by `sessionResumed`
    /// (spec: "Same-generation recovery", owner ruling 2026-08-28,
    /// superseding the earlier "only a new generation leaves this phase"
    /// rule): if the port's authoritative visibility returns to `.live` on
    /// the SAME generation, the machine moves straight to `.settled`, never
    /// back to `.loading`.
    case retained
}

// MARK: - Events

/// Everything that can drive a `SettlingCardPhase` transition. Deliberately
/// does NOT include a "transient inactivity" / churn event: the spec's
/// churn policy ("transient same-generation inactivity does not end the
/// session; `.loading` persists with its original deadline") is modelled by
/// omission, not by an explicit no-op case. A churn dip (issue #536) simply
/// never produces a `sessionEnded` event; only the parent's authoritative
/// visibility/liveness verdict does, once it actually declares the session
/// over. Adding a `transientInactivity` case that reducers to a no-op would
/// invite a caller to fire it speculatively "just in case", which is exactly
/// the ambiguity the spec's release rule (timeout-only, no early release)
/// is designed to avoid.
public enum SettlingCardEvent: Equatable, Sendable {
    /// The generation-scoped deadline timer woke up. Carries the generation
    /// it was armed for (spec: "checks BOTH phase and generation before
    /// settling"); the reducer compares it against the machine's own
    /// generation and ignores a wake for an obsolete one.
    case deadlineReached(generation: Int)
    /// The authoritative visibility/liveness state the parent computes has
    /// declared this session ended (not raw `connectionActive`, and not a
    /// transient churn dip). This is the ONLY thing that can move `.loading`
    /// or `.settled` into `.fading`.
    case sessionEnded
    /// The card's exit animation finished. `parentRetainsCard` is the
    /// parent's rendering-contract decision (spec: "Parent-owned retention
    /// and removal"): `true` on the reduced-opacity retained path (the
    /// machine survives into `.retained`); `false` on the `ForEach` removal
    /// path, where the parent unmounts the card and this machine is
    /// discarded by its owner without ever seeing this event in practice.
    /// Modelled here anyway (rather than only carrying the `true` case) so
    /// the reducer stays total: an out-of-band call with `false` is a no-op,
    /// not a trap.
    case fadeCompleted(parentRetainsCard: Bool)
    /// The port's authoritative visibility state has returned to `.live`
    /// while THIS generation's machine is `.retained`. Spec: "Same-generation
    /// recovery" (owner ruling 2026-08-28, supersedes the earlier
    /// no-resurrection rule): `#536`-style churn can hold a port dead past
    /// the visibility grace window without a real unplug, and without
    /// recovery the card would show "Nothing connected" indefinitely for a
    /// cable that is, in fact, still working. The ONLY phase this moves is
    /// `.retained`, and it moves it straight to `.settled` (the full card,
    /// never a spinner: a fresh `.loading` start only ever happens via
    /// `SettlingCardReplacement.startingPhase` on a genuinely NEW
    /// generation, never as a reducer transition on an existing one).
    /// Everywhere else a no-op, keeping the reducer total: `.fading` in
    /// particular does NOT recover mid-fade (spec: "no mid-fade reversal");
    /// it must finish fading to `.retained` first.
    case sessionResumed
}

// MARK: - Replacement (a new generation is NOT an event)

/// A new session generation (a genuine new plug, or a coalesced rapid
/// replug) is NOT modelled as an event fed to the old machine. Spec: "State
/// identity across a generation change belongs to the (portID,
/// generation)-keyed subview: the old machine is discarded whole."
///
/// This is deliberately NOT `SettlingCardReducer.reduce(phase:event:
/// generation:)` with a `generationReplaced` case. An earlier version of
/// this file had exactly that, hardcoded to always yield `.loading`. That
/// is wrong: the spec's trigger conditions can legitimately put a BRAND NEW
/// generation straight into `.settled` at construction time too (MagSafe;
/// a coalesced rapid replug where the session has already ended again by
/// the time the new machine is built; age already past the window on a slow
/// mount). Hardcoding `.loading` in a reducer arm would silently violate
/// those cases the moment a caller used it instead of the trigger. Task 3
/// must construct the replacement machine's starting phase via
/// `SettlingCardTrigger.evaluate(_:)` (see below), the same as any other
/// fresh mount, never by transitioning the old one.
public enum SettlingCardReplacement {
    /// Discards the old `(portID, generation)` machine and computes the
    /// starting phase for the new one, exactly as a fresh mount would. A
    /// thin, explicitly-named pass-through to `SettlingCardTrigger.evaluate`
    /// so the "replacement is reconstruction, not a transition" rule has one
    /// call site in this file rather than being left to convention.
    public static func startingPhase(for input: SettlingCardTriggerInput) -> SettlingCardPhase {
        SettlingCardTrigger.evaluate(input)
    }
}

// MARK: - Reducer

/// The pure `(phase, event) -> phase` reducer. A free function, not a
/// method on a stateful type, so it is trivially testable and has no
/// hidden state of its own: the caller (Task 3's per-card view state) owns
/// the current phase and generation and threads them through.
public enum SettlingCardReducer {
    /// - Parameters:
    ///   - phase: the machine's current phase.
    ///   - event: the event to apply.
    ///   - generation: the machine's own session generation, used only to
    ///     validate `deadlineReached`'s carried generation.
    /// - Returns: the resulting phase. Total: every `(phase, event)` pair
    ///   has a defined result. A pairing the spec never wires up in
    ///   practice (e.g. `fadeCompleted` while `.loading`) is an explicit
    ///   no-op (returns `phase` unchanged), never a trap, so a caller bug
    ///   that delivers an unexpected event degrades to "nothing happened"
    ///   rather than a crash.
    public static func reduce(
        phase: SettlingCardPhase,
        event: SettlingCardEvent,
        generation: Int
    ) -> SettlingCardPhase {
        switch event {
        case .deadlineReached(let wokeGeneration):
            switch phase {
            case .loading:
                // The one and only release path. A wake for an obsolete
                // generation (a stale timer that fired after a replug) is
                // ignored; the machine stays exactly where it is.
                return wokeGeneration == generation ? .settled : .loading
            case .settled, .fading, .retained:
                // Terminal-with-respect-to-this-event in every other phase.
                // Crucially: `.fading` staying `.fading` here is what makes
                // "session end during loading -> .fading; a queued timeout
                // wake cannot then settle" (spec, Release tests list) hold:
                // a deadline task armed before the session ended can still
                // wake up after `.fading` has already been entered, and it
                // must not resurrect the body.
                return phase
            }

        case .sessionEnded:
            switch phase {
            case .loading, .settled:
                return .fading
            case .fading, .retained:
                // Already ending / already ended. A redundant sessionEnded
                // (e.g. the visibility verdict re-confirms "ended" on a
                // later pass) is a no-op, not a re-entry into `.fading`.
                return phase
            }

        case .fadeCompleted(let parentRetainsCard):
            switch phase {
            case .fading:
                // The one real transition this event drives. When the
                // parent does NOT retain the card, the parent's `ForEach`
                // removal owns disposal and this machine is discarded by
                // its owner rather than told; returning `.fading` unchanged
                // here is the total-reducer fallback for that case, not a
                // path Task 3 is expected to exercise.
                return parentRetainsCard ? .retained : .fading
            case .loading, .settled, .retained:
                // Out of sequence (no exit animation was running). No-op.
                return phase
            }

        case .sessionResumed:
            switch phase {
            case .retained:
                // Spec: "Same-generation recovery". The full card, never a
                // spinner: `.settled`, not `.loading`. A fresh `.loading`
                // start is a construction-time decision
                // (`SettlingCardReplacement.startingPhase`) for a genuinely
                // new generation, never a reducer transition on an existing
                // one.
                return .settled
            case .loading, .settled, .fading:
                // No-op everywhere else. `.fading` in particular: recovery
                // does NOT interrupt an in-flight exit (spec: "no mid-fade
                // reversal"); the fade must finish to `.retained` first, and
                // only THEN can a later `sessionResumed` recover it.
                // `.loading`/`.settled` have nothing to recover FROM (the
                // session hasn't ended for this machine at all).
                return phase
            }
        }
    }
}

// MARK: - Trigger

/// The authoritative visibility/liveness verdict as the trigger needs it,
/// mirroring `WhatCableCore.PortVisibilityState`'s three cases one-for-one
/// (spec, "Trigger": "the port is .live or explicitly transient
/// (.fading-grace), never .hidden").
///
/// Deliberately has NO case for "unknown" / "not yet evaluated". The spec's
/// "Implementation cautions" section is explicit that a temporarily missing
/// visibility entry (a nil lookup on the initial frame) must NOT be read as
/// transient fading-grace. `ContentView.mainContent` (read for this task;
/// not modified by it) already resolves that nil case itself:
///
///     switch portVisibilityStates[port.serviceName] {
///     case .hidden: return false
///     case .live, .fading: return true
///     case nil:
///         // Not yet evaluated by the periodic tick (e.g. the very first
///         // frame). Fall back to the immediate signal so a freshly-plugged
///         // port isn't briefly hidden.
///         return isPortLive(port, structurallyScopedDevices: ...)
///     }
///
/// i.e. nil falls back to the immediate `isPortLive` signal, which is a
/// live-or-not verdict, never a "transient/fading" one. This type's absence
/// of an "unknown" case forces Task 3's caller to perform that same
/// resolution (nil -> live or ended, never -> transientFadingGrace) BEFORE
/// calling `SettlingCardTrigger.evaluate`, mirroring the parent's existing
/// handling faithfully instead of re-deciding it here with a different
/// (and looser) default.
public enum SettlingCardVisibility: Equatable, Sendable {
    case live
    case transientFadingGrace
    case ended
}

/// Inputs to the trigger evaluation (spec, "Trigger"): whether a freshly
/// mounted card should start at `.loading` (spinner) or `.settled`
/// (today's card, immediately).
public struct SettlingCardTriggerInput: Equatable, Sendable {
    /// `PortConnectionSessionTracker.retainedAttachInstant(for:)` /
    /// `AppleHPMInterfaceWatcher.connectionRetainedAttachInstant(for:)`
    /// (Task 1). `nil` for a never-stamped session (e.g. a relaunch
    /// mid-connection): condition 1 fails, trigger starts at `.settled`.
    public var retainedAttachInstant: TimeInterval?
    /// The current monotonic time (e.g. `ProcessInfo.processInfo.systemUptime`,
    /// matching `ContentView.recomputePortVisibility`'s clock choice).
    public var now: TimeInterval
    /// `PortSummary.emarkerReadWindow`, passed in rather than referenced
    /// directly so this stays a pure function of its inputs.
    public var window: TimeInterval
    /// MagSafe ports never start the loading placeholder (spec, "Trigger").
    public var isMagSafe: Bool
    /// The authoritative visibility verdict, already resolved by the caller
    /// per the doc comment on `SettlingCardVisibility`.
    public var visibility: SettlingCardVisibility

    public init(
        retainedAttachInstant: TimeInterval?,
        now: TimeInterval,
        window: TimeInterval,
        isMagSafe: Bool,
        visibility: SettlingCardVisibility
    ) {
        self.retainedAttachInstant = retainedAttachInstant
        self.now = now
        self.window = window
        self.isMagSafe = isMagSafe
        self.visibility = visibility
    }
}

/// The trigger evaluation: which phase a freshly mounted card starts at.
public enum SettlingCardTrigger {
    /// All four conditions from the spec's "Trigger" section, ALL required
    /// for `.loading`; any one failing falls through to `.settled`
    /// ("today's card immediately").
    public static func evaluate(_ input: SettlingCardTriggerInput) -> SettlingCardPhase {
        // MagSafe: never spinner, regardless of anything else.
        guard !input.isMagSafe else { return .settled }

        // Condition 1: retained attach instant known.
        guard let instant = input.retainedAttachInstant else { return .settled }

        // Condition 2: age inside the window at mount. `max(0, ...)` mirrors
        // `ContentView.connectionAge`'s clamp (a clock read can race the
        // stamp by a hair on the same tick; negative age is meaningless).
        let age = max(0, input.now - instant)
        guard age < input.window else { return .settled }

        // Condition 3: the authoritative visibility state has not declared
        // the session ended.
        switch input.visibility {
        case .live, .transientFadingGrace:
            return .loading
        case .ended:
            return .settled
        }
    }
}

// MARK: - Deadline

/// The generation-scoped deadline arithmetic (spec, "Release rule"):
/// `deadline = retainedAttachInstant + PortSummary.emarkerReadWindow + epsilon`.
public enum SettlingCardDeadline {
    /// "epsilon ~0.1s; deadline is explicitly approximate" (spec). Matches
    /// the epsilon `ContentView.waitForEmarkerWindowExpiry` already uses for
    /// the same purpose (landing the re-render just after macOS's own
    /// schedule, not exactly on it).
    public static let epsilon: TimeInterval = 0.1

    /// The absolute monotonic instant the deadline falls at.
    public static func instant(retainedAttachInstant: TimeInterval, window: TimeInterval) -> TimeInterval {
        retainedAttachInstant + window + epsilon
    }

    /// The remaining interval to sleep from `now`, clamped to zero (never
    /// negative: a mount that already missed the deadline should fire
    /// immediately, not schedule a wait into the past).
    public static func remaining(retainedAttachInstant: TimeInterval, window: TimeInterval, now: TimeInterval) -> TimeInterval {
        max(0, instant(retainedAttachInstant: retainedAttachInstant, window: window) - now)
    }
}
