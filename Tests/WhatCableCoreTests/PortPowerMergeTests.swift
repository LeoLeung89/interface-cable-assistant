import Foundation
import Testing
@testable import WhatCableCore

// MARK: - Unit tests for the per-port power merge
//
// WHY THESE EXIST ALONGSIDE THE CORPUS SWEEP. The corpus harness
// (`PortPowerMergeCharacterisationCorpusSweepTests`) replays 328 real machines
// and pins every decision the merge makes on them. It cannot, however, exercise
// the precedence order between an SMC reading and a contract, and this was
// measured rather than assumed: deliberately moving the contract fill ahead of
// the SMC fill changed ZERO of the 715 recorded rows.
//
// The reason is physical, not a gap in the corpus. An SMC channel reports power
// the Mac is sourcing OUT of a port. A contract is what a charger negotiated to
// push power IN. A port doing one is not doing the other, so in real captures
// the two never land on the same port key. No amount of extra corpus data would
// change that.
//
// So the ordering is pinned here instead, on hand-built inputs that put both
// sources on one port on purpose. Every fixture below uses realistic values
// (a 100 W 20 V charger, a 5 V peripheral draw) so a unit-confusion bug still
// shows up as an implausible number rather than a passing test.
@Suite("PortPowerMerge - precedence and provenance")
struct PortPowerMergeTests {

    // MARK: - Fixtures

    private static let uuidA = "aaaaaaaabbbbccccddddeeeeeeeeeeee"
    private static let uuidB = "11111111222233334444555555555555"

    /// Port 1 sourcing 5.1 V at 1.5 A, the shape a phone on a Mac's port makes.
    private static func liveChannel(
        uuid: String = uuidA,
        volts: Double = 5.1,
        amps: Double = 1.5,
        present: Bool = true
    ) -> SMCPortPowerChannel {
        SMCPortPowerChannel(channel: 1, present: present, volts: volts, amps: amps, uuid: uuid)
    }

    /// A `PowerOutDetails`-shaped sample: carries `adapterVoltage`, which is the
    /// field that makes it usable for the cable-resistance regression.
    private static func podSample(portKey: String, watts: Int = 7_650) -> PortPowerSample {
        PortPowerSample(
            portIndex: 1, portKey: portKey,
            current: 1_500, watts: watts,
            configuredVoltage: 5_000, configuredCurrent: 1_500,
            adapterVoltage: 5_139, vconnCurrent: 0, vconnPower: 0
        )
    }

    /// A negotiated-contract sample: 100 W at 20 V, the reporter's own charger
    /// from issue #491.
    private static func contractSample(portKey: String) -> PortPowerSample {
        PortPowerSample(
            portIndex: 1, portKey: portKey,
            current: 5_000, watts: 100_000,
            configuredVoltage: 20_000, configuredCurrent: 5_000,
            adapterVoltage: 0, vconnCurrent: 0, vconnPower: 0,
            isContractedFallback: true
        )
    }

    // MARK: - Precedence

