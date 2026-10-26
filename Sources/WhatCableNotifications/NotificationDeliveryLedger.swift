import Foundation

/// Owns the per-category sequence counter and last-posted identifier that
/// `NotificationDecision.deliveryDirective(for:sequence:previousIdentifier:)`
/// needs as input. Kept as its own small type, separate from
/// `DeviceDiffSequencer`, on purpose: `DeviceDiffSequencer` already carries a
/// large amount of timing/ordering state (settle debounce, parked-diff
/// bookkeeping, presentation gap, absolute deadline) with its own dense set
/// of invariants; this bookkeeping is unrelated to any of that (it doesn't
/// care when a post happens, only how many of a given category have
/// happened so far), so giving it a dedicated type keeps both easier to read
/// and test in isolation.
///
/// No `Foundation.Date` or `UUID`: the sequence number is a plain
/// incrementing counter, not a timestamp, so directives are fully
/// deterministic and don't need a clock to test.
///
/// One instance per `DeviceDiffSequencer`, constructed fresh in its `init`.
/// That's what makes "a fresh sequencer starts clean" true: nothing here is
/// shared across instances or persisted between app launches.
public final class NotificationDeliveryLedger {
    private var sequences: [NotificationCategory: UInt64] = [:]
    private var lastIdentifiers: [NotificationCategory: String] = [:]

    /// A string, unique to THIS app launch, folded into every identifier
    /// this ledger hands out (see `nextDirective`). Fixes the
    /// cross-launch collision Codex flagged: without it, a fresh launch's
    /// sequence counter restarts at 1, so its first post reuses the exact
    /// identifier ("device-event-1") a PREVIOUS launch's first post already
    /// used. macOS's Notification Centre keeps delivered notifications
    /// across launches, so that reused identifier silently replaces the
    /// stale one instead of banner-ing a fresh notification, and the stale
    /// one is never explicitly cleared. Never generated in here (this
    /// module never calls `UUID()` or `Date()`, see the purity note on the
    /// type doc comment above): the caller supplies it, so a test can pass
    /// a fixed value and directives stay fully deterministic.
    private let launchToken: String

    /// - Parameter launchToken: a launch-unique string (production: the
    ///   app-side shim's full `UUID().uuidString`, not truncated, so a
    ///   same-second relaunch's token is negligibly unlikely to collide
    ///   with the previous launch's), folded into every identifier this
    ///   ledger produces. No default: every caller must decide deliberately
    ///   what identifies this launch, rather than silently falling back to
    ///   something that could collide.
    public init(launchToken: String) {
        self.launchToken = launchToken
    }

    /// Advances `category`'s sequence counter and returns the directive for
    /// the next post in that category: a fresh identifier (this category's
    /// new sequence number, never reused) plus the identifier of the
    /// PREVIOUS post in the SAME category to remove, if any. Distinct
    /// categories keep entirely separate counters and "previous identifier"
    /// slots, so a charger post never removes a device identifier or vice
    /// versa.
    ///
    /// - Parameter previousPostWasRecent: whether the previous same-category
    ///   post went out within the spacing window (the caller's clock-based
    ///   judgement; see `DeliveryDirective.removePendingIdentifiers`'s doc
    ///   comment). Threaded straight through to `deliveryDirective`.
    public func nextDirective(for category: NotificationCategory, previousPostWasRecent: Bool) -> NotificationDecision.DeliveryDirective {
        let sequence = (sequences[category] ?? 0) + 1
        sequences[category] = sequence
        let directive = NotificationDecision.deliveryDirective(
            for: category,
            sequence: sequence,
            previousIdentifier: lastIdentifiers[category],
            previousPostWasRecent: previousPostWasRecent,
            launchToken: launchToken
        )
        lastIdentifiers[category] = directive.identifier
        return directive
    }
}
