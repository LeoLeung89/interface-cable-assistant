import Foundation

/// The trust verdict for a cable, as a single tier plus the evidence behind
/// it. Carries no user-facing copy (that arrives in the UI phase, the same
/// way `DataLinkDiagnostic` deferred its wording).
///
/// **Behaviour-first model** (see the private design note "cable-trust-model"). Trust is
/// whether the cable *delivers what it claims*, not whether its e-marker bits
/// are internally tidy. Running the static-flag model against the real cable
/// corpus showed that spec-encoding flags fire on genuine hardware (Apple's
/// own cables among them), so those flags are **notes only** here; they never
/// set the tier.
///
/// **Phase 1 (this type) produces green or amber only.**
/// - Green: we have *watched the cable deliver its claim* (the live link
///   carried its claimed speed, or a PD contract carried its full rated
///   power). Earns green even with a zeroed vendor ID: performance outranks
///   pedigree. Registration alone is **not** enough, because green is a claim
///   of proof and registration isn't proof of delivery.
/// - Amber: unverified. Nothing demanding has been connected, or the maker
///   can't be corroborated. Not a fault, never "suspicious."
///
/// Red ("isn't performing as expected") is Phase 2: it needs attributed,
/// *corroborated* non-delivery (repeat failure or overcurrent), which depends
/// on session-quality monitoring. This type never emits red yet.
public struct CableTrust: Hashable {
    public enum Tier: String, Hashable, Sendable {
        /// Watched delivering its claim.
        case green
        /// Unverified: nothing to confirm, or maker can't be corroborated.
        case amber
        /// Demonstrably not delivering. Reserved for Phase 2 (behavioural,
        /// built on session monitoring); not produced by this type yet.
        case red
    }

    /// Which behavioural axes confirmed delivery. Non-empty only on green.
    public enum Dimension: String, Hashable, Sendable {
        /// The live data link carried the cable's full claimed speed.
        case data
        /// A PD contract carried at or above the cable's full rated power.
        case power
    }

    public let tier: Tier

    /// The axes that confirmed delivery (green only). Tells the UI whether to
    /// say "we've seen it carry 40 Gbps", "its full 100 W", or both.
    public let confirmedBy: Set<Dimension>

    /// Static e-marker flags that fired. **Informational notes only**; they
    /// do not affect the tier. Rendered as hedged "unusual" detail.
    public let flags: [TrustFlag]

    /// Whether the vendor ID is USB-IF registered. Informational (drives the
    /// amber "registered vendor, not yet seen to perform" note); not a tier
    /// driver, because registration is an assumption of genuineness, not
    /// proof of delivery.
    public let vendorRegistered: Bool

    /// The live link disagrees with the e-marker's claim. A pointer for the
    /// UI ("see the Negotiation breakdown"); it gates off confirmation (we
    /// won't claim delivery while readings conflict) but never itself sets a
    /// tier.
    public let contradiction: Bool

    /// True when green was earned by watching the cable perform.
    public var isConfirmed: Bool { tier == .green }

    // MARK: Primitive init (unit-tested directly)

    /// - Parameters:
    ///   - flags: the static e-marker trust flags (notes only).
    ///   - vendorRegistered: whether the vendor ID is in the USB-IF list.
    ///   - dataConfirmed: the live link carried the cable's full claimed speed.
    ///   - powerConfirmed: a PD contract carried the cable's full rated power.
    ///   - contradiction: the link and e-marker disagree (gates confirmation).
    ///   - sessionFailed: session monitoring corroborated non-delivery
    ///     (repeated/sustained data degradation or out-of-spec resistance
    ///     under load). This is the only path to red. It outranks
    ///     confirmation: a cable that performed earlier but then demonstrably
    ///     failed is red, not green.
    public init(
        flags: [TrustFlag],
        vendorRegistered: Bool,
        dataConfirmed: Bool,
        powerConfirmed: Bool,
        contradiction: Bool,
        sessionFailed: Bool = false
    ) {
        self.flags = flags
        self.vendorRegistered = vendorRegistered
        self.contradiction = contradiction

        // Corroborated non-delivery wins outright. Red is never "confirmed
        // delivering", so it carries no confirmed dimensions.
        if sessionFailed {
            self.tier = .red
            self.confirmedBy = []
            return
        }

        // A live disagreement between the e-marker and the link gates off
        // confirmation: we won't claim the cable delivered while two readings
        // contradict each other.
        var confirmed: Set<Dimension> = []
        if !contradiction {
            if dataConfirmed { confirmed.insert(.data) }
            if powerConfirmed { confirmed.insert(.power) }
        }

        if confirmed.isEmpty {
            self.tier = .amber
            self.confirmedBy = []
        } else {
            self.tier = .green
            self.confirmedBy = confirmed
        }
    }
}

