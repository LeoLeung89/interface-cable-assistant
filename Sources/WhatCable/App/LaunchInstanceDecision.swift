import Foundation

/// Whether a launching copy of WhatCable should continue starting up, or
/// hand off to a copy that's already running.
///
/// Two ways a second launch can happen (issue #455): reopening the SAME
/// running copy (double-click the Dock/menu-bar icon, or Finder while it's
/// already open) is handled by AppKit's `applicationShouldHandleReopen`
/// hook and never reaches this decision. This type covers the OTHER case:
/// a DIFFERENT copy on disk sharing the same bundle ID (e.g. one launched
/// from `/Applications` while a Homebrew-installed copy is already
/// running). Without a guard both copies watch the ports, post duplicate
/// notifications, and steal each other's focus, observed live.
///
/// This is an ELECTION, not a simple "is anyone else running?" check.
/// Two copies can both start `applicationDidFinishLaunching` at nearly the
/// same moment (e.g. a launcher double-click while Homebrew is mid-upgrade
/// and relaunching the old copy), and each would see the other as
/// "already running" if the check only asked existence. The election
/// needs a rule every copy agrees on independently, with no coordination
/// between them, using only facts that are stable for the lifetime of the
/// comparison:
///
/// - No other instance found: this copy is the only one, so it continues.
/// - Both processes' launch dates are known and differ: the EARLIER one
///   wins (it's the more established copy) and the later one defers.
/// - Launch dates are equal, or either one is unknown: fall back to the
///   process ID, which every process already has and which can never tie.
///   The lower PID wins. Both copies compute this the same way from the
///   same two PIDs, so they always agree on the same winner.
///
/// An earlier cut of this election used `NSRunningApplication.isFinishedLaunching`
/// instead of a launch date, and that was wrong: the flag is TRANSIENT,
/// not a fact fixed at launch. A higher-PID copy that loses the election
/// and starts handing off returns from its delegate callback while the
/// handover is still in flight, and AppKit marks it "finished launching"
/// at that point, before the handover has actually completed. A
/// lower-PID copy checking a moment later would read the deferring copy
/// as established and ALSO defer to it: both copies hand off to each
/// other, both terminate, zero copies survive. `launchDate` doesn't have
/// this problem: it's set once, at process launch, and never changes
/// afterwards, so both copies see the same value for each other for as
/// long as the election is being decided.
enum LaunchInstanceDecision: Equatable {
    /// No other instance found, or this instance won the election. Start
    /// up normally.
    case continueLaunch
    /// Another instance is already running (or won the election). Hand off
    /// to it and terminate this process, without starting any subsystem.
    case deferToRunningInstance

    /// Pure decision, kept separate from `NSRunningApplication` so it's
    /// testable without a real running process (not available under
    /// `swift test`).
    ///
    /// - Parameters:
    ///   - otherExists: Whether another process shares this bundle ID.
    ///   - myLaunch: This process's `NSRunningApplication.current.launchDate`.
    ///   - otherLaunch: The other process's `launchDate`. Either date can
    ///     be nil (AppKit doesn't guarantee it), which is exactly why the
    ///     PID fallback exists.
    ///   - myPID: This process's PID, the tiebreak when dates are equal
    ///     or either is unknown.
    ///   - otherPID: The other process's PID. Ignored when `otherExists`
    ///     is false.
    static func decide(
        otherExists: Bool,
        myLaunch: Date?,
        otherLaunch: Date?,
        myPID: Int32,
        otherPID: Int32
    ) -> LaunchInstanceDecision {
        guard otherExists else { return .continueLaunch }
        if let myLaunch, let otherLaunch, myLaunch != otherLaunch {
            return myLaunch < otherLaunch ? .continueLaunch : .deferToRunningInstance
        }
        // Dates equal, or either side unknown: fall back to PID, which
        // both copies can read reliably and which can never tie.
        return myPID < otherPID ? .continueLaunch : .deferToRunningInstance
    }
}
