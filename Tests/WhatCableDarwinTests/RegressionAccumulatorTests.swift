import Foundation
import Testing
@testable import WhatCableDarwinBackend
import WhatCableCore

// Charging-path resistance rework (2026-08): the accumulator regresses live SMC DC-in (VD0R volts, ID0R amps)
// and reports -slope as the whole charging-path resistance. These tests cover
// every owner acceptance criterion that is testable synthetically, plus a
// replay of the real 2026-08-11 dev-M5 charge capture.

private func fp(
    port: String = "2/4",
    voltage: Int = 20_000,
    current: Int = 5_000,
    sourceID: UInt64 = 42
) -> ChargingInputResolver.Fingerprint {
    ChargingInputResolver.Fingerprint(
        portJoinKey: "uuid-\(port)", portKey: port, sourceID: sourceID,
        contractVoltageMV: voltage, contractCurrentMA: current
    )
}

/// A physically consistent input: watts = volts * amps, so the PDTR sanity
/// gate passes unless a test overrides watts to break it on purpose.
private func input(volts: Double, amps: Double, watts: Double? = nil) -> SMCSystemPowerInput {
    SMCSystemPowerInput(volts: volts, amps: amps, watts: watts ?? (volts * amps))
}

/// Feed a synthetic sweep: current ramps `from` -> `to` across `count` ticks,
/// voltage sags by `milliohms` per amp around a 20.1 V setpoint. Every tuple
/// is distinct by construction.
private func feedRamp(
    _ acc: inout RegressionAccumulator,
    milliohms: Double,
    from: Double,
    to: Double,
    count: Int,
    fingerprint: ChargingInputResolver.Fingerprint = fp()
) {
    for i in 0..<count {
        let amps = from + (to - from) * Double(i) / Double(max(count - 1, 1))
        let volts = 20.1 - (milliohms / 1000) * amps
        acc.append(input: input(volts: volts, amps: amps), fingerprint: fingerprint)
    }
}

@Suite("RegressionAccumulator (charging-path resistance)")
struct RegressionAccumulatorTests {

    // MARK: - Success path

    @Test("Clean ramp converges to the synthetic resistance, stable, R² ≈ 1")
    func syntheticSuccess() {
        var acc = RegressionAccumulator(settleSkipCount: 0)
        feedRamp(&acc, milliohms: 180, from: 0.3, to: 1.4, count: 40)
        let est = acc.estimate()
        #expect(est.status == .stable)
        #expect(abs(est.milliohms - 180) < 1, "Slope must recover the synthetic 180 mOhm")
        #expect(est.rSquared > 0.99)
        #expect(est.sampleCount == 40)
        #expect(est.currentSpanMilliamps == 1100)
        #expect(acc.attributedPortKey == "2/4")
    }

    @Test("Below 30 samples the estimate is converging, not stable")
    func convergingBelowStableFloor() {
        var acc = RegressionAccumulator(settleSkipCount: 0)
        feedRamp(&acc, milliohms: 180, from: 0.3, to: 1.4, count: 20)
        #expect(acc.estimate().status == .converging)
    }

    @Test("Below 10 samples the estimate is insufficient")
    func insufficientBelowValueFloor() {
        var acc = RegressionAccumulator(settleSkipCount: 0)
        feedRamp(&acc, milliohms: 180, from: 0.3, to: 1.4, count: 5)
        let est = acc.estimate()
        #expect(est.status == .insufficient)
        #expect(est.milliohms == 0)
    }

    // MARK: - Owner gates

    @Test("Current span under 0.5 A is unreliable regardless of sample count")
    func insufficientSpan() {
        var acc = RegressionAccumulator(settleSkipCount: 0)
        // 0.3 A span, 40 clean samples: plenty of data, not enough spread.
        feedRamp(&acc, milliohms: 180, from: 0.5, to: 0.8, count: 40)
        let est = acc.estimate()
        #expect(est.status == .unreliable)
        #expect(est.currentSpanMilliamps == 300)
    }

