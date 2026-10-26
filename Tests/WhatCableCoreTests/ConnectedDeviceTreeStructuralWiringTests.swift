import Foundation
import Testing
@testable import WhatCableCore

/// End-to-end wiring tests for the structural tunnel join:
/// a tunnelled USB device whose `tunnelRootName` names THIS port's own
/// `apciecN` root (derived from the host root switch's `acioRootName`) now
/// flows into `ConnectedDeviceTree.rows` via the `tunnelledDevices` parameter
/// and nests under its chain device, instead of only ever appearing in the
/// separate flat/single-port `TunnelledDeviceGrouping` section.
///
/// Three things this file exists to prove, matching the reviewer's brief:
/// (a) the reporter's ground-truth shape renders the tunnelled devices nested
///     in the SAME "Connected devices" tree as the chain device; (b) a
///     machine with no structural fields at all (older capture) renders
///     byte-identical output, whether or not the caller passes the new
///     parameters; (c) a multi-port machine with two valid `apciecN` roots
///     scopes each port's tunnelled devices to that port ONLY.
@Suite("ConnectedDeviceTree structural tunnel wiring")
struct ConnectedDeviceTreeStructuralWiringTests {

    // MARK: - Fixtures

    private func makePort(serviceName: String, portNumber: Int) -> AppleHPMInterface {
        AppleHPMInterface(
            id: UInt64(portNumber),
            serviceName: serviceName,
            className: "AppleHPMInterfaceType10",
            portDescription: nil,
            portTypeDescription: "USB-C",
            portNumber: portNumber,
            connectionActive: true,
            activeCable: nil,
            opticalCable: nil,
            usbActive: nil,
            superSpeedActive: nil,
            usbModeType: nil,
            usbConnectString: nil,
            transportsSupported: ["CC", "USB2", "USB3", "CIO", "DisplayPort"],
            transportsActive: ["CC", "USB3", "CIO"],
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

    private func lanePort(socketID: String, hopTable: [HopTableEntry] = []) -> IOThunderboltPort {
        IOThunderboltPort(
            portNumber: 1,
            socketID: socketID,
            adapterType: .lane,
            currentSpeed: .usb4Tb4,
            currentWidth: LinkWidth(rawValue: 0x2),
            targetWidth: nil,
            rawTargetSpeed: nil,
            linkBandwidthRaw: nil,
            hopTable: hopTable
        )
    }

    private func usbProtocolPort(portNumber: Int, hopTable: [HopTableEntry]) -> IOThunderboltPort {
        IOThunderboltPort(
            portNumber: portNumber,
            socketID: nil,
            adapterType: .usb3Down,
            currentSpeed: nil,
            currentWidth: nil,
            targetWidth: nil,
            rawTargetSpeed: nil,
            linkBandwidthRaw: nil,
            hopTable: hopTable
        )
    }

    private func hopEntry(pathUUID: String) -> HopTableEntry {
        HopTableEntry(counter: 0, hopID: 8, dstHopID: 8, dstPort: 1, pathUUID: pathUUID)
    }

    private func hostRootSwitch(
        id: Int64,
        ports: [IOThunderboltPort],
        acioRootName: String?
    ) -> IOThunderboltSwitch {
        IOThunderboltSwitch(
            id: id, className: "IOThunderboltSwitchType5", vendorID: 0x5AC,
            vendorName: "Apple Inc.", modelName: "Mac", routerID: 0, depth: 0,
            routeString: 0, upstreamPortNumber: 7, maxPortNumber: 7,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE), ports: ports,
            parentSwitchUID: nil, acioRootName: acioRootName
        )
    }

    private func downstreamSwitch(
        id: Int64,
        parent: Int64,
        depth: Int,
        vendor: String,
        model: String,
        ports: [IOThunderboltPort]
    ) -> IOThunderboltSwitch {
        IOThunderboltSwitch(
            id: id, className: "IOThunderboltSwitchType3", vendorID: 0x2109,
            vendorName: vendor, modelName: model, routerID: depth, depth: depth,
            routeString: Int64(depth), upstreamPortNumber: 1, maxPortNumber: 13,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE), ports: ports,
            parentSwitchUID: parent
        )
    }

