import Foundation
import Testing
@testable import WhatCableCore

// MARK: - The SMC charging contract, and the five gates in front of it
//
// This is the fix for public issue 491: an M1 Pro charging at 100 W whose
// per-port card spun "waiting for power telemetry" forever, because that
// silicon publishes no USB-C power-source node and the existing fallback needs
// a PDO list its macOS does not ship.
//
// It is also the one piece of the power-slice work that can turn a fail-closed
// bug into a fail-open one. Everything else showed a spinner or showed nothing;
// this puts a number on a card. So the gates get a test each, with the
// deliberately awkward cases (a dock on another port, MagSafe, a channel that
// is sourcing rather than receiving) spelled out rather than assumed away.
@Suite("SMC charging contract synthesis")
struct SMCContractSynthesisTests {

    // MARK: - Fixtures

    private static let uuidA = "aaaaaaaabbbbccccddddeeeeeeeeeeee"
    private static let uuidB = "11111111222233334444555555555555"

    /// The reporter's own contract from issue 491: 100 W at 20 V, 5 A.
    private static func contract(
        channel: Int = 2,
        uuid: String = uuidA,
        powerMW: Int = 100_000,
        voltageMV: Int = 20_000,
        currentMA: Int = 5_000,
        label: String = "pd charger"
    ) -> SMCPortContract {
        SMCPortContract(channel: channel, uuid: uuid, powerMW: powerMW,
                        voltageMV: voltageMV, currentMA: currentMA, label: label)
    }

    private static func port(
        number: Int = 2,
        magSafe: Bool = false,
        connected: Bool = true,
        uuid: String? = uuidA
    ) -> AppleHPMInterface {
        let description = magSafe ? "MagSafe 3" : "USB-C"
        return AppleHPMInterface(
            id: UInt64(number), serviceName: "Port-\(description)@\(number)",
            className: "AppleHPMInterfaceType10",
            portDescription: "Port-\(description)@\(number)",
            portTypeDescription: description, portNumber: number,
            connectionActive: connected, activeCable: nil, opticalCable: nil,
            usbActive: nil, superSpeedActive: nil, usbModeType: nil, usbConnectString: nil,
            transportsSupported: [], transportsActive: [], transportsProvisioned: [],
            plugOrientation: nil, plugEventCount: nil, connectionCount: nil, overcurrentCount: nil,
            pinConfiguration: [:], powerCurrentLimits: [], firmwareVersion: nil, bootFlagsHex: nil,
            hpmControllerUUID: uuid,
            rawProperties: ["PortType": magSafe ? "17" : "2"]
        )
    }

    private static func realSource(portType: Int = 2, portNumber: Int = 1, watts: Int) -> PowerSource {
        let option = PowerOption(voltageMV: 20_000, maxCurrentMA: watts / 20, maxPowerMW: watts)
        return PowerSource(
            id: 99, name: "USB-PD", parentPortType: portType, parentPortNumber: portNumber,
            options: [option], winning: watts > 0 ? option : nil
        )
    }

    private static func synthesize(
        contracts: [SMCPortContract]? = nil,
        uuidMap: [String: String]? = nil,
        ports: [AppleHPMInterface]? = nil,
        realSources: [PowerSource] = [],
        externalConnected: Bool = true,
        enabled: Bool = true
    ) -> PowerSource? {
        // `enabled` is passed explicitly rather than read from the global, so
        // the switch-off test below cannot race the rest of the suite.
        SMCContractSynthesis.synthesizedSource(
            contracts: contracts ?? [contract()],
            uuidMap: uuidMap ?? [uuidA: "2/2"],
            ports: ports ?? [port()],
            realSources: realSources,
            externalConnected: externalConnected,
            enabled: enabled
        )
    }

    // MARK: - The case this exists for

    @Test("The reporter's machine gets its 100 W contract onto the right port")
    func reportersCaseResolves() {
        let source = Self.synthesize()

        #expect(source != nil, "an M1 Pro charging at 100 W must stop showing a spinner")
        #expect(source?.winning?.maxPowerMW == 100_000)
        #expect(source?.winning?.voltageMV == 20_000)
        #expect(source?.winning?.maxCurrentMA == 5_000)
        // The port comes from the UUID join, never from the channel index: this
        // is channel D2 landing on USB-C 2 because the UUID says so, and it
        // would land on USB-C 4 just as happily if the map said that.
        #expect(source?.portKey == "2/2")
        #expect(source?.isSynthesized == true, "it must be distinguishable from a real node")
    }

    @Test("The channel index is not the port number")
    func channelIndexIsNotThePortNumber() {
        // D2 mapped to port 4. A version of this that trusted the index would
        // put a 100 W charge on the wrong card, which is the misattribution
        // class this whole slice exists to close.
        let source = Self.synthesize(
            uuidMap: [Self.uuidA: "2/4"],
            ports: [Self.port(number: 4)]
        )
        #expect(source?.portKey == "2/4")
    }

    // MARK: - The five gates, one at a time

    @Test("Gate 1: nothing is synthesized when the Mac is not externally powered")
    func gateExternalPower() {
        #expect(Self.synthesize(externalConnected: false) == nil)
    }

