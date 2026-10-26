import Foundation
import WhatCableCore

/// Accumulates live SMC DC-in (voltage, current) pairs for the charging-path
/// resistance regression, with per-path reset, transient rejection and the
/// estimate itself (charging-path resistance rework, 2026-08).
///
/// The regression fits `V = a + b*I` over the samples and reports
/// `-b * 1000` as milliohms: the slope of the Mac-side DC-in voltage against
/// current is the negative of the whole charging-path resistance (cable
/// VBUS+GND loop + connectors + charger output impedance + Mac board path).
/// The fitted intercept absorbs the charger's fixed setpoint, so no absolute
/// voltage reference is needed. This replaced the `PowerOutDetails` feed,
/// which the corpus proved never produced a single accepted sample (see
/// `research/cable-resistance-via-iokit.md`).
///
/// This is a pure value type (no IOKit, no @MainActor) so it is
/// unit-testable with synthetic sample sequences and the captured fixture.
///
/// ## Per-path reset
/// The caller resolves a `ChargingInputResolver.Fingerprint` each tick (port +
/// contract identity). When it changes, or resolves to nil, the sample buffer
/// clears and a settle countdown starts, covering cable swap, charger swap,
/// port change and PD renegotiation.
///
/// ## Transient rejection
/// The first `settleSkipCount` ticks after a fingerprint change are
/// discarded. At a 1 s poll rate this gives a ~5 s settle window covering the
/// PD renegotiation handshake. The countdown ticks on every call regardless
/// of whether a usable sample arrives, so the window is wall-clock based.
///
/// ## Distinct-tuple rule (owner criterion)
/// The SMC publishes at roughly 1 Hz while the service may poll faster, so
/// consecutive reads can return the identical (volts, amps, watts) tuple.
/// Identical readings add no regression information and must not advance
/// convergence: a tick whose tuple equals the previously accepted one is
/// dropped.
struct RegressionAccumulator {

    // MARK: - Types

    struct Sample: Equatable {
        /// Mac-side DC-in voltage (`VD0R`), volts.
        let volts: Double
        /// DC-in current (`ID0R`), amps.
        let amps: Double
    }

    // MARK: - Configuration

    /// Number of ticks to discard after a fingerprint change.
    let settleSkipCount: Int

    /// Maximum sample buffer size. Oldest entries are dropped when exceeded.
    let maxSamples: Int

    /// Minimum charging current for a tick to count at all, amps. Below this
    /// the Mac is effectively not drawing (battery full, lid closed) and the
    /// reading carries no slope information.
    let minAmps: Double

    /// Distinct samples required before any value is reported (below:
    /// `insufficient`).
    let minSamplesForValue: Int

    /// Distinct samples required for a `stable` verdict (between the two:
    /// `converging`).
    let minSamplesForStable: Int

    /// Required current span, amps (owner criterion: 0.5 A minimum). Below
    /// this the fit is `unreliable` regardless of sample count.
    let minCurrentSpan: Double

    /// Minimum R-squared for `stable`.
    let minRSquared: Double

    /// Relative tolerance for the `PDTR ~= VD0R * ID0R` sanity gate. A tick
    /// whose reported watts disagree with volts x amps by more than this
    /// fraction (with a 1 W floor for tiny loads) is dropped: the three keys
    /// were not published together, so the pair may be torn.
    let wattsTolerance: Double

    // MARK: - State

    private(set) var samples: [Sample] = []
    private(set) var lastFingerprint: ChargingInputResolver.Fingerprint?
    private(set) var settleCountdown: Int = 0
    /// The last ACCEPTED (volts, amps, watts) tuple, for the distinct-tuple
    /// rule. Reset with the buffer.
    private var lastTuple: SMCSystemPowerInput?
    /// The most recent `stable` fit for the CURRENT fingerprint. A converged
    /// reading stays valid until the path itself changes (cable, charger,
    /// port, contract): the rolling buffer ages varied samples out during
    /// idle, and without this latch the UI would drop a good reading back to
    /// "measuring" a few minutes after the workload flattens (owner decision,
    /// 2026-08-11). Refreshed whenever a newer fit reaches `stable`; cleared
    /// wherever the buffer resets.
    private var latchedStable: CableResistanceEstimate?
    /// Consecutive ticks with an eligible fingerprint but no SMC input. A
    /// short blip is tolerated; a sustained outage clears the buffer so a
    /// converged estimate cannot sit on screen as fresh while the data
    /// underneath it stopped (review finding: an SMC failure mid-session
    /// used to republish the old stable value indefinitely).
    private var missedInputStreak: Int = 0

