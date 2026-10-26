import Foundation
import WhatCableCore

/// Tracks, per physical port, how long the CURRENT cable connection has been
/// live, so the UI can show "Reading cable details…" only for the ~5s
/// window macOS actually needs to read the e-marker (see
/// `PortSummary.emarkerReadWindow`), instead of guessing from a sampled age.
///
/// Pure: no `IOKit` import, no `Date`. `AppleHPMInterfaceWatcher` owns one
/// instance and calls `observe(_:)` with the rebuilt `[AppleHPMInterface]`
/// array on every `refresh()`, so this type is exercised without touching
/// the registry, and this file is the only place session-identity policy
/// lives.
///
/// ## Clock
///
/// Time arrives through an injected `() -> TimeInterval` seam returning
/// MONOTONIC seconds (e.g. mach uptime), never `Date`/wall-clock. A wall
/// clock can jump backwards under NTP correction or a manual time change,
/// which would produce a negative or nonsensical "seconds since attach".
/// Tests inject a fake clock for determinism.
///
/// ## Session identity
///
/// `AppleHPMInterface.plugEventCount` (falling back to `connectionCount`) is
/// the token used to tell a genuinely new plug apart from macOS's own
/// attribution churn (issue #536: a single power source gets bounced
/// between two ports' `connectionActive` flags every 1-2s without a real
/// unplug happening). See `observe(_:)` for the exact transition rules, and
/// `SessionToken` for what happens when neither field is available.
public final class PortConnectionSessionTracker {
    /// Per-port session state.
    private struct SessionState {
        /// Monotonic instant the CURRENT session was stamped at. `nil` means
        /// "unknown": either this port's first observation arrived already
        /// active (watcher just started, or an app relaunch mid-connection),
        /// or no observation has ever put it in a state where a stamp made
        /// sense.
        var startedAt: TimeInterval?
        /// The session token last seen while the port was active. Compared
        /// against a fresh observation's token to tell a churn round-trip
        /// (same token) from a genuine replug (different token).
        var lastActiveToken: SessionToken
        /// Whether the port is active as of the most recent `observe(_:)`.
        var isActive: Bool
        /// Bumped every time the session is (re)stamped. Never bumped by a
        /// churn-reuse or a steady true->true observation. Task 3 (app UI)
        /// keys a SwiftUI `.task(id:)` expiry timer off this value so a
        /// genuine replug restarts the timer and a churn round-trip does not.
        var generation: Int
    }

    /// The session-identity token read off one observation of a port.
    ///
    /// `.none` means neither `plugEventCount` nor `connectionCount` was
    /// available on this observation. On a machine/port where that is
    /// permanently the case, there is no reliable way to distinguish a churn
    /// round-trip from a genuine replug, so `observe(_:)` falls back to
    /// PLAIN TRANSITION STAMPING for that port: every false/nil -> true
    /// transition restamps unconditionally (never reused), and steady
    /// true -> true observations do nothing. Accepted limitation (spec
    /// "Backend" section): a #536 churn flip on such a port produces, at
    /// worst, a spurious ~6s reappearance of "Reading cable details…",
    /// never a wrong verdict.
    private enum SessionToken: Equatable {
        case value(Int)
        case none
    }

    private var sessions: [UInt64: SessionState] = [:]
    private let now: () -> TimeInterval

    /// - Parameter now: a monotonic-seconds clock seam. In production this
    ///   should be backed by mach uptime (e.g.
    ///   `Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000`),
    ///   never the wall clock. Tests inject a fake clock they can advance by hand.
    public init(now: @escaping () -> TimeInterval) {
        self.now = now
    }