extension CableTrust {
    // MARK: Convenience init (derives the behavioural signals)

    /// Build a verdict from the static report plus the live diagnostics.
    /// Derivation lives in one tested place.
    ///
    /// - Parameters:
    ///   - report: the static e-marker trust report (its flags become notes).
    ///   - vendorRegistered: `VendorDB.isRegistered(vendorID)`.
    ///   - dataLink: the port's data-link diagnostic, or nil when there's no
    ///     active link to judge.
    ///   - negotiatedWatts: the winning PD contract's wattage, or nil.
    ///   - ratedWatts: the cable e-marker's rated wattage, or nil.
    ///   - sessionVerdict: the running `SessionMonitor` verdict for this
    ///     connection, or nil when nothing is being watched. Only
    ///     `.notPerforming` drives red; `.caution` / `.performing` leave the
    ///     tier to the green/amber logic (a caution is not yet a conviction).
    public init(
        report: CableTrustReport,
        vendorRegistered: Bool,
        dataLink: DataLinkDiagnostic?,
        negotiatedWatts: Int?,
        ratedWatts: Int?,
        sessionVerdict: SessionMonitor.Verdict? = nil
    ) {
        // `.fine` can fire from the host/device floor with no cable speed
        // claim involved. Only treat it as confirmation when the cable
        // actually advertised a speed the link could meet, or we'd assert
        // "delivered its claim" for a claim the cable never made.
        let hasCableSpeedClaim = dataLink?.facts.cableGbps != nil
        let behaviour = CableTrust.behaviour(
            for: dataLink?.bottleneck,
            hasCableSpeedClaim: hasCableSpeedClaim
        )

        // Power is confirmed only when we've watched the cable carry its full
        // rated power. Carrying less is an honest lower bound (useful copy)
        // but not confirmation of the rating.
        let powerConfirmed: Bool
        if let negotiated = negotiatedWatts, let rated = ratedWatts, rated > 0 {
            powerConfirmed = negotiated >= rated
        } else {
            powerConfirmed = false
        }

        self.init(
            flags: report.flags,
            vendorRegistered: vendorRegistered,
            dataConfirmed: behaviour.dataConfirmed,
            powerConfirmed: powerConfirmed,
            contradiction: behaviour.contradiction,
            sessionFailed: sessionVerdict == .notPerforming
        )
    }

    /// Map a data-link bottleneck to the two behavioural booleans. Extracted
    /// so the rules are testable without building a full `DataLinkDiagnostic`.
    ///
    /// Data is confirmed only by two cases: the link ran right up to the
    /// cable's own rating (`.cableLimit`, which only fires when a cable claim
    /// exists), or it ran at the fastest the parties support (`.fine`) AND the
    /// cable advertised a speed. `.fine` alone isn't enough: it can come from
    /// the host/device floor with no cable claim, and confirming a claim the
    /// cable never made would be a false green. `.cableContradictsActive` is
    /// the e-marker and link disagreeing with no tie-breaker: a pointer, not
    /// confirmation. Every other case is someone else's limit (host, device)
    /// or an unattributable shortfall, none of which is the cable's fault, so
    /// none confirm and none contradict.
    ///
    /// - Parameter hasCableSpeedClaim: whether the cable advertised a usable
    ///   speed (from its e-marker or the controller). Gates the `.fine` case.
    public static func behaviour(
        for bottleneck: DataLinkDiagnostic.Bottleneck?,
        hasCableSpeedClaim: Bool
    ) -> (dataConfirmed: Bool, contradiction: Bool) {
        switch bottleneck {
        case .cableLimit:
            return (true, false)
        case .fine:
            return (hasCableSpeedClaim, false)
        case .cableContradictsActive:
            return (false, true)
        case .blockedBySecurity:
            // A security block is not a cable-trust signal: the cable's
            // capabilities are not in question, only the user's approval state.
            return (false, false)
        case .hostLimit, .deviceLimit, .degraded, .unknownCable, .none:
            return (false, false)
        }
    }
}
