import Foundation
import Testing
import WhatCableCore
@testable import WhatCable

/// issue #181 test matrix item 4, second half: the OTHER widget builder.
///
/// `WidgetSnapshot.init(from:)` (covered in
/// `USB3CorroborationWidgetTests`) is what the widget process itself
/// calls. This one is `WidgetDataWriter`'s builder in the app process,
/// which writes the App Group cache the widget falls back to. The two are
/// independent code paths that must agree, so a fix proven in one says
/// nothing about the other.
///
/// The writer's build loop is driven by live IOKit watchers and can't be
/// constructed in a test, so this exercises the pure seam it uses to
/// decide what reaches corroboration, `WidgetDataWriter.deviceInputs`,
/// plus the `PortSummary` call it feeds. That pairing IS the writer's
/// gating behaviour; nothing here reimplements it.
///
/// What could actually go wrong and what this catches: `deviceInputs`
/// returns two lists on purpose, `attributed` (native + Thunderbolt
/// tunnelled, for liveness and device counts) and `matched` (native only,
/// for speed corroboration). Feeding the wrong one to `PortSummary` would
/// let a device behind a dock corroborate a native port's phantom USB3
/// reading, which is the bug this whole PR exists to prevent.
@Suite("USB3 corroboration: widget writer inputs (issue #181)")
struct USB3CorroborationWriterInputsTests {

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

    private func transientTransport() -> USB3Transport {
        USB3Transport(
            id: 500, portKey: "2/1", signaling: 2,
            signalingDescription: "Gen 2", dataRole: "host",
            transportRestricted: false
        )
    }

    private func nativeSuperSpeedDevice() -> USBDevice {
        USBDevice(
            id: 9300, locationID: 0x0020_0000,
            vendorID: 0x1234, productID: 0x5678,
            vendorName: nil, productName: "Test SSD", serialNumber: nil,
            usbVersion: nil, speedRaw: 3,
            busPowerMA: nil, currentMA: nil,
            controllerPortName: "Port-USB-C@1",
            rawProperties: [:]
        )
    }

    /// Renders the writer's gating decision the way the writer does:
    /// its own device seam, then PortSummary.
    private func writerBadge(devices: [USBDevice]) -> LinkSpeed? {
        let p = port()
        let inputs = WidgetDataWriter.deviceInputs(
            for: p, devices: devices, thunderboltSwitches: []
        )
        return PortSummary(
            port: p,
            devices: inputs.matched,
            usb3Transports: [transientTransport()]
        ).linkSpeed
    }

    @Test("Writer path: no speed badge for the uncorroborated transient handshake")
    func writerBadgeAbsentForTransient() {
        #expect(writerBadge(devices: []) == nil,
            "the App Group cache the widget falls back to must not carry a phantom badge")
    }

    @Test("Writer path: a corroborated native SuperSpeed device still gets its badge")
    func writerBadgePresentWhenCorroborated() {
        #expect(writerBadge(devices: [nativeSuperSpeedDevice()]) != nil,
            "a real SuperSpeed device must still light the badge on the writer path")
    }

    @Test("Writer path: the two states genuinely differ, so the suppression test isn't vacuous")
    func writerStatesDiffer() {
        #expect(writerBadge(devices: []) != writerBadge(devices: [nativeSuperSpeedDevice()]),
            "gated and corroborated writer output must differ, or the suppression assertion proves nothing")
    }

    /// A host root switch whose lane port sits on socket 1, i.e. this
    /// port's own socket, naming `acio1` (so the structural join derives
    /// `apciec1` as the tunnel root for devices arriving on this port).
    private func hostRootOnSocket1() -> IOThunderboltSwitch {
        IOThunderboltSwitch(
            id: 100, className: "IOThunderboltSwitchType5", vendorID: 0x5AC,
            vendorName: "Apple Inc.", modelName: "Mac", routerID: 0, depth: 0,
            routeString: 0, upstreamPortNumber: 7, maxPortNumber: 7,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE),
            ports: [
                IOThunderboltPort(
                    portNumber: 1, socketID: "1", adapterType: .lane,
                    currentSpeed: .usb4Tb4, currentWidth: LinkWidth(rawValue: 0x2),
                    targetWidth: nil, rawTargetSpeed: nil, linkBandwidthRaw: nil,
                    hopTable: []
                )
            ],
            parentSwitchUID: nil, acioRootName: "acio1"
        )
    }

    /// A SuperSpeed device that reached the Mac through this port's own
    /// Thunderbolt tunnel: behind a dock, structurally scoped to this port.
    private func tunnelledSuperSpeedDevice() -> USBDevice {
        USBDevice(
            id: 9301, locationID: 0x0310_0000,
            vendorID: 0x1234, productID: 0x9999,
            vendorName: nil, productName: "Device behind a dock",
            serialNumber: nil,
            usbVersion: nil, speedRaw: 3,
            busPowerMA: nil, currentMA: nil,
            controllerPortName: nil,
            isThunderboltTunnelled: true,
            tunnelBridgeDepth: 2,
            tunnelRootName: "apciec1",
            tunnelCarrier: .usbTunnel,
            rawProperties: [:]
        )
    }

    @Test("Writer path: PortSummary is fed native matches only, never the tunnelled union")
    func writerFeedsNativeMatchesOnly() {
        // A Thunderbolt-tunnelled SuperSpeed device (behind a dock) must
        // land in `attributed` (so the widget's device count and liveness
        // see it) but NOT in `matched` (so it cannot corroborate this
        // port's own native USB3 reading, which is bus-local).
        //
        // The switches argument is load-bearing and the first version of
        // this test omitted it. Without a host root the structural join
        // fails closed, the device lands in NEITHER list, and every
        // assertion below passes for the wrong reason: swapping `matched`
        // for `attributed` in the writer (the exact regression this guards)
        // went undetected. Hence the explicit precondition first.
        let tunnelled = tunnelledSuperSpeedDevice()
        let inputs = WidgetDataWriter.deviceInputs(
            for: port(), devices: [tunnelled], thunderboltSwitches: [hostRootOnSocket1()]
        )

        #expect(inputs.attributed.contains { $0.id == 9301 },
            "PRECONDITION: the tunnelled device must be structurally scoped to this port, or this test proves nothing")
        #expect(inputs.matched.contains { $0.id == 9301 } == false,
            "a tunnelled device must not reach speed corroboration, got: \(inputs.matched.map(\.id))")

        let badge = PortSummary(
            port: port(),
            devices: inputs.matched,
            usb3Transports: [transientTransport()]
        ).linkSpeed
        #expect(badge == nil,
            "a device behind a dock must not corroborate this port's phantom USB3 reading, got: \(String(describing: badge))")
    }
}
