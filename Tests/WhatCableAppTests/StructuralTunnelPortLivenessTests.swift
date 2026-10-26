import Testing
import WhatCableCore
@testable import WhatCable

/// Regression for the "Hide empty ports" vanishing-devices bug (review
/// finding, structural tunnel join follow-up): a port whose ONLY connected
/// devices are structurally-scoped tunnelled ones (behind a dock or display,
/// via `TunnelledDeviceGrouping.structurallyScopedTunnelledDevices`) carries
/// nothing in `AppleHPMInterface.matchingDevices` (that join explicitly
/// excludes anything `isThunderboltTunnelled`). With `connectionActive` false
/// or lagging and no native devices, `isPortLive` used to say "dead", and
/// "Hide empty ports" removed the whole card, taking every structurally
/// attributed device with it: a dock full of devices disappeared entirely.
///
/// This exercises the real wiring end to end: `ContentView
/// .structurallyScopedTunnelledDevices` (the same static helper `body` calls)
/// feeding `WhatCableCore.isPortLive`'s new `hasStructurallyScopedTunnelledDevices`
/// parameter, not a reimplementation of either.
@Suite("Structural tunnel port liveness (Hide empty ports)")
struct StructuralTunnelPortLivenessTests {

    // MARK: - Fixtures

    private func makePort(serviceName: String, portNumber: Int, connectionActive: Bool) -> AppleHPMInterface {
        AppleHPMInterface(
            id: UInt64(portNumber),
            serviceName: serviceName,
            className: "AppleHPMInterfaceType10",
            portDescription: nil,
            portTypeDescription: "USB-C",
            portNumber: portNumber,
            connectionActive: connectionActive,
            activeCable: nil,
            opticalCable: nil,
            usbActive: nil,
            superSpeedActive: nil,
            usbModeType: nil,
            usbConnectString: nil,
            transportsSupported: ["CC", "USB2", "USB3", "CIO"],
            transportsActive: connectionActive ? ["CC", "USB3", "CIO"] : [],
            transportsProvisioned: [],
            plugOrientation: nil,
            plugEventCount: nil,
            connectionCount: nil,
            overcurrentCount: nil,
            pinConfiguration: [:],
            powerCurrentLimits: [],
            firmwareVersion: nil,
            bootFlagsHex: nil,
            rawProperties: [:]
        )
    }

    private func lanePort(socketID: String, hopTable: [HopTableEntry]) -> IOThunderboltPort {
        IOThunderboltPort(
            portNumber: 1, socketID: socketID, adapterType: .lane, currentSpeed: .usb4Tb4,
            currentWidth: LinkWidth(rawValue: 0x2), targetWidth: nil, rawTargetSpeed: nil,
            linkBandwidthRaw: nil, hopTable: hopTable
        )
    }

    private func usbProtocolPort(portNumber: Int, hopTable: [HopTableEntry]) -> IOThunderboltPort {
        IOThunderboltPort(
            portNumber: portNumber, socketID: nil, adapterType: .usb3Down, currentSpeed: nil,
            currentWidth: nil, targetWidth: nil, rawTargetSpeed: nil, linkBandwidthRaw: nil,
            hopTable: hopTable
        )
    }

    private func hopEntry(pathUUID: String) -> HopTableEntry {
        HopTableEntry(counter: 0, hopID: 8, dstHopID: 8, dstPort: 1, pathUUID: pathUUID)
    }

    private func hostRootSwitch(id: Int64, ports: [IOThunderboltPort], acioRootName: String?) -> IOThunderboltSwitch {
        IOThunderboltSwitch(
            id: id, className: "IOThunderboltSwitchType5", vendorID: 0x5AC, vendorName: "Apple Inc.",
            modelName: "Mac", routerID: 0, depth: 0, routeString: 0, upstreamPortNumber: 7,
            maxPortNumber: 7, supportedSpeed: SupportedSpeedMask(rawValue: 0xE), ports: ports,
            parentSwitchUID: nil, acioRootName: acioRootName
        )
    }