    @Test("Noisy voltage (low R²) is unreliable, never stable")
    func lowRSquared() {
        var acc = RegressionAccumulator(settleSkipCount: 0)
        // Deterministic pseudo-noise of ±0.5 V swamps the ~0.2 V of real
        // signal across the ramp, so the fit cannot reach R² 0.7.
        for i in 0..<40 {
            let amps = 0.3 + 1.1 * Double(i) / 39.0
            let noise = Double((i * 7919) % 100) / 100.0 - 0.5
            let volts = 20.1 - 0.18 * amps + noise
            acc.append(input: input(volts: volts, amps: amps), fingerprint: fp())
        }
        let est = acc.estimate()
        #expect(est.status == .unreliable)
        #expect(est.rSquared < 0.7)
    }

    @Test("Positive slope (voltage rising with current) is unreliable")
    func positiveSlope() {
        var acc = RegressionAccumulator(settleSkipCount: 0)
        // A source ramping its setpoint UP under load: physically wrong for a
        // resistive path, must never be reported as a resistance.
        feedRamp(&acc, milliohms: -180, from: 0.3, to: 1.4, count: 40)
        let est = acc.estimate()
        #expect(est.status == .unreliable)
        #expect(est.milliohms == 0)
    }

    @Test("Distinct-tuple rule: repeated identical publications do not advance convergence")
    func distinctTupleRule() {
        var acc = RegressionAccumulator(settleSkipCount: 0)
        let same = input(volts: 20.0, amps: 1.0)
        for _ in 0..<25 {
            acc.append(input: same, fingerprint: fp())
        }
        #expect(acc.samples.count == 1, "24 identical re-reads must not count as new samples")
        #expect(acc.estimate().status == .insufficient)
    }

    @Test("PDTR sanity gate drops a tick whose watts disagree with volts × amps")
    func pdtrSanityGate() {
        var acc = RegressionAccumulator(settleSkipCount: 0)
        // 20 V × 1 A with 40 W reported: a torn read, must be dropped.
        let torn = input(volts: 20.0, amps: 1.0, watts: 40.0)
        let ok = acc.append(input: torn, fingerprint: fp())
        #expect(!ok)
        #expect(acc.samples.isEmpty)
        // The same electrical point with consistent watts is accepted.
        let ok2 = acc.append(input: input(volts: 20.0, amps: 1.0), fingerprint: fp())
        #expect(ok2)
    }

    @Test("Ticks below the minimum charging current are ignored")
    func minimumCurrentGate() {
        var acc = RegressionAccumulator(settleSkipCount: 0)
        let ok = acc.append(input: input(volts: 20.0, amps: 0.01), fingerprint: fp())
        #expect(!ok)
        #expect(acc.samples.isEmpty)
    }

    // MARK: - Reset semantics

    @Test("Fingerprint change (renegotiated contract) clears the buffer and re-settles")
    func contractChangeResets() {
        var acc = RegressionAccumulator(settleSkipCount: 2)
        // Burn the initial settle window, then accumulate on contract A.
        for i in 0..<12 {
            acc.append(input: input(volts: 20.0 - Double(i) * 0.01, amps: 0.5 + Double(i) * 0.1), fingerprint: fp())
        }
        #expect(acc.samples.count == 10)

        // Contract renegotiates (same port, new current ceiling).
        let renegotiated = fp(current: 3_000)
        let accepted = acc.append(input: input(volts: 20.0, amps: 1.0), fingerprint: renegotiated)
        #expect(!accepted, "First tick after a contract change is in the settle window")
        #expect(acc.samples.isEmpty, "Old contract's samples must be cleared")
        #expect(acc.lastFingerprint == renegotiated)
    }

    @Test("Port change clears the buffer")
    func portChangeResets() {
        var acc = RegressionAccumulator(settleSkipCount: 0)
        feedRamp(&acc, milliohms: 180, from: 0.3, to: 1.4, count: 15)
        #expect(acc.samples.count == 15)
        // settleSkipCount is 0, so the same tick that triggers the reset is
        // also the first accepted sample of the NEW path: the old 15 must be
        // gone and exactly the new one present.
        acc.append(input: input(volts: 20.0, amps: 1.0), fingerprint: fp(port: "2/1"))
        #expect(acc.samples == [RegressionAccumulator.Sample(volts: 20.0, amps: 1.0)])
        #expect(acc.attributedPortKey == "2/1")
    }