    @Test("Gate 2: a channel whose UUID resolves to no port is ignored")
    func gateUUIDJoin() {
        // An empty map is the M1/M2-without-UUID and Mac Pro case. Guessing a
        // positional mapping here is exactly what must not happen.
        #expect(Self.synthesize(uuidMap: [:]) == nil)
        #expect(Self.synthesize(uuidMap: [Self.uuidB: "2/2"]) == nil)
    }

    @Test("Gate 3: an implausible contract is ignored")
    func gatePlausibility() {
        #expect(Self.synthesize(contracts: [Self.contract(powerMW: 0)]) == nil)
        // Below the 5 V floor every USB-C contract starts at: a
        // partially-populated channel, not a charger.
        #expect(Self.synthesize(contracts: [Self.contract(voltageMV: 4_000)]) == nil)
        // The floor itself passes.
        #expect(Self.synthesize(contracts: [Self.contract(voltageMV: 5_000)]) != nil)
    }

    @Test("Gate 4: a channel sourcing power to a peripheral is not an incoming charge")
    func gateOutgoingLabel() {
        #expect(Self.synthesize(contracts: [Self.contract(label: "usb host")]) == nil)
        #expect(Self.synthesize(contracts: [Self.contract(label: "USB Host")]) == nil)
        // An empty label is NOT a rejection: 153 channels in the corpus carry a
        // genuine 20 V charger contract with no label at all, so absence proves
        // nothing and treating it as proof would re-break the reporter's case.
        #expect(Self.synthesize(contracts: [Self.contract(label: "")]) != nil)
    }

    @Test("Gate 5: macOS's own answer always wins, wherever it is")
    func gateRealContractAnywhere() {
        // THE IMPORTANT ONE. An M1 Pro charging on MagSafe with a dock plugged
        // into a USB-C port: the dock's SMC contract must not be shown as
        // though the Mac were charging from it. The winning contract is on a
        // DIFFERENT port, which is why this gate is cross-port and not
        // per-port.
        let magSafeCharging = Self.realSource(portType: 17, portNumber: 1, watts: 96_000)
        #expect(Self.synthesize(realSources: [magSafeCharging]) == nil,
            "a real winning contract anywhere means macOS has answered")

        // A real source with no winning contract still does not block: that is
        // the "port has a node but nothing negotiated" case, which is not an
        // answer. It is blocked per-port instead, below.
        let idleElsewhere = Self.realSource(portType: 2, portNumber: 1, watts: 0)
        #expect(Self.synthesize(realSources: [idleElsewhere]) != nil)
    }

    @Test("A port macOS already describes is left alone, contract or not")
    func realSourceOnTheSamePortBlocks() {
        // Even with no winning contract, if macOS publishes a node for THIS
        // port then macOS is describing it and we do not talk over it.
        let sameIdlePort = Self.realSource(portType: 2, portNumber: 2, watts: 0)
        #expect(Self.synthesize(realSources: [sameIdlePort]) == nil)
    }

    // MARK: - Shapes that must never produce a contract

    @Test("MagSafe is never synthesized from the SMC")
    func magSafeNeverSynthesized() {
        // 105 MagSafe contracts in the corpus come from the node and 0 from the
        // SMC, so a MagSafe match here would be a join error rather than a
        // discovery, and it would put an incoming charge on a connector whose
        // real contract lives somewhere else entirely.
        let source = Self.synthesize(
            uuidMap: [Self.uuidA: "17/1"],
            ports: [Self.port(number: 1, magSafe: true)]
        )
        #expect(source == nil)
    }

    @Test("A disconnected port is not charging")
    func disconnectedPortIsNotCharging() {
        #expect(Self.synthesize(ports: [Self.port(connected: false)]) == nil)
    }

    @Test("Two candidate channels produce silence, not a guess")
    func ambiguityProducesSilence() {
        // Naming the wrong port is worse than naming none.
        let source = Self.synthesize(
            contracts: [Self.contract(channel: 1, uuid: Self.uuidA), Self.contract(channel: 2, uuid: Self.uuidB)],
            uuidMap: [Self.uuidA: "2/1", Self.uuidB: "2/2"],
            ports: [Self.port(number: 1, uuid: Self.uuidA), Self.port(number: 2, uuid: Self.uuidB)]
        )
        #expect(source == nil)
    }

    // MARK: - The rollback lever

    @Test("The switch returns every affected port to its previous no-data state")
    func rollbackSwitch() {
        // Passed as an argument, not by mutating the global. The first version
        // of this test did mutate it, and since swift-testing runs tests in
        // parallel it turned the switch off underneath its own siblings: a gate
        // test failed and looked for all the world like a logic bug.
        #expect(Self.synthesize(enabled: false) == nil,
            "with the switch off, the reporter's case must go back to showing nothing")
        #expect(Self.synthesize(enabled: true) != nil,
            "and back on again, so the test is not passing for some other reason")
        #expect(SMCContractSynthesis.isEnabled,
            "the shipped default must be on, or the fix does nothing")
    }
}
