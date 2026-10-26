import Foundation
import Testing
@testable import WhatCableCore

/// issue #181 test matrix item 4 ("Widget path"): the USB3 corroboration
/// gate must hold in the WIDGET, not just in the app.
///
/// This is not a formality. The widget is a SEPARATE PROCESS that does its
/// own live IOKit reads on every timeline refresh, so an app-side gate does
/// not automatically reach it (the same lesson the PCIe attribution work
/// learned the hard way: prove it, don't assume it). The widget builds its
/// entries through `WidgetSnapshot.init(from: CableSnapshot)`, which is what
/// `CableTimelineProvider` calls; if that builder failed to hand PortSummary
/// the port's devices or its USB3 transports, the transient "10 Gbps" flash
/// would live on in the widget after being fixed everywhere else.
///
/// The design note claims the widget "inherits" the gate via PortSummary.
/// These tests are what makes that a measured fact rather than a claim.
@Suite("USB3 corroboration: widget path (issue #181)")
struct USB3CorroborationWidgetTests {

    // MARK: - Fixtures (mirrors USB3TransientReproTests, same handshake state)

    private func port() -> AppleHPMInterface {
        AppleHPMInterface(
            id: 1,
            serviceName: "Port-USB-C@1",
            className: "AppleHPMInterfaceType10",
            portDescription: "Port-USB-C@1",
            portTypeDescription: "USB-C",
            portNumber: 1,
            connectionActive: true,
            activeCable: nil,
            opticalCable: nil,
            usbActive: nil,
            superSpeedActive: nil,
            usbModeType: nil,
            usbConnectString: nil,
            transportsSupported: ["CC", "USB2", "USB3"],
            transportsActive: ["USB3"],
            transportsProvisioned: [],
            plugOrientation: nil,
            plugEventCount: nil,
            connectionCount: nil,
            overcurrentCount: nil,
            pinConfiguration: [:],
            powerCurrentLimits: [],
            firmwareVersion: nil,
            bootFlagsHex: nil,
            rawProperties: ["PortType": "2"]
        )
    }

    /// Mid-handshake: signaling present, TRM clear, nothing restricted.
    private func transientTransport() -> USB3Transport {
        USB3Transport(
            id: 500, portKey: "2/1", signaling: 2,
            signalingDescription: "Gen 2", dataRole: "host",
            transportRestricted: false
        )
    }

    /// A root SuperSpeed device: the corroborating signal.
    ///
    /// `controllerPortName` is set on purpose. Unlike the PortSummary tests,
    /// which hand PortSummary a pre-scoped device list, the widget builder
    /// does its OWN device-to-port join first
    /// (`AppleHPMInterface.matchingDevices(from:)`), so a device with no
    /// `UsbIOPort` name never reaches corroboration at all. Writing this
    /// test caught exactly that: the first version of the fixture omitted
    /// the name and the "corroborated" case produced no badge, which looked
    /// like a gate bug and was really an unjoinable fixture. Keeping the
    /// real join in the path is the point of testing the builder rather
    /// than PortSummary twice.
    private func superSpeedDevice() -> USBDevice {
        USBDevice(
            id: 9200, locationID: 0x0020_0000,
            vendorID: 0x1234, productID: 0x5678,
            vendorName: nil, productName: "Test SSD", serialNumber: nil,
            usbVersion: nil, speedRaw: 3,
            busPowerMA: nil, currentMA: nil,
            controllerPortName: "Port-USB-C@1",
            rawProperties: [:]
        )
    }

    private func snapshot(devices: [USBDevice]) -> CableSnapshot {
        CableSnapshot(
            ports: [port()],
            powerSources: [],
            identities: [],
            usbDevices: devices,
            adapter: nil,
            usb3Transports: [transientTransport()]
        )
    }

    private func entry(devices: [USBDevice]) -> WidgetSnapshot.PortEntry? {
        WidgetSnapshot(from: snapshot(devices: devices)).ports.first
    }

    // MARK: - The gate holds in the widget

    @Test("Widget builder: no speed badge for the uncorroborated transient handshake")
    func widgetBadgeAbsentForTransient() throws {
        let e = try #require(entry(devices: []), "widget builder produced no port entry")
        #expect(e.linkSpeed == nil,
            "the widget must not flash a speed badge mid-handshake, got: \(String(describing: e.linkSpeed))")
    }

    @Test("Widget builder: no USB3 speed text anywhere in the entry for the transient handshake")
    func widgetTextCleanForTransient() throws {
        let e = try #require(entry(devices: []), "widget builder produced no port entry")
        // Every text field the widget can render, not just the one the
        // small widget happens to show today: a layout change must not
        // reintroduce the flash through a field nobody was checking.
        let text = [e.headline, e.subtitle, e.topBullet].compactMap { $0 }.joined(separator: " | ")
        #expect(text.contains("USB 3.2") == false && text.contains("SuperSpeed") == false,
            "no USB3 speed text may appear mid-handshake, got: \(text)")
    }

    // MARK: - ... and only suppresses the phantom, not the real thing

    @Test("Widget builder: a corroborated SuperSpeed device still gets its badge")
    func widgetBadgePresentWhenCorroborated() throws {
        let e = try #require(entry(devices: [superSpeedDevice()]), "widget builder produced no port entry")
        #expect(e.linkSpeed != nil,
            "a real SuperSpeed device must still light the widget badge; the gate suppresses the phantom, not the link")
    }

    @Test("Widget builder: the two states genuinely differ, so the suppression tests aren't vacuous")
    func widgetStatesDiffer() throws {
        // Guards the whole suite: if the fixture ever stopped producing a
        // badge in EITHER state (a builder change that drops linkSpeed, say),
        // the suppression tests above would pass while proving nothing.
        let transient = try #require(entry(devices: []))
        let corroborated = try #require(entry(devices: [superSpeedDevice()]))
        #expect(transient.linkSpeed != corroborated.linkSpeed,
            "the gated and corroborated widget entries must differ, or the suppression assertions prove nothing")
    }
}
