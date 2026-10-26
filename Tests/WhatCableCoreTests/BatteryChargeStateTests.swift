import Testing
@testable import WhatCableCore

/// The SMC charge-state chain step by step.
@Suite("Battery charge state")
struct BatteryChargeStateTests {
    /// Charger present and able to charge, battery not full, nothing
    /// inhibiting. Each test changes one key from here.
    private func plugged(_ edit: (inout BatteryChargeInputs) -> Void = { _ in }) -> BatteryChargeInputs {
        var k = BatteryChargeInputs(ch0r: 0, chce: true, chcc: true, bsfc: false, buic: 50, chnc: 0, chsc: true)
        edit(&k)
        return k
    }

    private func decide(_ edit: (inout BatteryChargeInputs) -> Void) -> BatteryChargeState? {
        BatteryChargeState.decide(plugged(edit))
    }

    @Test("Baseline reads charging")
    func baseline() { #expect(BatteryChargeState.decide(plugged()) == .charging) }

    @Test("Step 1: CH0R low bits mean running on battery, checked before CHCE")
    func ch0rLowBits() {
        #expect(decide { $0.ch0r = 0x10 } == .runningOnBattery)
        #expect(decide { $0.ch0r = 0x10; $0.chce = nil } == .runningOnBattery)
    }

    @Test("Step 1: CH0R inhibit with no charger is not plugged in; with a charger or unknown it is running on battery")
    func ch0rNeedsCharger() {
        #expect(decide { $0.ch0r = 0x8; $0.chce = false } == .notPluggedIn)
        #expect(decide { $0.ch0r = 0x8; $0.chce = true } == .runningOnBattery)
        #expect(decide { $0.ch0r = 0x8; $0.chce = nil } == .runningOnBattery)
    }

    @Test("Step 1: CH0R bit 8 (BMS busy), bits above 15 and an absent CH0R are ignored")
    func ch0rIgnoredBits() {
        #expect(decide { $0.ch0r = 0x100 } == .charging)
        #expect(decide { $0.ch0r = 0x1_0000 } == .charging)
        #expect(decide { $0.ch0r = nil } == .charging)
    }

    @Test("Step 2: CHCE off is not plugged in; CHCC off is running on battery")
    func chargerPresence() {
        #expect(decide { $0.chce = false } == .notPluggedIn)
        #expect(decide { $0.chcc = false } == .runningOnBattery)
    }

    @Test("Step 3: AC-i below 100 is running on battery; 100 passes")
    func acInputLimit() {
        #expect(decide { $0.acInputLimit = 99 } == .runningOnBattery)
        #expect(decide { $0.acInputLimit = 100 } == .charging)
    }

    @Test("Step 4: BSFC set is full, ahead of CHNC")
    func bsfcFull() {
        #expect(decide { $0.bsfc = true; $0.chnc = 1 << 14 } == .full)
    }

    @Test("Step 5: CHNC bits")
    func chncBits() {
        #expect(decide { $0.chnc = 1 } == .full)
        #expect(decide { $0.chnc = 1 << 23 } == .charging)
        #expect(decide { $0.chnc = 1 << 24 } == .chargeLimitReached)
        #expect(decide { $0.chnc = (1 << 24) | (1 << 55) } == .chargeLimitReached)
        #expect(decide { $0.chnc = 1 << 14 } == .onHold)
        #expect(decide { $0.chnc = (1 << 23) | (1 << 14) } == .onHold)
        #expect(decide { $0.chnc = 0 } == .charging)
    }

    @Test("Step 5: BMS busy at the charge limit is on hold")
    func bmsBusyAtLimit() {
        // CHLS low byte 80 gives limit 75.
        #expect(decide { $0.chnc = 1 << 23; $0.chls = 80; $0.buic = 80 } == .onHold)
        #expect(decide { $0.chnc = 1 << 23; $0.chls = 80; $0.buic = 74 } == .charging)
        // No CHLS: CHWA on gives the fixed limit 75.
        #expect(decide { $0.chnc = 1 << 23; $0.chwa = true; $0.buic = 75 } == .onHold)
        #expect(decide { $0.chnc = 1 << 23; $0.chwa = false; $0.buic = 90 } == .charging)
        // Per reading: CHWA present means CHWA is used and
        // CHLS never is. CHLS is consulted only when CHWA is absent.
        #expect(decide { $0.chnc = 1 << 23; $0.chls = 0; $0.chwa = true; $0.buic = 80 } == .onHold)
        #expect(decide { $0.chnc = 1 << 23; $0.chls = 80; $0.chwa = false; $0.buic = 90 } == .charging)
        // CHLS alone (no CHWA) below 10 sets no limit.
        #expect(decide { $0.chnc = 1 << 23; $0.chls = 5; $0.buic = 90 } == .charging)
        // A limit with BUIC unreadable is not limited.
        #expect(decide { $0.chnc = 1 << 23; $0.chls = 80; $0.buic = nil } == .charging)
    }

    @Test("Step 6: no CHNC, CHSC decides")
    func chscFallback() {
        #expect(decide { $0.chnc = nil; $0.chsc = true } == .charging)
        #expect(decide { $0.chnc = nil; $0.chsc = false } == .onHold)
    }

    @Test("A missing required key returns nil, so callers keep the battery record")
    func missingKeysReturnNil() {
        #expect(BatteryChargeState.decide(BatteryChargeInputs()) == nil)
        #expect(decide { $0.chce = nil } == nil)
        #expect(decide { $0.chcc = nil } == nil)
        #expect(decide { $0.bsfc = nil } == nil)
        #expect(decide { $0.chnc = nil; $0.chsc = nil } == nil)
    }

    @Test("resolvedFlags: nil leaves the battery record untouched")
    func resolvedPassThrough() {
        let values: [Bool?] = [true, false, nil]
        for ic in values { for fc in values {
            let r = BatteryChargeState.resolvedFlags(state: nil, isCharging: ic, fullyCharged: fc)
            #expect(r.isCharging == ic && r.fullyCharged == fc)
        } }
    }

    @Test("resolvedFlags: notPluggedIn clears a stale IsCharging and keeps FullyCharged")
    func resolvedNotPluggedIn() {
        let values: [Bool?] = [true, false, nil]
        for fc in values {
            let r = BatteryChargeState.resolvedFlags(state: .notPluggedIn, isCharging: true, fullyCharged: fc)
            #expect(r.isCharging == false && r.fullyCharged == fc)
        }
    }

    @Test("resolvedFlags: a decided state overrides a stale battery record")
    func resolvedOverride() {
        let charging = BatteryChargeState.resolvedFlags(state: .charging, isCharging: false, fullyCharged: false)
        #expect(charging.isCharging == true && charging.fullyCharged == false)
        let full = BatteryChargeState.resolvedFlags(state: .full, isCharging: false, fullyCharged: false)
        #expect(full.isCharging == false && full.fullyCharged == true)
        for state in [BatteryChargeState.onHold, .chargeLimitReached, .runningOnBattery] {
            let r = BatteryChargeState.resolvedFlags(state: state, isCharging: true, fullyCharged: true)
            #expect(r.isCharging == false && r.fullyCharged == false)
        }
    }
}