    @Test("A live SMC reading beats PowerOutDetails on the same port")
    func smcBeatsPowerOutDetails() {
        let result = PortPowerMerge.merge(
            smcChannels: [Self.liveChannel()],
            uuidMap: [Self.uuidA: "2/1"],
            powerOutDetailSamples: [Self.podSample(portKey: "2/1")],
            contractedSamples: []
        )

        #expect(result.displaySamples.count == 1, "one port in, one card out")
        #expect(result.provenance["2/1"] == .smc)
        #expect(result.displaySamples[0].isSMCMeasured)
        // 5.1 V x 1.5 A = 7.65 W. The PowerOutDetails fixture is deliberately
        // the same wattage, so only the provenance and the flags distinguish
        // them: a watts-only assertion here would pass either way.
        #expect(result.displaySamples[0].configuredVoltage == 5_100,
            "the SMC's own 5.1 V should show, not PowerOutDetails' 5.0 V")
    }

    @Test("A live SMC reading beats a negotiated contract on the same port")
    func smcBeatsContract() {
        let result = PortPowerMerge.merge(
            smcChannels: [Self.liveChannel()],
            uuidMap: [Self.uuidA: "2/1"],
            powerOutDetailSamples: [],
            contractedSamples: [Self.contractSample(portKey: "2/1")]
        )

        #expect(result.displaySamples.count == 1)
        #expect(result.provenance["2/1"] == .smc)
        #expect(result.displaySamples[0].isSMCMeasured)
        #expect(result.displaySamples[0].isContractedFallback == false)
        #expect(result.displaySamples[0].watts == 7_650,
            "the measured 7.65 W should show, not the contract's 100 W ceiling")
    }

    @Test("PowerOutDetails beats a negotiated contract on the same port")
    func powerOutDetailsBeatsContract() {
        let result = PortPowerMerge.merge(
            smcChannels: [],
            uuidMap: [:],
            powerOutDetailSamples: [Self.podSample(portKey: "2/1")],
            contractedSamples: [Self.contractSample(portKey: "2/1")]
        )

        #expect(result.displaySamples.count == 1)
        #expect(result.provenance["2/1"] == .powerOutDetails)
        #expect(result.displaySamples[0].isContractedFallback == false)
        #expect(result.displaySamples[0].watts == 7_650)
    }

    @Test("Each source still covers the ports the ones above it did not")
    func lowerSourcesFillUncoveredPorts() {
        let result = PortPowerMerge.merge(
            smcChannels: [Self.liveChannel()],
            uuidMap: [Self.uuidA: "2/1"],
            powerOutDetailSamples: [Self.podSample(portKey: "2/2")],
            contractedSamples: [Self.contractSample(portKey: "17/1")]
        )

        #expect(result.displaySamples.count == 3, "three distinct ports, three cards")
        #expect(result.provenance["2/1"] == .smc)
        #expect(result.provenance["2/2"] == .powerOutDetails)
        #expect(result.provenance["17/1"] == .contracted)
        for sample in result.displaySamples {
            #expect(result.provenance[sample.portKey] != nil,
                "\(sample.portKey) displayed with no recorded provenance")
        }
    }

    // MARK: - perPortMeteringSupported

    @Test("An idle but resolvable channel still proves per-port metering works")
    func idleResolvableChannelSupportsMetering() {
        let result = PortPowerMerge.merge(
            smcChannels: [Self.liveChannel(volts: 0, amps: 0, present: false)],
            uuidMap: [Self.uuidA: "2/1"],
            powerOutDetailSamples: [],
            contractedSamples: []
        )

        // Nothing to show, but the machine is not an M1: the channel resolved.
        // Getting this backwards is what made the Power Monitor spin forever on
        // an idle desktop (#291).
        #expect(result.perPortMeteringSupported)
        #expect(result.displaySamples.isEmpty)
    }

    @Test("A channel whose UUID is not in the map does not count as metering support")
    func unresolvableChannelDoesNotSupportMetering() {
        let result = PortPowerMerge.merge(
            smcChannels: [Self.liveChannel(uuid: Self.uuidB)],
            uuidMap: [Self.uuidA: "2/1"],
            powerOutDetailSamples: [],
            contractedSamples: []
        )

        #expect(result.perPortMeteringSupported == false)
        #expect(result.displaySamples.isEmpty)
    }

    @Test("An empty UUID map skips the SMC entirely (M1/M2, Mac Pro)")
    func emptyUUIDMapSkipsSMC() {
        let result = PortPowerMerge.merge(
            smcChannels: [Self.liveChannel()],
            uuidMap: [:],
            powerOutDetailSamples: [Self.podSample(portKey: "2/1")],
            contractedSamples: []
        )

        #expect(result.perPortMeteringSupported == false)
        #expect(result.provenance["2/1"] == .powerOutDetails,
            "with no map the channel cannot be tied to a port, so PowerOutDetails must win")
    }

    // The old `meteredSamples` resistance-feed tests lived here. The feed was
    // removed in the 2026-08 charging-path rework (the corpus proved zero of its samples were ever
    // accepted); the regression now reads the live SMC DC-in pair, covered by
    // `RegressionAccumulatorTests`.

    // MARK: - Degenerate inputs

    @Test("No readers at all produces an empty result rather than a crash")
    func emptyInputsProduceEmptyResult() {
        let result = PortPowerMerge.merge(
            smcChannels: [], uuidMap: [:], powerOutDetailSamples: [], contractedSamples: []
        )
        #expect(result.displaySamples.isEmpty)
        #expect(result.provenance.isEmpty)
        #expect(result.perPortMeteringSupported == false)
    }

    @Test("Two channels resolving to the same port yield one card, not two")
    func duplicateChannelsCollapse() {
        // Not seen on real hardware (one controller per physical port on Apple
        // Silicon), but the merge must not produce two cards for one port if it
        // ever happens: the Power Monitor keys its tabs by port.
        let result = PortPowerMerge.merge(
            smcChannels: [
                Self.liveChannel(uuid: Self.uuidA, volts: 5.1, amps: 1.5),
                SMCPortPowerChannel(channel: 2, present: true, volts: 9.0, amps: 2.0, uuid: Self.uuidB),
            ],
            uuidMap: [Self.uuidA: "2/1", Self.uuidB: "2/1"],
            powerOutDetailSamples: [],
            contractedSamples: []
        )

        #expect(result.displaySamples.count == 1)
        #expect(result.displaySamples[0].watts == 7_650, "the first resolving channel wins")
        #expect(result.perPortMeteringSupported)
    }

    // MARK: - smcSample conversion

    @Test("smcSample converts volts/amps to mV/mA/mW and derives the port number")
    func smcSampleConversion() {
        let sample = PortPowerMerge.smcSample(
            channel: SMCPortPowerChannel(channel: 3, present: true, volts: 20.0, amps: 4.25, uuid: Self.uuidA),
            portKey: "17/2"
        )

        #expect(sample.configuredVoltage == 20_000)
        #expect(sample.current == 4_250)
        #expect(sample.watts == 85_000)
        #expect(sample.portIndex == 2, "the port number comes from the key's second component")
        #expect(sample.portKey == "17/2")
        #expect(sample.isSMCMeasured)
        #expect(sample.adapterVoltage == 0,
            "no adapter voltage is what keeps SMC samples out of the resistance regression")
    }
}
