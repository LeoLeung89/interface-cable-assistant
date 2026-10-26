import Foundation
import Testing
@testable import WhatCableCore

/// One snapshot, three renderers: the CLI text, the CLI JSON and the widget
/// must show the SMC charge state the snapshot carries, not the lagging
/// battery record beside it.
@Suite("Battery charge state reaches every renderer")
struct BatteryChargeStatePlumbingTests {
    private func port() -> AppleHPMInterface {
        AppleHPMInterface(
            id: 1, serviceName: "Port-USB-C@1", className: "AppleHPMInterfaceType10",
            portDescription: "Port-USB-C@1", portTypeDescription: "USB-C", portNumber: 1,
            connectionActive: true, activeCable: nil, opticalCable: nil, usbActive: nil,
            superSpeedActive: nil, usbModeType: nil, usbConnectString: nil,
            transportsSupported: ["USB2"], transportsActive: [], transportsProvisioned: [],
            plugOrientation: nil, plugEventCount: nil, connectionCount: nil, overcurrentCount: nil,
            pinConfiguration: [:], powerCurrentLimits: [], firmwareVersion: nil, bootFlagsHex: nil,
            rawProperties: ["PortType": "2"])
    }

    private func source() -> PowerSource {
        let w = PowerOption(voltageMV: 20_000, maxCurrentMA: 96 * 50, maxPowerMW: 96_000)
        return PowerSource(id: 1, name: "USB-PD", parentPortType: 2, parentPortNumber: 1, options: [w], winning: w)
    }

    /// The record still says charging (stale); the SMC says running on battery.
    private func snapshot() -> CableSnapshot {
        CableSnapshot(
            ports: [port()], powerSources: [source()], identities: [], usbDevices: [],
            adapter: AdapterInfo(watts: 96, isCharging: nil, source: "AC"),
            batteryFullyCharged: false, batteryIsCharging: true, batteryChargeState: .runningOnBattery)
    }

    /// The banner only fires when the context joins the USB-PD source to the
    /// port. Fail as a join miss, not as a plumbing failure, if it doesn't.
    private func requireJoin(_ s: CableSnapshot) throws {
        let ctx = CableSnapshotContext(snapshot: s)
        try #require(!(ctx.portContexts.first?.portSources.isEmpty ?? true), "fixture source did not join the port")
    }

    @Test("CLI text shows the SMC state")
    func text() throws {
        let s = snapshot()
        try requireJoin(s)
        let out = TextFormatter.render(
            ports: s.ports, sources: s.powerSources, identities: s.identities, showRaw: false,
            adapter: s.adapter, batteryFullyCharged: s.batteryFullyCharged,
            batteryIsCharging: s.batteryIsCharging, batteryChargeState: s.batteryChargeState)
        #expect(out.contains("Plugged in, running on battery"), "\(out)")
    }

    @Test("CLI JSON shows the SMC state")
    func json() throws {
        let s = snapshot()
        try requireJoin(s)
        let out = try JSONFormatter.render(
            ports: s.ports, sources: s.powerSources, identities: s.identities, showRaw: false,
            adapter: s.adapter, batteryFullyCharged: s.batteryFullyCharged,
            batteryIsCharging: s.batteryIsCharging, batteryChargeState: s.batteryChargeState)
        #expect(out.contains("Plugged in, running on battery"), "\(out)")
    }

    @Test("Widget headline and power state use the SMC state")
    func widget() {
        let w = WidgetSnapshot(from: snapshot())
        let headline = w.ports.first?.headline ?? ""
        #expect(headline.hasPrefix("Plugged in"), "\(headline)")
        #expect(w.powerState?.isCharging == false)
        #expect(w.batteryChargeState == .runningOnBattery)
    }
}
