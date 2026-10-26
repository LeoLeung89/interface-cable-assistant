import Foundation
import Testing
@testable import WhatCableCore

@Suite("PortControllerInfo content-join")
struct PowerControllerPortJoinTests {

    /// A power source with a winning contract of `winningWatts` mW on the given
    /// port. `id` lets two sources share a port (USB-PD + Brick ID).
    private func source(port: Int, type: Int = 2, winningWatts: Int?, id: UInt64? = nil, name: String = "USB-PD") -> PowerSource {
        PowerSource(
            id: id ?? UInt64(port),
            name: name,
            parentPortType: type,
            parentPortNumber: port,
            options: [],
            winning: winningWatts.map { PowerOption(voltageMV: 20000, maxCurrentMA: 5000, maxPowerMW: $0) }
        )
    }

    @Test("Charger item maps to the source's port regardless of array position")
    func orderIndependent() {
        let sources = [source(port: 4, winningWatts: 100_000)]

        // Charger at array index 2 (the live-repro layout).
        let atIndex2 = PowerControllerPortJoin.portKeysByContent(
            controllerMaxPowerMW: [0, 0, 100_000, 0], sources: sources)
        #expect(atIndex2 == [2: "2/4"])

        // Shuffle: same charger at index 0. The key must still be 2/4.
        let atIndex0 = PowerControllerPortJoin.portKeysByContent(
            controllerMaxPowerMW: [100_000, 0, 0], sources: sources)
        #expect(atIndex0 == [0: "2/4"])
    }

    @Test("Two different ports at the same wattage are ambiguous: item omitted")
    func ambiguousAcrossPortsOmitted() {
        let sources = [
            source(port: 4, winningWatts: 100_000),
            source(port: 1, winningWatts: 100_000),
        ]
        let map = PowerControllerPortJoin.portKeysByContent(
            controllerMaxPowerMW: [100_000], sources: sources)
        #expect(map.isEmpty)
    }

    @Test("Two sources on the SAME port at one wattage still map (one distinct port)")
    func sameWattageSamePortMaps() {
        let sources = [
            source(port: 4, winningWatts: 100_000, id: 1, name: "USB-PD"),
            source(port: 4, winningWatts: 100_000, id: 2, name: "Brick ID"),
        ]
        let map = PowerControllerPortJoin.portKeysByContent(
            controllerMaxPowerMW: [100_000], sources: sources)
        #expect(map == [0: "2/4"])
    }

    @Test("No power source means no mapping (never guess)")
    func noSourceNoMapping() {
        let map = PowerControllerPortJoin.portKeysByContent(
            controllerMaxPowerMW: [100_000], sources: [])
        #expect(map.isEmpty)
    }

    @Test("Zero-watt items are ignored")
    func zeroWattItemsIgnored() {
        let sources = [source(port: 4, winningWatts: 100_000)]
        let map = PowerControllerPortJoin.portKeysByContent(
            controllerMaxPowerMW: [0, 0], sources: sources)
        #expect(map.isEmpty)
    }

    @Test("Watts match within tolerance, miss outside it")
    func tolerance() {
        let sources = [source(port: 4, winningWatts: 44_800)]
        // 44850 vs 44800 = 50 mW, inside the 1.5 W tolerance.
        #expect(PowerControllerPortJoin.portKeysByContent(
            controllerMaxPowerMW: [44_850], sources: sources) == [0: "2/4"])
        // 40000 vs 44800 = 4.8 W, well outside: no guess.
        #expect(PowerControllerPortJoin.portKeysByContent(
            controllerMaxPowerMW: [40_000], sources: sources).isEmpty)
    }

    @Test("A source with no winning contract is not a match target")
    func sourceWithoutWinningIgnored() {
        let sources = [source(port: 4, winningWatts: nil)]
        let map = PowerControllerPortJoin.portKeysByContent(
            controllerMaxPowerMW: [100_000], sources: sources)
        #expect(map.isEmpty)
    }
}
