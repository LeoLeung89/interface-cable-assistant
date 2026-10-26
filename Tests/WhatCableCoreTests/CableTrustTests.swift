import Testing
@testable import WhatCableCore

@Suite("Cable Trust tier")
struct CableTrustTests {

    // A spec-encoding flag and an identity flag. In the behaviour-first model
    // both are *notes only*: neither sets the tier.
    private static let specFlag: TrustFlag = .reservedSpeedEncoding(5)
    private static let identityFlag: TrustFlag = .zeroVendorID(corroborated: false)

    // MARK: Green (confirmed delivery)

    @Test("Data confirmation is green")
    func dataConfirmedIsGreen() {
        let t = CableTrust(flags: [], vendorRegistered: false,
                           dataConfirmed: true, powerConfirmed: false, contradiction: false)
        #expect(t.tier == .green)
        #expect(t.confirmedBy == [.data])
        #expect(t.isConfirmed)
    }

    @Test("Power confirmation is green")
    func powerConfirmedIsGreen() {
        let t = CableTrust(flags: [], vendorRegistered: false,
                           dataConfirmed: false, powerConfirmed: true, contradiction: false)
        #expect(t.tier == .green)
        #expect(t.confirmedBy == [.power])
    }

    @Test("Both axes confirmed")
    func bothConfirmed() {
        let t = CableTrust(flags: [], vendorRegistered: true,
                           dataConfirmed: true, powerConfirmed: true, contradiction: false)
        #expect(t.tier == .green)
        #expect(t.confirmedBy == [.data, .power])
    }

    @Test("Performance outranks pedigree: zeroed VID still green when confirmed")
    func confirmedDespiteZeroedVID() {
        let t = CableTrust(flags: [Self.identityFlag], vendorRegistered: false,
                           dataConfirmed: true, powerConfirmed: false, contradiction: false)
        #expect(t.tier == .green)
        #expect(t.confirmedBy == [.data])
    }

    // MARK: Amber (unverified)

    @Test("Registered vendor with a clean e-marker is amber until seen to perform")
    func registeredCleanIsAmber() {
        // Registration is not proof of delivery, so green requires behaviour.
        let t = CableTrust(flags: [], vendorRegistered: true,
                           dataConfirmed: false, powerConfirmed: false, contradiction: false)
        #expect(t.tier == .amber)
        #expect(t.confirmedBy.isEmpty)
        #expect(!t.isConfirmed)
    }

    @Test("Zeroed VID with no confirmation is amber")
    func zeroedVIDIsAmber() {
        let t = CableTrust(flags: [Self.identityFlag], vendorRegistered: false,
                           dataConfirmed: false, powerConfirmed: false, contradiction: false)
        #expect(t.tier == .amber)
    }

    // MARK: Red (corroborated non-delivery, Phase 2)

    @Test("Session non-delivery is red")
    func sessionFailedIsRed() {
        let t = CableTrust(flags: [], vendorRegistered: true,
                           dataConfirmed: false, powerConfirmed: false,
                           contradiction: false, sessionFailed: true)
        #expect(t.tier == .red)
        #expect(t.confirmedBy.isEmpty)
        #expect(!t.isConfirmed)
    }

    @Test("Session non-delivery outranks confirmation: red, not green")
    func sessionFailedOverridesConfirmation() {
        // A cable that performed earlier but then demonstrably failed is red.
        let t = CableTrust(flags: [], vendorRegistered: true,
                           dataConfirmed: true, powerConfirmed: true,
                           contradiction: false, sessionFailed: true)
        #expect(t.tier == .red)
        #expect(t.confirmedBy.isEmpty)
    }

    @Test("Only .notPerforming drives red; caution and performing do not")
    func onlyNotPerformingIsRed() {
        let report = CableTrustReport(flags: [])
        func tier(_ v: SessionMonitor.Verdict?) -> CableTrust.Tier {
            CableTrust(report: report, vendorRegistered: true, dataLink: nil,
                       negotiatedWatts: nil, ratedWatts: nil, sessionVerdict: v).tier
        }
        #expect(tier(.notPerforming) == .red)
        #expect(tier(.caution) == .amber)
        #expect(tier(.performing) == .amber)
        #expect(tier(nil) == .amber)
    }

    // MARK: Spec flags are notes, never a verdict