    private func tunnelledDevice(
        id: UInt64,
        locationID: UInt32,
        bridgeDepth: Int,
        tunnelRootName: String,
        product: String? = nil,
        isHub: Bool
    ) -> USBDevice {
        USBDevice(
            id: id, locationID: locationID, vendorID: 0x05AC, productID: 0x1234,
            vendorName: nil, productName: product, serialNumber: nil,
            usbVersion: nil, speedRaw: 3, busPowerMA: nil, currentMA: nil,
            isThunderboltTunnelled: true, tunnelBridgeDepth: bridgeDepth,
            tunnelRootName: tunnelRootName,
            // Models captured XHCITR ancestry; the structural join requires a
            // known carrier (nil joins nothing).
            tunnelCarrier: .usbTunnel,
            deviceClass: isHub ? 0x09 : 0x00,
            rawProperties: [:]
        )
    }

    // MARK: - (a) Ground truth: nested, not flat

    @Test("A structurally-scoped tunnelled device nests under its chain device in the SAME tree")
    func structurallyScopedDeviceNestsInTree() throws {
        // One host root (apciec2/acio2), one downstream USB-tunnelled switch
        // (LaCie-shaped): DROM depth 1 -> bridge depth 2 -> the LaCie switch.
        let uuidUSB = "BBBBBBBB-0000-0000-0000-000000000002"
        let root = hostRootSwitch(
            id: 100,
            ports: [lanePort(socketID: "4", hopTable: [hopEntry(pathUUID: uuidUSB)])],
            acioRootName: "acio2"
        )
        let laCie = downstreamSwitch(
            id: 200, parent: 100, depth: 1, vendor: "LaCie", model: "1big Dock v2",
            ports: [usbProtocolPort(portNumber: 5, hopTable: [hopEntry(pathUUID: uuidUSB)])]
        )
        let port = makePort(serviceName: "Port-USB-C@4", portNumber: 4)

        // The hub persona names nothing about the LaCie (a bare "USB2 Hub",
        // exactly the case a name match cannot place), with a child device
        // nested under it, to prove BOTH the join itself and that the child
        // inherits through it.
        let hub = tunnelledDevice(id: 1, locationID: 0x0310_0000, bridgeDepth: 2, tunnelRootName: "apciec2", product: "USB2 Hub", isHub: true)
        let child = tunnelledDevice(id: 2, locationID: 0x0310_1000, bridgeDepth: 2, tunnelRootName: "apciec2", product: nil, isHub: false)

        let scoped = TunnelledDeviceGrouping.structurallyScopedTunnelledDevices(
            for: port, in: [hub, child], thunderboltSwitches: [root, laCie]
        )
        #expect(Set(scoped.map(\.id)) == [1, 2], "both devices carry tunnelRootName == apciec2, this port's own root")

        let rows = ConnectedDeviceTree.rows(
            devices: [], tunnelledDevices: scoped, port: port,
            thunderboltSwitches: [root, laCie], displayPorts: []
        )
        // The hub and its child must appear NESTED in this SAME row list
        // (not a separate section): find the LaCie chain row, then confirm
        // the hub is at the next depth and the child one deeper still.
        let laCieRowIndex = try #require(rows.firstIndex { $0.label.contains("1big Dock v2") })
        let hubRow = try #require(rows.first { $0.device?.device.id == 1 })
        let childRow = try #require(rows.first { $0.device?.device.id == 2 })
        #expect(hubRow.depth == rows[laCieRowIndex].depth + 1, "the hub nests directly under its chain device")
        #expect(childRow.depth == hubRow.depth + 1, "the child inherits the hub's placement, one level deeper")
    }

    // MARK: - (b) No structural fields: byte-identical output