    @Test("Losing eligibility (nil fingerprint) discards samples and attribution")
    func nilFingerprintDiscards() {
        var acc = RegressionAccumulator(settleSkipCount: 0)
        feedRamp(&acc, milliohms: 180, from: 0.3, to: 1.4, count: 15)
        #expect(acc.samples.count == 15)
        // Unplug / second charger appears: nothing is attributable any more.
        acc.append(input: input(volts: 20.0, amps: 1.0), fingerprint: nil)
        #expect(acc.samples.isEmpty)
        #expect(acc.attributedPortKey == nil)
        #expect(acc.estimate().status == .insufficient)
    }

    @Test("Replug (new source registry ID) resets even with identical port and contract")
    func replugResets() {
        var acc = RegressionAccumulator(settleSkipCount: 0)
        feedRamp(&acc, milliohms: 180, from: 0.3, to: 1.4, count: 15)
        #expect(acc.samples.count == 15)
        // A cable swap recreates the power-source node: same port, same
        // negotiated contract, new registry entry ID. Two cables must never
        // share one fit.
        acc.append(input: input(volts: 20.0, amps: 1.0), fingerprint: fp(sourceID: 43))
        #expect(acc.samples.count == 1)
    }

    @Test("A sustained SMC outage mid-session clears a converged estimate instead of freezing it")
    func sustainedOutageClearsBuffer() {
        var acc = RegressionAccumulator(settleSkipCount: 0)
        feedRamp(&acc, milliohms: 180, from: 0.3, to: 1.4, count: 40)
        #expect(acc.reportedEstimate().status == .stable)
        // Eligible fingerprint, but the SMC stops answering. A short blip
        // keeps the estimate; a sustained outage must degrade it, INCLUDING
        // the latch: a frozen data source must not keep a "fresh" reading up.
        for _ in 0..<(RegressionAccumulator.maxMissedInputTicks - 1) {
            acc.append(input: nil, fingerprint: fp())
        }
        #expect(acc.reportedEstimate().status == .stable, "a brief blip must not discard a good fit")
        acc.append(input: nil, fingerprint: fp())
        #expect(acc.samples.isEmpty)
        #expect(acc.reportedEstimate().status == .insufficient)
        // Recovery accumulates fresh samples from scratch.
        let ok = acc.append(input: input(volts: 20.0, amps: 1.0), fingerprint: fp())
        #expect(ok)
    }

    // MARK: - Latch (owner decision 2026-08-11)

    @Test("A converged reading persists through an idle spell instead of degrading")
    func latchSurvivesIdleFlattening() {
        var acc = RegressionAccumulator(settleSkipCount: 0, maxSamples: 240)
        feedRamp(&acc, milliohms: 180, from: 0.3, to: 1.4, count: 40)
        let converged = acc.reportedEstimate()
        #expect(converged.status == .stable)

        // Idle spell: 240 distinct near-flat samples age every varied sample
        // out of the rolling buffer, so the LIVE fit loses its span and goes
        // unreliable. The reported estimate must stay the converged one.
        for i in 0..<240 {
            let amps = 0.25 + Double(i % 7) * 0.001
            let volts = 20.1 - 0.18 * amps
            acc.append(input: input(volts: volts, amps: amps), fingerprint: fp())
        }
        #expect(acc.estimate().status == .unreliable, "the live fit must have lost its span (test setup check)")
        let reported = acc.reportedEstimate()
        #expect(reported.status == .stable)
        #expect(abs(reported.milliohms - converged.milliohms) < 0.001, "the latched reading, not a new fit")
    }

    @Test("The latch clears on a fingerprint change")
    func latchClearsOnPathChange() {
        var acc = RegressionAccumulator(settleSkipCount: 0)
        feedRamp(&acc, milliohms: 180, from: 0.3, to: 1.4, count: 40)
        #expect(acc.reportedEstimate().status == .stable)
        // New connection (replug): the old cable's reading must not carry over.
        acc.append(input: input(volts: 20.0, amps: 1.0), fingerprint: fp(sourceID: 99))
        #expect(acc.reportedEstimate().status == .insufficient)
    }