    /// Eligible ticks with no SMC input tolerated before the buffer clears.
    /// ~10 s at the 1 Hz poll: long enough to ride out a transient user-client
    /// hiccup, short enough that a genuinely dead SMC degrades to
    /// `insufficient` promptly.
    static let maxMissedInputTicks = 10

    // MARK: - Lifecycle

    init(
        settleSkipCount: Int = 5,
        maxSamples: Int = 240,
        minAmps: Double = 0.05,
        minSamplesForValue: Int = 10,
        minSamplesForStable: Int = 30,
        minCurrentSpan: Double = 0.5,
        minRSquared: Double = 0.7,
        wattsTolerance: Double = 0.15
    ) {
        self.settleSkipCount = settleSkipCount
        self.maxSamples = maxSamples
        self.minAmps = minAmps
        self.minSamplesForValue = minSamplesForValue
        self.minSamplesForStable = minSamplesForStable
        self.minCurrentSpan = minCurrentSpan
        self.minRSquared = minRSquared
        self.wattsTolerance = wattsTolerance
    }

    mutating func reset() {
        samples.removeAll()
        lastFingerprint = nil
        settleCountdown = 0
        lastTuple = nil
        missedInputStreak = 0
        latchedStable = nil
    }

    // MARK: - Core logic

    /// Process one tick.
    ///
    /// - Parameters:
    ///   - input: the live SMC DC-in read, or nil when the SMC is unreadable
    ///     this tick (older silicon, sandbox). The feature then simply never
    ///     accumulates and the estimate stays `insufficient`.
    ///   - fingerprint: the resolved charging path, or nil when any
    ///     eligibility gate failed this tick.
    /// - Returns: true when a new sample was accepted (useful for testing).
    @discardableResult
    mutating func append(
        input: SMCSystemPowerInput?,
        fingerprint: ChargingInputResolver.Fingerprint?
    ) -> Bool {
        guard let fingerprint else {
            // Not an eligible charging state. Drop any collected samples:
            // they belong to a path that no longer exists (unplug) or one
            // that was never attributable (second charger appeared), and
            // keeping them would let a later re-plug splice two different
            // cables into one fit.
            if lastFingerprint != nil || !samples.isEmpty {
                samples.removeAll()
                lastFingerprint = nil
                lastTuple = nil
                latchedStable = nil
            }
            if settleCountdown > 0 { settleCountdown -= 1 }
            return false
        }

        if fingerprint != lastFingerprint {
            samples.removeAll()
            lastFingerprint = fingerprint
            lastTuple = nil
            settleCountdown = settleSkipCount
            missedInputStreak = 0
            latchedStable = nil
        }

        if settleCountdown > 0 {
            settleCountdown -= 1
            return false
        }

        // Eligible tick but the SMC gave nothing: count the outage, and after
        // a sustained run clear the buffer so the estimate degrades to
        // `insufficient` instead of freezing at its last value.
        guard let input else {
            missedInputStreak += 1
            if missedInputStreak >= Self.maxMissedInputTicks {
                samples.removeAll()
                lastTuple = nil
                latchedStable = nil
            }
            return false
        }
        missedInputStreak = 0

        guard input.volts > 0, input.amps >= minAmps else { return false }

        // Distinct-tuple rule: an SMC publication identical to the last
        // accepted one carries no new information.
        if let last = lastTuple, last == input { return false }

        // PDTR sanity gate: volts, amps and watts must describe the same
        // instant. Only meaningful when `watts` is a real `PDTR` read; the
        // computed fallback would compare a product with itself and pass
        // vacuously (review finding), so it is skipped honestly instead.
        if input.pdtrIsMeasured {
            let computed = input.volts * input.amps
            let tolerance = max(1.0, computed * wattsTolerance)
            guard abs(input.watts - computed) <= tolerance else { return false }
        }

        lastTuple = input
        samples.append(Sample(volts: input.volts, amps: input.amps))
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
        return true
    }

