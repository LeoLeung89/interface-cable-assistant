import Foundation
import Testing
@testable import WhatCableCore

struct PowerMonitorSnapshotCodableTests {

    @Test("Round-trips with the per-port metering capability bit")
    func roundTripsCapabilityBit() throws {
        let snapshot = PowerMonitorSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            systemSample: PowerSample(timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                                      systemVoltageIn: 5000, systemCurrentIn: 1000, systemPowerIn: 5000),
            portSamples: [],
            resistanceEstimate: nil,
            perPortMeteringSupported: true
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(PowerMonitorSnapshot.self, from: data)
        #expect(decoded.perPortMeteringSupported)
        #expect(decoded == snapshot)
    }

    @Test("Decodes a legacy snapshot missing newer keys without throwing")
    func decodesLegacyJSONWithDefaults() throws {
        // A snapshot as an older build would have encoded it: no perPortMetering
        // Supported, no hasContract, no battery fields. Must default, not throw.
        let legacy = """
        {
            "timestamp": 1700000000,
            "systemSample": { "timestamp": 1700000000, "systemVoltageIn": 0, "systemCurrentIn": 0, "systemPowerIn": 0 },
            "portSamples": []
        }
        """
        let decoded = try JSONDecoder().decode(PowerMonitorSnapshot.self, from: Data(legacy.utf8))
        #expect(decoded.perPortMeteringSupported == false)
        #expect(decoded.hasContract == false)
        #expect(decoded.externalConnected == true)   // desktop-friendly default
        #expect(decoded.batteryInstalled == false)
    }

    // MARK: - chargerAttached and the shared stale-contract gate

    @Test("externalPowerAbsent is true when either signal says no external power")
    func externalPowerAbsentTruthTable() {
        // The two signals clear at different speeds after an unplug, and either
        // one is sufficient. This is the whole rule, in one place, so a surface
        // cannot quietly apply half of it the way the widget contributor used to.
        func snapshot(externalConnected: Bool, batteryInstalled: Bool, chargerAttached: Bool) -> PowerMonitorSnapshot {
            PowerMonitorSnapshot(
                timestamp: Date(),
                systemSample: PowerSample(timestamp: Date(), systemVoltageIn: 0, systemCurrentIn: 0, systemPowerIn: 0),
                portSamples: [],
                resistanceEstimate: nil,
                externalConnected: externalConnected,
                batteryInstalled: batteryInstalled,
                chargerAttached: chargerAttached
            )
        }

        // Plugged in, both signals agree: show the contract.
        #expect(snapshot(externalConnected: true, batteryInstalled: true, chargerAttached: true).externalPowerAbsent == false)
        // The unplug window: adapter gone, ExternalConnected still lagging.
        #expect(snapshot(externalConnected: true, batteryInstalled: true, chargerAttached: false).externalPowerAbsent)
        // Fully on battery, both agree.
        #expect(snapshot(externalConnected: false, batteryInstalled: true, chargerAttached: false).externalPowerAbsent)
        // ExternalConnected cleared first, adapter still reported.
        #expect(snapshot(externalConnected: false, batteryInstalled: true, chargerAttached: true).externalPowerAbsent)

        // THE DESKTOP CASE, and it is not a corner: it is every Mac mini,
        // Studio and Pro. A desktop has no battery, and
        // IOPSCopyExternalPowerAdapterDetails returns nil on one even while it
        // is happily running on mains, which the test kit's own probe 39 states
        // in its header. So chargerAttached reads FALSE on every desktop, and a
        // gate of `onBattery || !chargerAttached` would be permanently true
        // there and blank every contract card.
        //
        // The first version of this commit shipped exactly that. These four
        // rows are the regression test.
        #expect(snapshot(externalConnected: true, batteryInstalled: false, chargerAttached: false).externalPowerAbsent == false)
        #expect(snapshot(externalConnected: false, batteryInstalled: false, chargerAttached: false).externalPowerAbsent == false)
        #expect(snapshot(externalConnected: true, batteryInstalled: false, chargerAttached: true).externalPowerAbsent == false)
        #expect(snapshot(externalConnected: false, batteryInstalled: false, chargerAttached: true).externalPowerAbsent == false)
    }

    @Test("A snapshot written by an older build decodes as charger-attached, not charger-absent")
    func olderSnapshotDecodesChargerAttached() throws {
        // Nothing in the app actually decodes a PowerMonitorSnapshot today (the
        // widget's cache is WidgetSnapshot; the only production encode is
        // one-way, for `whatcable --monitor-json`). This pins the conservative
        // default anyway, because the decoder exists and the wrong default
        // would make externalPowerAbsent true everywhere and suppress every
        // contract card on a plugged-in machine.
        let json = """
        {
          "timestamp": 0,
          "systemSample": {"timestamp": 0, "systemVoltageIn": 20000, "systemCurrentIn": 1000, "systemPowerIn": 20000},
          "portSamples": [],
          "externalConnected": true,
          "batteryInstalled": true
        }
        """
        let decoded = try JSONDecoder().decode(PowerMonitorSnapshot.self, from: Data(json.utf8))
        #expect(decoded.chargerAttached, "a missing chargerAttached must read as attached")
        #expect(decoded.externalPowerAbsent == false)
    }

    @Test("chargerAttached round-trips")
    func chargerAttachedRoundTrips() throws {
        for attached in [true, false] {
            let original = PowerMonitorSnapshot(
                timestamp: Date(timeIntervalSince1970: 0),
                systemSample: PowerSample(timestamp: Date(timeIntervalSince1970: 0), systemVoltageIn: 0, systemCurrentIn: 0, systemPowerIn: 0),
                portSamples: [],
                resistanceEstimate: nil,
                chargerAttached: attached
            )
            let decoded = try JSONDecoder().decode(
                PowerMonitorSnapshot.self, from: JSONEncoder().encode(original)
            )
            #expect(decoded.chargerAttached == attached)
        }
    }
}
