import Testing
@testable import WhatCableCore

@Suite("Cable resistance tier (spec-anchored)")
struct CableResistanceTierTests {

    private func estimate(_ mOhm: Double, _ status: CableResistanceEstimate.Status = .stable)
        -> CableResistanceEstimate {
        CableResistanceEstimate(milliohms: mOhm, sampleCount: 40, rSquared: 0.9, status: status)
    }

    @Test("Non-stable estimates have no tier")
    func nonStableNil() {
        #expect(estimate(50, .converging).tier(ratedFiveA: true) == nil)
        #expect(estimate(50, .insufficient).tier(ratedFiveA: false) == nil)
        #expect(estimate(50, .unreliable).tier(ratedFiveA: true) == nil)
    }

    @Test("5 A budget: good < 100, marginal 100-150, high > 150")
    func fiveAmpBudget() {
        #expect(estimate(99).tier(ratedFiveA: true) == .good)
        #expect(estimate(100).tier(ratedFiveA: true) == .marginal)
        #expect(estimate(150).tier(ratedFiveA: true) == .marginal)
        #expect(estimate(151).tier(ratedFiveA: true) == .high)
    }

    @Test("3 A budget: good < 165, marginal 165-250, high > 250")
    func threeAmpBudget() {
        #expect(estimate(164).tier(ratedFiveA: false) == .good)
        #expect(estimate(165).tier(ratedFiveA: false) == .marginal)
        #expect(estimate(250).tier(ratedFiveA: false) == .marginal)
        #expect(estimate(251).tier(ratedFiveA: false) == .high)
    }

    @Test("The old 300 mOhm reading is now High, not Marginal")
    func oldThresholdRegression() {
        // The bug this fixes: 280 mOhm used to read "Marginal" (orange). It's
        // out of spec for every rating now.
        #expect(estimate(280).tier(ratedFiveA: false) == .high)
        #expect(estimate(280).tier(ratedFiveA: true) == .high)
    }
}