    /// Feed the rebuilt port list for one watcher refresh. Call this on
    /// EVERY refresh, including ones where the caller ends up skipping its
    /// own publish because the array compared equal, so a session-token-only
    /// change is never missed even if some future change to
    /// `AppleHPMInterface` narrowed what participates in its `==`.
    public func observe(_ ports: [AppleHPMInterface]) {
        let currentIDs = Set(ports.map(\.id))

        // Port entry id no longer observed: drop its state entirely. A port
        // that reappears later (a real controller re-enumeration, not a
        // cable event) is then treated as a brand new port for session
        // purposes, i.e. a fresh "first observation".
        for id in sessions.keys where !currentIDs.contains(id) {
            sessions.removeValue(forKey: id)
        }

        let timestamp = now()

        for port in ports {
            let token = Self.sessionToken(for: port)
            let isActive = port.connectionActive == true

            guard var state = sessions[port.id] else {
                // First observation of this port entry id (tracker fresh, or
                // after reset()/prune). If it's already active we do NOT
                // stamp: we have no idea how long it's been connected (the
                // watcher may have just started mid-connection), so age must
                // stay unknown rather than claim "just plugged in".
                sessions[port.id] = SessionState(
                    startedAt: nil,
                    // Only record a "last active" token when this first
                    // observation actually was active. An inactive first
                    // observation has no prior active session at all, so
                    // `.none` here is the "nothing to compare against"
                    // sentinel: it makes the eventual false -> true
                    // transition fall through to the genuine-new-plug
                    // restamp, rather than being mistaken for a churn
                    // round-trip just because this port's token happens to
                    // equal the value first seen while inactive.
                    lastActiveToken: isActive ? token : .none,
                    isActive: isActive,
                    generation: 0
                )
                continue
            }

            if isActive {
                if state.isActive {
                    // true -> true. A changed, KNOWN token means a rapid
                    // replug got coalesced into a single observation (no
                    // false state was ever seen): restamp. An unchanged
                    // token, or a `.none` token (identity unknowable), means
                    // treat as the same continuing session; leave the stamp
                    // alone.
                    if token != state.lastActiveToken && token != .none {
                        state.startedAt = timestamp
                        state.lastActiveToken = token
                        state.generation += 1
                    }
                } else {
                    // false/nil -> true.
                    if token == .none {
                        // No session identity available at all: plain
                        // transition stamping, always restamp (see
                        // `SessionToken` doc).
                        state.startedAt = timestamp
                        state.lastActiveToken = token
                        state.generation += 1
                    } else if token == state.lastActiveToken {
                        // Same session token as the last true-state: this
                        // cannot be a new plug (the counter increments per
                        // plug, measured on live captures), so it is a #536
                        // churn round-trip. Keep whatever stamp we already
                        // have, unchanged either way:
                        //   - a real stamp (state.startedAt != nil): reuse
                        //     it, do not restamp.
                        //   - nil (the port's first-ever observation arrived
                        //     already active, e.g. app relaunch mid-
                        //     connection, so age has been unknown since the
                        //     start): stay unknown. Restamping "now" here
                        //     would manufacture a known-but-wrong age and
                        //     claim "just plugged in" on a connection that
                        //     could be hours old, which is exactly the wrong
                        //     claim the nil-on-first-observation rule exists
                        //     to prevent. Do not bump generation either.
                        state.lastActiveToken = token
                    } else {
                        // Genuine new plug: the token changed.
                        state.startedAt = timestamp
                        state.lastActiveToken = token
                        state.generation += 1
                    }
                }
                state.isActive = true
            } else {
                // true -> false, or a continued false/nil. Retain the stamp
                // and the last-active token (needed for a later churn
                // reuse); just record inactivity. `connectionAge` reports
                // nil for any inactive port regardless of a retained stamp.
                state.isActive = false
            }

            sessions[port.id] = state
        }
    }

    /// Seconds since the current session was stamped, or nil when unknown
    /// (never observed active with a known start, or the port is currently
    /// inactive). Always nonnegative.
    public func connectionAge(for portID: UInt64) -> TimeInterval? {
        guard let state = sessions[portID], state.isActive, let startedAt = state.startedAt else {
            return nil
        }
        return max(0, now() - startedAt)
    }

    /// The monotonic instant the current session was stamped at, for a
    /// caller (Task 3, the app UI) that wants to recompute age itself on
    /// every render rather than consume a sampled snapshot that goes stale.
    /// Nil under the same conditions as `connectionAge(for:)`.
    public func attachInstant(for portID: UInt64) -> TimeInterval? {
        guard let state = sessions[portID], state.isActive else { return nil }
        return state.startedAt
    }

    /// The monotonic instant the current session was stamped at, RETAINED
    /// across a transient inactive interval (unlike `attachInstant(for:)`,
    /// which returns nil the moment the port goes inactive).
    ///
    /// Why this exists: the settling-card state machine (spec
    /// "settling-card") mounts its `.loading` placeholder at the moment a
    /// port becomes visible, but issue #536's churn can flip
    /// `connectionActive` false for a beat on the SAME session before it
    /// flips back true, with no real unplug happening. `attachInstant(for:)`
    /// deliberately returns nil during that gap (it answers "is this session
    /// live right now"), which would make a loading card lose its deadline
    /// and restart the spinner on every churn flip. This accessor answers a
    /// different question: "what was the retained start of the most recent
    /// session, active or not", so a generation-scoped deadline computed
    /// from it survives the transient dip.
    ///
    /// Dead-session caveat: a young retained instant does not mean the
    /// session is still alive. A real unplug also leaves the stamp in place
    /// (see `observe(_:)`'s true -> false branch), so a card that mounts
    /// just after a genuine unplug can read a recent instant here for a
    /// session that has already ended. This accessor does not gate on
    /// liveness; the caller (the presentation trigger, spec "Trigger"
    /// section) is responsible for checking the authoritative
    /// visibility/liveness state before treating the returned instant as the
    /// start of a live session.
    ///
    /// Returns nil for a never-stamped session (first observation arrived
    /// already active, so age is unknown), after `reset()`, or once the
    /// port id has been pruned (no longer observed). Replaced whenever
    /// `observe(_:)` restamps the session (a genuine new plug or a coalesced
    /// rapid replug), same as `attachInstant(for:)`.
    public func retainedAttachInstant(for portID: UInt64) -> TimeInterval? {
        sessions[portID]?.startedAt
    }

    /// Changes only when the session is (re)stamped: a genuine new plug or a
    /// coalesced rapid replug, never a churn round-trip reuse or a steady
    /// true -> true observation. Task 3 keys a SwiftUI `.task(id:)` off this
    /// so an expiry timer restarts exactly when a new session actually
    /// begins. Nil when the port has no tracked state at all.
    public func sessionGeneration(for portID: UInt64) -> Int? {
        sessions[portID]?.generation
    }

    /// Clears all tracked session state. Call on watcher `stop()` so a
    /// restart begins fresh (no stale stamps from a previous run).
    public func reset() {
        sessions.removeAll()
    }

    private static func sessionToken(for port: AppleHPMInterface) -> SessionToken {
        if let plugEventCount = port.plugEventCount {
            return .value(plugEventCount)
        }
        if let connectionCount = port.connectionCount {
            return .value(connectionCount)
        }
        return .none
    }
}