    // MARK: - Estimate

    /// Attribution for the current estimate: the display port key of the
    /// charging path the samples belong to, or nil when none is resolved.
    var attributedPortKey: String? { lastFingerprint?.portKey }

    /// What the snapshot reports: the latest `stable` fit for this path if
    /// one has been achieved (see `latchedStable`), else the live fit.
    /// Mutating because a fresh `stable` fit updates the latch here, on the
    /// same tick every consumer reads.
    mutating func reportedEstimate() -> CableResistanceEstimate {
        let live = estimate()
        if live.status == .stable {
            latchedStable = live
            return live
        }
        return latchedStable ?? live
    }

    /// The regression over the current buffer.
    ///
    /// Status ladder:
    /// - fewer than `minSamplesForValue` distinct samples -> `insufficient`;
    /// - current span below `minCurrentSpan` -> `unreliable` (the span is
    ///   surfaced so the UI can say "needs load variation");
    /// - non-negative slope -> `unreliable` (voltage rising with current is
    ///   physically wrong for a resistive path; usually a source moving its
    ///   setpoint);
    /// - under `minSamplesForStable` -> `converging`;
    /// - R-squared under `minRSquared` -> `unreliable`; else `stable`.
    func estimate() -> CableResistanceEstimate {
        let spanAmps = (samples.map(\.amps).max() ?? 0) - (samples.map(\.amps).min() ?? 0)
        let spanMA = Int((spanAmps * 1000).rounded())

        guard samples.count >= minSamplesForValue else {
            return CableResistanceEstimate(
                milliohms: 0, sampleCount: samples.count, rSquared: 0,
                status: .insufficient, currentSpanMilliamps: spanMA
            )
        }
        guard spanAmps >= minCurrentSpan else {
            return CableResistanceEstimate(
                milliohms: 0, sampleCount: samples.count, rSquared: 0,
                status: .unreliable, currentSpanMilliamps: spanMA
            )
        }

        let count = Double(samples.count)
        let meanAmps = samples.reduce(0) { $0 + $1.amps } / count
        let meanVolts = samples.reduce(0) { $0 + $1.volts } / count
        let sxx = samples.reduce(0) { $0 + pow($1.amps - meanAmps, 2) }
        guard sxx > 0 else {
            return CableResistanceEstimate(
                milliohms: 0, sampleCount: samples.count, rSquared: 0,
                status: .unreliable, currentSpanMilliamps: spanMA
            )
        }
        let sxy = samples.reduce(0) { $0 + (($1.amps - meanAmps) * ($1.volts - meanVolts)) }
        let slope = sxy / sxx
        let intercept = meanVolts - slope * meanAmps
        let total = samples.reduce(0) { $0 + pow($1.volts - meanVolts, 2) }
        let residual = samples.reduce(0) {
            let predicted = slope * $1.amps + intercept
            return $0 + pow($1.volts - predicted, 2)
        }
        let rSquared = total > 0 ? max(0, 1 - residual / total) : 0

        // Volts per amp -> milliohms. Negative slope (sag under load) is the
        // physical expectation; its negation is the path resistance.
        let milliohms = -slope * 1000

        guard milliohms > 0 else {
            return CableResistanceEstimate(
                milliohms: 0, sampleCount: samples.count, rSquared: rSquared,
                status: .unreliable, currentSpanMilliamps: spanMA
            )
        }

        let status: CableResistanceEstimate.Status
        if samples.count < minSamplesForStable {
            status = .converging
        } else if rSquared >= minRSquared {
            status = .stable
        } else {
            status = .unreliable
        }
        return CableResistanceEstimate(
            milliohms: milliohms, sampleCount: samples.count, rSquared: rSquared,
            status: status, currentSpanMilliamps: spanMA
        )
    }
}