    @Test("A machine with no structural tunnel fields renders identically with or without the new parameters")
    func noStructuralFieldsRendersIdentically() {
        // A plain native device, no tunnel fields at all (an older capture,
        // or simply a machine with nothing tunnelled). thunderboltSwitches
        // has no host root either, so there is no Thunderbolt device
        // downstream: the plain USB tree path.
        let port = makePort(serviceName: "Port-USB-C@1", portNumber: 1)
        let device = USBDevice(
            id: 1, locationID: 0x0100_0000, vendorID: 0x05AC, productID: 0x1234,
            vendorName: "Apple", productName: "Magic Keyboard", serialNumber: nil,
            usbVersion: nil, speedRaw: 2, busPowerMA: nil, currentMA: nil,
            busIndex: 1, deviceClass: 0x00, rawProperties: [:]
        )

        // Old call shape (no tunnelledDevices argument at all: the default).
        let oldShapeRows = ConnectedDeviceTree.rows(
            devices: [device], port: port, thunderboltSwitches: [], displayPorts: []
        )
        // New call shape, explicit empty tunnelledDevices.
        let newShapeRows = ConnectedDeviceTree.rows(
            devices: [device], tunnelledDevices: [], port: port, thunderboltSwitches: [], displayPorts: []
        )
        #expect(oldShapeRows == newShapeRows, "an unused new parameter must not change existing output")
        #expect(!oldShapeRows.isEmpty)
    }

    // MARK: - (c) Multi-port scoping

    @Test("A multi-port machine scopes each port's tunnelled devices to that port only")
    func multiPortScopesCorrectly() {
        let uuidA = "AAAAAAAA-1111-1111-1111-111111111111"
        let uuidB = "BBBBBBBB-2222-2222-2222-222222222222"

        let rootA = hostRootSwitch(
            id: 100,
            ports: [lanePort(socketID: "1", hopTable: [hopEntry(pathUUID: uuidA)])],
            acioRootName: "acio1"
        )
        let dockA = downstreamSwitch(
            id: 200, parent: 100, depth: 1, vendor: "Vendor A", model: "Dock A",
            ports: [usbProtocolPort(portNumber: 5, hopTable: [hopEntry(pathUUID: uuidA)])]
        )
        let rootB = hostRootSwitch(
            id: 101,
            ports: [lanePort(socketID: "2", hopTable: [hopEntry(pathUUID: uuidB)])],
            acioRootName: "acio2"
        )
        let dockB = downstreamSwitch(
            id: 201, parent: 101, depth: 1, vendor: "Vendor B", model: "Dock B",
            ports: [usbProtocolPort(portNumber: 5, hopTable: [hopEntry(pathUUID: uuidB)])]
        )
        let switches = [rootA, dockA, rootB, dockB]

        let portA = makePort(serviceName: "Port-USB-C@1", portNumber: 1)
        let portB = makePort(serviceName: "Port-USB-C@2", portNumber: 2)

        let deviceA = tunnelledDevice(id: 1, locationID: 0x0310_0000, bridgeDepth: 2, tunnelRootName: "apciec1", product: nil, isHub: false)
        let deviceB = tunnelledDevice(id: 2, locationID: 0x0311_0000, bridgeDepth: 2, tunnelRootName: "apciec2", product: nil, isHub: false)
        let allDevices = [deviceA, deviceB]

        let scopedForA = TunnelledDeviceGrouping.structurallyScopedTunnelledDevices(
            for: portA, in: allDevices, thunderboltSwitches: switches
        )
        let scopedForB = TunnelledDeviceGrouping.structurallyScopedTunnelledDevices(
            for: portB, in: allDevices, thunderboltSwitches: switches
        )
        #expect(scopedForA.map(\.id) == [1], "port A only claims the device whose tunnelRootName is apciec1")
        #expect(scopedForB.map(\.id) == [2], "port B only claims the device whose tunnelRootName is apciec2")

        // And confirm it flows all the way through the tree: device 1 must
        // resolve under Dock A's row when resolving port A, never under
        // Dock B, and vice versa.
        let rowsA = ConnectedDeviceTree.rows(
            devices: [], tunnelledDevices: scopedForA, port: portA,
            thunderboltSwitches: switches, displayPorts: []
        )
        #expect(rowsA.contains { $0.device?.device.id == 1 })
        #expect(!rowsA.contains { $0.device?.device.id == 2 })

        let rowsB = ConnectedDeviceTree.rows(
            devices: [], tunnelledDevices: scopedForB, port: portB,
            thunderboltSwitches: switches, displayPorts: []
        )
        #expect(rowsB.contains { $0.device?.device.id == 2 })
        #expect(!rowsB.contains { $0.device?.device.id == 1 })
    }
}