    @Test("A newer stable fit refreshes the latch")
    func latchRefreshes() {
        var acc = RegressionAccumulator(settleSkipCount: 0, maxSamples: 240)
        feedRamp(&acc, milliohms: 180, from: 0.3, to: 1.4, count: 40)
        #expect(Int(acc.reportedEstimate().milliohms.rounded()) == 180)
        // The path warms up (resistance rises) and a fresh varied window
        // converges again: the newer fit must win. 240 samples fully evict
        // the old 180 mOhm window (test setup guarded by the count check).
        feedRamp(&acc, milliohms: 220, from: 0.3, to: 1.4, count: 240)
        #expect(acc.samples.count == 240)
        #expect(Int(acc.reportedEstimate().milliohms.rounded()) == 220)
    }

    @Test("PDTR gate is skipped honestly when watts is the computed fallback")
    func pdtrFallbackSkipsGate() {
        var acc = RegressionAccumulator(settleSkipCount: 0)
        // watts wildly off, but flagged as not-measured: the gate cannot
        // judge it, so the volt/amp pair is still usable.
        let fallback = SMCSystemPowerInput(volts: 20.0, amps: 1.0, watts: 40.0, pdtrIsMeasured: false)
        let ok = acc.append(input: fallback, fingerprint: fp())
        #expect(ok)
    }

    @Test("nil SMC input (blocked AppleSMC) accumulates nothing and stays insufficient")
    func nilInputDegradesToUnavailable() {
        var acc = RegressionAccumulator(settleSkipCount: 0)
        for _ in 0..<40 {
            acc.append(input: nil, fingerprint: fp())
        }
        #expect(acc.samples.isEmpty)
        #expect(acc.estimate().status == .insufficient)
    }

    @Test("Sample buffer is capped at maxSamples")
    func bufferCap() {
        var acc = RegressionAccumulator(settleSkipCount: 0, maxSamples: 10)
        feedRamp(&acc, milliohms: 180, from: 0.3, to: 1.4, count: 30)
        #expect(acc.samples.count == 10)
    }

    @Test("Settle window rejects the first ticks after the first fingerprint")
    func settleWindow() {
        var acc = RegressionAccumulator(settleSkipCount: 3)
        for i in 0..<3 {
            let ok = acc.append(input: input(volts: 20.0, amps: 1.0 + Double(i) * 0.1), fingerprint: fp())
            #expect(!ok, "Tick \(i) is inside the settle window")
        }
        let ok = acc.append(input: input(volts: 20.0, amps: 1.4), fingerprint: fp())
        #expect(ok)
    }

    // MARK: - Real capture replay

    @Test("Replaying the 2026-08-11 dev-M5 charge capture reproduces ~179.6 mOhm at R² ≥ 0.99")
    func realCaptureReplay() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/m5-charge-capture-2026-08-11.csv")
        let text = try String(contentsOf: url, encoding: .utf8)
        var acc = RegressionAccumulator(settleSkipCount: 0)
        var fed = 0
        for line in text.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: ",").map(String.init)
            // t,VD0R,ID0R,PDTR,...
            guard cols.count >= 4,
                  let v = Double(cols[1]), let i = Double(cols[2]), let w = Double(cols[3]) else { continue }
            acc.append(input: SMCSystemPowerInput(volts: v, amps: i, watts: w), fingerprint: fp())
            fed += 1
        }
        // Floor on what the parser fed, so a format drift shows up as a
        // failure here rather than as a vacuously green regression below.
        #expect(fed >= 150, "Fixture must parse; got \(fed) rows")
        // The capture polled at 2 Hz against a ~1 Hz SMC, so the distinct-
        // tuple rule must have dropped a large share of the rows.
        #expect(acc.samples.count >= 30)
        #expect(acc.samples.count < fed - 40, "Distinct-tuple rule must drop repeated publications")

        let est = acc.estimate()
        #expect(est.status == .stable)
        #expect(abs(est.milliohms - 179.6) < 3.0, "Live capture slope was 179.6 mOhm; got \(est.milliohms)")
        #expect(est.rSquared >= 0.99)
        #expect(est.currentSpanMilliamps >= 900)
    }
}