    private func downstreamSwitch(id: Int64, parent: Int64, depth: Int, model: String, ports: [IOThunderboltPort]) -> IOThunderboltSwitch {
        IOThunderboltSwitch(
            id: id, className: "IOThunderboltSwitchType3", vendorID: 0x2109, vendorName: "LaCie",
            modelName: model, routerID: depth, depth: depth, routeString: Int64(depth),
            upstreamPortNumber: 1, maxPortNumber: 13, supportedSpeed: SupportedSpeedMask(rawValue: 0xE),
            ports: ports, parentSwitchUID: parent
        )
    }

    private func tunnelledDevice(id: UInt64, locationID: UInt32, bridgeDepth: Int, tunnelRootName: String) -> USBDevice {
        USBDevice(
            id: id, locationID: locationID, vendorID: 0x05AC, productID: 0x1234, vendorName: nil,
            productName: nil, serialNumber: nil, usbVersion: nil, speedRaw: 3, busPowerMA: nil,
            currentMA: nil, isThunderboltTunnelled: true, tunnelBridgeDepth: bridgeDepth,
            tunnelRootName: tunnelRootName, deviceClass: 0x00, rawProperties: [:]
        )
    }

    // MARK: - The regression

    @Test("hideEmptyPorts=true, connectionActive=false, structurally scoped devices present: the port is NOT filtered out")
    func structurallyScopedPortSurvivesHideEmptyPorts() {
        let uuidUSB = "AAAAAAAA-0000-0000-0000-00000000AAAA"
        let root = hostRootSwitch(
            id: 100,
            ports: [lanePort(socketID: "3", hopTable: [hopEntry(pathUUID: uuidUSB)])],
            acioRootName: "acio2"
        )
        let laCie = downstreamSwitch(
            id: 200, parent: 100, depth: 1, model: "1big Dock v2",
            ports: [usbProtocolPort(portNumber: 5, hopTable: [hopEntry(pathUUID: uuidUSB)])]
        )
        let switches = [root, laCie]

        // The port itself reports NOT connected/active: a lagging or stale
        // AppleHPMInterface read, the exact shape the bug needs.
        let port = makePort(serviceName: "Port-USB-C@3", portNumber: 3, connectionActive: false)

        // A tunnelled device behind the dock, structurally scoped to THIS
        // port. Its own product name is nil (an unnamed hub persona, exactly
        // the case a name match cannot place either), so nothing but the
        // structural join can attribute it anywhere.
        let device = tunnelledDevice(id: 1, locationID: 0x0310_0000, bridgeDepth: 2, tunnelRootName: "apciec2")

        let scoping = ContentView.structurallyScopedTunnelledDevices(
            ports: [port], devices: [device], thunderboltSwitches: switches
        )
        let scopedForThisPort = scoping.byPort[port.serviceName] ?? []
        #expect(scopedForThisPort.map(\.id) == [1], "the device must structurally scope to this port")

        // The exact liveness call `ContentView`'s `visiblePorts` filter makes
        // when "Hide empty ports" is on: no power sources, no PD identities,
        // no natively-matched devices (matchingDevices excludes tunnelled
        // devices by construction), connectionActive false, no charger.
        let isLive = isPortLive(
            port: port,
            powerSources: [],
            identities: [],
            matchingDevices: [],
            chargerAttached: false,
            hasStructurallyScopedTunnelledDevices: !scopedForThisPort.isEmpty
        )
        #expect(isLive, "a port carrying structurally attributed devices must not read as empty")
    }

    @Test("A port with NO structurally scoped devices and no other signal is still correctly filtered out")
    func portWithNothingStaysFilteredOut() {
        // Same shape, but with no tunnelled device at all: confirms the fix
        // does not make every port unconditionally live.
        let root = hostRootSwitch(id: 100, ports: [lanePort(socketID: "3", hopTable: [])], acioRootName: "acio2")
        let port = makePort(serviceName: "Port-USB-C@3", portNumber: 3, connectionActive: false)

        let scoping = ContentView.structurallyScopedTunnelledDevices(
            ports: [port], devices: [], thunderboltSwitches: [root]
        )
        let scopedForThisPort = scoping.byPort[port.serviceName] ?? []
        #expect(scopedForThisPort.isEmpty)

        let isLive = isPortLive(
            port: port, powerSources: [], identities: [], matchingDevices: [],
            chargerAttached: false, hasStructurallyScopedTunnelledDevices: !scopedForThisPort.isEmpty
        )
        #expect(!isLive, "an actually-empty port must still be filtered out")
    }
}