    @Test("A spec-encoding flag alone is amber, not red")
    func specFlagAloneIsAmber() {
        // The corpus disproof: spec-encoding quirks fire on genuine cables, so
        // they must not drive a damning tier. Carried as a note, tier stays
        // amber.
        let t = CableTrust(flags: [Self.specFlag], vendorRegistered: true,
                           dataConfirmed: false, powerConfirmed: false, contradiction: false)
        #expect(t.tier == .amber)
        #expect(t.flags == [Self.specFlag])
    }

    @Test("A confirmed cable with a spec flag is still green")
    func specFlagWithConfirmationIsGreen() {
        // Delivery outranks an untidy bit: the flag is a footnote, not a block.
        let t = CableTrust(flags: [Self.specFlag], vendorRegistered: false,
                           dataConfirmed: true, powerConfirmed: false, contradiction: false)
        #expect(t.tier == .green)
        #expect(t.flags == [Self.specFlag])
    }

    @Test("Without a session failure, static flags and confirmation never emit red")
    func noStaticPathToRed() {
        // Red comes only from corroborated non-delivery (sessionFailed). No
        // combination of e-marker flags or confirmation booleans can produce
        // it on its own: that is the corpus disproof made permanent.
        for flags in [[], [Self.specFlag], [Self.identityFlag]] {
            for confirmed in [true, false] {
                let t = CableTrust(flags: flags, vendorRegistered: false,
                                   dataConfirmed: confirmed, powerConfirmed: false, contradiction: false)
                #expect(t.tier != .red)
            }
        }
    }

    // MARK: Contradiction gates confirmation

    @Test("Contradiction suppresses confirmation, falls to amber")
    func contradictionSuppressesGreen() {
        let t = CableTrust(flags: [], vendorRegistered: true,
                           dataConfirmed: false, powerConfirmed: true, contradiction: true)
        #expect(t.confirmedBy.isEmpty)
        #expect(t.tier == .amber)
        #expect(t.contradiction)
    }

    // MARK: behaviour(for:) derivation

    @Test("cableLimit confirms; fine confirms only with a cable speed claim")
    func fineAndCableLimitConfirm() {
        #expect(CableTrust.behaviour(for: .cableLimit(cableGbps: 10, capableGbps: 40),
                                     hasCableSpeedClaim: true).dataConfirmed)
        #expect(CableTrust.behaviour(for: .fine(activeGbps: 40),
                                     hasCableSpeedClaim: true).dataConfirmed)
    }

    @Test("fine with no cable speed claim does NOT confirm (no false green)")
    func fineWithoutClaimDoesNotConfirm() {
        let b = CableTrust.behaviour(for: .fine(activeGbps: 40), hasCableSpeedClaim: false)
        #expect(!b.dataConfirmed)
        #expect(!b.contradiction)
    }

    @Test("Other-party limits and shortfalls never confirm and never contradict")
    func otherLimitsNeutral() {
        let cases: [DataLinkDiagnostic.Bottleneck?] = [
            .hostLimit(hostGbps: 10, capableGbps: 40),
            .deviceLimit(deviceGbps: 0.48),
            .degraded(activeGbps: 10, expectedGbps: 40),
            .unknownCable(activeGbps: 10),
            nil
        ]
        for c in cases {
            let b = CableTrust.behaviour(for: c, hasCableSpeedClaim: true)
            #expect(!b.dataConfirmed)
            #expect(!b.contradiction)
        }
    }

    @Test("cableContradictsActive sets contradiction, not confirmation")
    func contradictionCase() {
        let b = CableTrust.behaviour(for: .cableContradictsActive(cableGbps: 10, activeGbps: 40),
                                     hasCableSpeedClaim: true)
        #expect(!b.dataConfirmed)
        #expect(b.contradiction)
    }

    // MARK: Convenience init (power lower-bound rule)

    @Test("Carrying full rated power confirms; carrying less does not")
    func powerConfirmationLowerBound() {
        let clean = CableTrustReport(flags: [])
        // 100 W cable carrying a 100 W contract: confirmed -> green.
        let full = CableTrust(report: clean, vendorRegistered: false,
                              dataLink: nil, negotiatedWatts: 100, ratedWatts: 100)
        #expect(full.tier == .green)
        #expect(full.confirmedBy == [.power])

        // 240 W cable carrying only 100 W: a lower bound, not confirmation.
        let partial = CableTrust(report: clean, vendorRegistered: false,
                                 dataLink: nil, negotiatedWatts: 100, ratedWatts: 240)
        #expect(partial.confirmedBy.isEmpty)
        #expect(partial.tier == .amber)
    }
}
