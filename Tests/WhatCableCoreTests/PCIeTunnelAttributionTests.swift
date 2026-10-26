import Foundation
import Testing
@testable import WhatCableCore

/// Tests for the PCIe-carried tunnelled-device attribution (plan
/// `pcie-tunnelled-usb-attribution`, the LG UltraFine 5K case): the carrier
/// gates in `ChainDeviceAttribution`, the Stage A single-switch shortcut, the
/// Core union helper, and the end-to-end wiring through both formatters and
/// the widget snapshot.
///
/// Ground truth throughout is the reporter's capture
/// (`research/customer-probes/m2max_macos26.6.1`): a 2019 LG UltraFine 5K
/// whose 8 USB devices (camera, audio, optical drive) sit on the monitor's
/// own FL1100 PCIe xHCI, with PCIe + DP tunnels and NO USB tunnel.
struct PCIeTunnelAttributionTests {

    // MARK: - Fixtures (construction helpers duplicated per house rule)

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
            transportsActive: ["CC", "CIO"],
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

    private func lanePort(socketID: String) -> IOThunderboltPort {
        IOThunderboltPort(
            portNumber: 1,
            socketID: socketID,
            adapterType: .lane,
            currentSpeed: .usb4Tb4,
            currentWidth: LinkWidth(rawValue: 0x2),
            targetWidth: nil,
            rawTargetSpeed: nil,
            linkBandwidthRaw: nil,
            hopTable: []
        )
    }

    private func hostRootSwitch(
        id: Int64,
        socketID: String,
        acioRootName: String?
    ) -> IOThunderboltSwitch {
        IOThunderboltSwitch(
            id: id, className: "IOThunderboltSwitchType5", vendorID: 0x5AC,
            vendorName: "Apple Inc.", modelName: "Mac", routerID: 0, depth: 0,
            routeString: 0, upstreamPortNumber: 7, maxPortNumber: 7,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE),
            ports: [lanePort(socketID: socketID)],
            parentSwitchUID: nil, acioRootName: acioRootName
        )
    }

    /// A PCIe-only downstream switch (LG UltraFine-shaped): TB3 class, no
    /// USB-tunnel adapters, so it never appears in `usbTunnelSwitchUIDs`.
    private func pcieOnlySwitch(
        id: Int64,
        parent: Int64,
        depth: Int,
        model: String = "UltraFine 5K"
    ) -> IOThunderboltSwitch {
        IOThunderboltSwitch(
            id: id, className: "IOThunderboltSwitchType3", vendorID: 0x043E,
            vendorName: "LG Electronics", modelName: model, routerID: depth,
            depth: depth, routeString: Int64(depth), upstreamPortNumber: 1,
            maxPortNumber: 13, supportedSpeed: SupportedSpeedMask(rawValue: 0xE),
            ports: [], parentSwitchUID: parent
        )
    }

    /// A device on a dock-supplied PCIe xHCI: tunnelled, PCIe carrier,
    /// rootName from the walk, NO bridge depth (unverified for dock
    /// controllers; Stage A never uses one).
    private func pcieDevice(
        id: UInt64,
        locationID: UInt32,
        rootName: String?,
        product: String,
        vid: UInt16 = 0x043E,
        isHub: Bool = false
    ) -> USBDevice {
        USBDevice(
            id: id, locationID: locationID, vendorID: vid, productID: 0x9A00,
            vendorName: nil, productName: product, serialNumber: nil,
            usbVersion: nil, speedRaw: 3, busPowerMA: nil, currentMA: nil,
            isThunderboltTunnelled: true,
            tunnelBridgeDepth: nil,
            tunnelRootName: rootName,
            tunnelCarrier: .pcieTunnel,
            deviceClass: isHub ? 0x09 : 0x00,
            rawProperties: [:]
        )
    }

    private func nativeDevice(id: UInt64, locationID: UInt32, port: String, product: String) -> USBDevice {
        USBDevice(
            id: id, locationID: locationID, vendorID: 0x2188, productID: 0x0033,
            vendorName: nil, productName: product, serialNumber: nil,
            usbVersion: nil, speedRaw: 3, busPowerMA: nil, currentMA: nil,
            controllerPortName: port,
            rawProperties: [:]
        )
    }

    private func chainNode(_ sw: IOThunderboltSwitch, in switches: [IOThunderboltSwitch]) -> [IOThunderboltSwitchNode] {
        ThunderboltTopology.tree(from: hostRoot(for: sw, in: switches) ?? sw, in: switches)
    }

    private func hostRoot(for sw: IOThunderboltSwitch, in switches: [IOThunderboltSwitch]) -> IOThunderboltSwitch? {
        switches.first { $0.id == sw.parentSwitchUID }
    }

    // MARK: - Carrier gates (plan test 10)

    @Test("A nil-carrier device with a valid bridge depth enters NEITHER structural join")
    func nilCarrierJoinsNothing() {
        let host = hostRootSwitch(id: 1, socketID: "1", acioRootName: "acio1")
        let usbDock = IOThunderboltSwitch(
            id: 2, className: "IOThunderboltSwitchIntelJHL8440", vendorID: 0x8087,
            vendorName: "CalDigit, Inc.", modelName: "Element Hub", routerID: 1,
            depth: 1, routeString: 1, upstreamPortNumber: 1, maxPortNumber: 13,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE), ports: [],
            parentSwitchUID: 1
        )
        let switches = [host, usbDock]
        let chain = ThunderboltTopology.tree(from: host, in: switches)

        // Depth 2 = DROM depth 1 = the dock: WOULD join if the carrier were
        // .usbTunnel (that is what the mutation check flips).
        let device = USBDevice(
            id: 10, locationID: 0x2200000, vendorID: 0x05AC, productID: 0x1,
            vendorName: nil, productName: "USB3 Hub", serialNumber: nil,
            usbVersion: nil, speedRaw: 3, busPowerMA: nil, currentMA: nil,
            isThunderboltTunnelled: true,
            tunnelBridgeDepth: 2, tunnelRootName: "apciec1",
            tunnelCarrier: nil,
            deviceClass: 0x09, rawProperties: [:]
        )
        let forest = USBDeviceNode.buildTree(from: [device])
        let result = ChainDeviceAttribution.resolve(
            chain: chain, forest: forest,
            usbTunnelSwitchUIDs: [2], expectedTunnelRootName: "apciec1"
        )
        #expect(result.regionOwner[10] == nil, "nil carrier must not enter the USB depth join")

        // Same device with the carrier set IS placed: proves the gate (not
        // some other refusal) is what excluded the nil-carrier device.
        let carried = USBDevice(
            id: 10, locationID: 0x2200000, vendorID: 0x05AC, productID: 0x1,
            vendorName: nil, productName: "USB3 Hub", serialNumber: nil,
            usbVersion: nil, speedRaw: 3, busPowerMA: nil, currentMA: nil,
            isThunderboltTunnelled: true,
            tunnelBridgeDepth: 2, tunnelRootName: "apciec1",
            tunnelCarrier: .usbTunnel,
            deviceClass: 0x09, rawProperties: [:]
        )
        let carriedResult = ChainDeviceAttribution.resolve(
            chain: chain, forest: USBDeviceNode.buildTree(from: [carried]),
            usbTunnelSwitchUIDs: [2], expectedTunnelRootName: "apciec1"
        )
        #expect(carriedResult.regionOwner[10] == 2)
    }

    // MARK: - Single-switch shortcut (plan tests 3 positive + 11 negative)

    @Test("PCIe-carried, rootName-scoped devices attribute to the SOLE downstream switch (positive shortcut proof)")
    func singleSwitchShortcutAttributes() {
        let host = hostRootSwitch(id: 1, socketID: "2", acioRootName: "acio1")
        let lg = pcieOnlySwitch(id: 5, parent: 1, depth: 1)
        let switches = [host, lg]
        let chain = ThunderboltTopology.tree(from: host, in: switches)
        #expect(chain.count == 1, "fixture: exactly one downstream switch")

        let camera = pcieDevice(id: 20, locationID: 0x20543000, rootName: "apciec1", product: "LG UltraFine Display Camera")
        let drive = pcieDevice(id: 21, locationID: 0x20530000, rootName: "apciec1", product: "VLI Product String", vid: 0x1234)
        let forest = USBDeviceNode.buildTree(from: [camera, drive])
        let result = ChainDeviceAttribution.resolve(
            chain: chain, forest: forest,
            usbTunnelSwitchUIDs: [],   // the LG carries no USB tunnel
            expectedTunnelRootName: "apciec1"
        )
        #expect(result.regionOwner[20] == 5, "camera nests under the LG switch")
        #expect(result.regionOwner[21] == 5, "optical drive nests under the LG switch")
    }

    @Test("PCIe-carried device on a 2-switch chain stays at port level (Stage B boundary is a test, not prose)")
    func multiSwitchChainRefusesShortcut() {
        let host = hostRootSwitch(id: 1, socketID: "2", acioRootName: "acio1")
        let first = pcieOnlySwitch(id: 5, parent: 1, depth: 1, model: "Dock A")
        let second = pcieOnlySwitch(id: 6, parent: 5, depth: 2, model: "Dock B")
        let switches = [host, first, second]
        let chain = ThunderboltTopology.tree(from: host, in: switches)
        #expect(ThunderboltTopology.flatten(chain).count == 2, "fixture: two downstream switches")

        let device = pcieDevice(id: 20, locationID: 0x20543000, rootName: "apciec1", product: "Some Device")
        let result = ChainDeviceAttribution.resolve(
            chain: chain, forest: USBDeviceNode.buildTree(from: [device]),
            usbTunnelSwitchUIDs: [], expectedTunnelRootName: "apciec1"
        )
        #expect(result.regionOwner[20] == nil, "no depth evidence exists for dock controllers; a daisy chain must refuse")
    }

    @Test("A PCIe device whose rootName names a DIFFERENT port is refused even on a single-switch chain")
    func crossPortRootRefused() {
        let host = hostRootSwitch(id: 1, socketID: "2", acioRootName: "acio1")
        let lg = pcieOnlySwitch(id: 5, parent: 1, depth: 1)
        let chain = ThunderboltTopology.tree(from: host, in: [host, lg])
        let device = pcieDevice(id: 20, locationID: 0x20543000, rootName: "apciec2", product: "Some Device")
        let result = ChainDeviceAttribution.resolve(
            chain: chain, forest: USBDeviceNode.buildTree(from: [device]),
            usbTunnelSwitchUIDs: [], expectedTunnelRootName: "apciec1"
        )
        #expect(result.regionOwner[20] == nil)
    }

    @Test("A PCIe device with NO rootName (failure invariant) is never structurally claimed")
    func noRootNameNeverClaimed() {
        let host = hostRootSwitch(id: 1, socketID: "2", acioRootName: "acio1")
        let lg = pcieOnlySwitch(id: 5, parent: 1, depth: 1)
        let chain = ThunderboltTopology.tree(from: host, in: [host, lg])
        let device = pcieDevice(id: 20, locationID: 0x20543000, rootName: nil, product: "Some Device")
        let result = ChainDeviceAttribution.resolve(
            chain: chain, forest: USBDeviceNode.buildTree(from: [device]),
            usbTunnelSwitchUIDs: [], expectedTunnelRootName: "apciec1"
        )
        #expect(result.regionOwner[20] == nil)
    }

    // MARK: - Positive nesting through the tree (plan test 3, rows level)

    @Test("Single-switch chain: the PCIe devices render nested UNDER the switch's chain row")
    func devicesNestUnderChainRow() {
        let host = hostRootSwitch(id: 1, socketID: "2", acioRootName: "acio1")
        let lg = pcieOnlySwitch(id: 5, parent: 1, depth: 1)
        let switches = [host, lg]
        let port = makePort(serviceName: "Port-USB-C@2", portNumber: 2)
        let camera = pcieDevice(id: 20, locationID: 0x20543000, rootName: "apciec1", product: "LG UltraFine Display Camera")

        let rows = ConnectedDeviceTree.rows(
            devices: [],
            tunnelledDevices: [camera],
            port: port,
            thunderboltSwitches: switches,
            displayPorts: []
        )
        let chainRowIndex = rows.firstIndex { $0.label.contains("UltraFine") && $0.device == nil }
        let deviceRowIndex = rows.firstIndex { $0.device?.id == 20 }
        let chainIdx = try! #require(chainRowIndex)
        let devIdx = try! #require(deviceRowIndex)
        #expect(devIdx > chainIdx, "device row comes after its chain row")
        #expect(rows[devIdx].depth > rows[chainIdx].depth, "device is nested under the switch, not flat beside it")
    }

    // MARK: - Union helper + multi-controller (plan tests 5a/5b)

    @Test("attributedDevices unions native matches and scoped tunnelled devices, deduplicated by id")
    func unionHelperDedups() {
        let host = hostRootSwitch(id: 1, socketID: "2", acioRootName: "acio1")
        let lg = pcieOnlySwitch(id: 5, parent: 1, depth: 1)
        let switches = [host, lg]
        let port = makePort(serviceName: "Port-USB-C@2", portNumber: 2)
        let native = nativeDevice(id: 30, locationID: 0x2100000, port: "Port-USB-C@2", product: "Native Hub")
        // Two controllers behind ONE port/root: both scope to it (5a).
        let a = pcieDevice(id: 31, locationID: 0x20543000, rootName: "apciec1", product: "Controller A Device")
        let b = pcieDevice(id: 32, locationID: 0x21543000, rootName: "apciec1", product: "Controller B Device")
        let devices = [native, a, b]
        let union = TunnelledDeviceGrouping.attributedDevices(for: port, in: devices, thunderboltSwitches: switches)
        #expect(Set(union.map(\.id)) == [30, 31, 32])
        #expect(union.count == 3, "no duplicates")
    }

    @Test("Controllers on DIFFERENT roots scope each to their own port only")
    func differentRootsScopeToOwnPorts() {
        let host1 = hostRootSwitch(id: 1, socketID: "1", acioRootName: "acio0")
        let host2 = hostRootSwitch(id: 2, socketID: "2", acioRootName: "acio1")
        let dockA = pcieOnlySwitch(id: 5, parent: 1, depth: 1, model: "Dock A")
        let dockB = pcieOnlySwitch(id: 6, parent: 2, depth: 1, model: "Dock B")
        let switches = [host1, host2, dockA, dockB]
        let port1 = makePort(serviceName: "Port-USB-C@1", portNumber: 1)
        let port2 = makePort(serviceName: "Port-USB-C@2", portNumber: 2)
        let devA = pcieDevice(id: 40, locationID: 0x20100000, rootName: "apciec0", product: "A Device")
        let devB = pcieDevice(id: 41, locationID: 0x21100000, rootName: "apciec1", product: "B Device")
        let all = [devA, devB]
        let scoped1 = TunnelledDeviceGrouping.structurallyScopedTunnelledDevices(for: port1, in: all, thunderboltSwitches: switches)
        let scoped2 = TunnelledDeviceGrouping.structurallyScopedTunnelledDevices(for: port2, in: all, thunderboltSwitches: switches)
        #expect(scoped1.map(\.id) == [40])
        #expect(scoped2.map(\.id) == [41])
    }

    // MARK: - End-to-end via the real entry points (plan test 6)

    /// The reporter's topology, shrunk to essentials: three ports, three TB
    /// devices (two USB-tunnel docks, one PCIe-only LG), the LG's devices
    /// carrying rootName from the extended walk. Before the fix these devices
    /// rendered only in the flat section; now they belong to the LG's port.
    private func reporterTopology() -> (
        ports: [AppleHPMInterface], switches: [IOThunderboltSwitch], devices: [USBDevice]
    ) {
        let host1 = hostRootSwitch(id: 1, socketID: "1", acioRootName: "acio0")
        let host2 = hostRootSwitch(id: 2, socketID: "2", acioRootName: "acio1")
        let host3 = hostRootSwitch(id: 3, socketID: "3", acioRootName: "acio2")
        let calDigit = IOThunderboltSwitch(
            id: 11, className: "IOThunderboltSwitchIntelJHL8440", vendorID: 0x8087,
            vendorName: "CalDigit, Inc.", modelName: "Element Hub", routerID: 1,
            depth: 1, routeString: 1, upstreamPortNumber: 1, maxPortNumber: 13,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE), ports: [],
            parentSwitchUID: 1
        )
        let owc = IOThunderboltSwitch(
            id: 12, className: "IOThunderboltSwitchIntelJHL8440", vendorID: 0x8087,
            vendorName: "Other World Computing", modelName: "Thunderbolt Dock", routerID: 1,
            depth: 1, routeString: 1, upstreamPortNumber: 1, maxPortNumber: 13,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE), ports: [],
            parentSwitchUID: 3
        )
        let lg = pcieOnlySwitch(id: 13, parent: 2, depth: 1)
        let ports = [
            makePort(serviceName: "Port-USB-C@1", portNumber: 1),
            makePort(serviceName: "Port-USB-C@2", portNumber: 2),
            makePort(serviceName: "Port-USB-C@3", portNumber: 3),
        ]
        let devices = [
            nativeDevice(id: 50, locationID: 0x100000, port: "Port-USB-C@1", product: "Element USB 2.0 Hub"),
            nativeDevice(id: 51, locationID: 0x2100000, port: "Port-USB-C@3", product: "OWC USB 2.0 Hub"),
            pcieDevice(id: 60, locationID: 0x20543000, rootName: "apciec1", product: "LG UltraFine Display Camera"),
            pcieDevice(id: 61, locationID: 0x20530000, rootName: "apciec1", product: "VLI Product String", vid: 0x1234),
            pcieDevice(id: 62, locationID: 0x20540000, rootName: "apciec1", product: "LG USB 3.1 Hub", isHub: true),
        ]
        return (ports, [host1, host2, host3, calDigit, owc, lg], devices)
    }

    @Test("TextFormatter end-to-end: LG devices render under the LG port, exactly once, no flat section")
    func textFormatterEndToEnd() {
        let (ports, switches, devices) = reporterTopology()
        let out = TextFormatter.render(
            ports: ports, sources: [], identities: [], showRaw: false,
            thunderboltSwitches: switches, usbDevices: devices
        )
        // Each LG device appears exactly once in the whole output.
        for name in ["LG UltraFine Display Camera", "VLI Product String"] {
            let occurrences = out.components(separatedBy: name).count - 1
            #expect(occurrences == 1, "\(name) must render exactly once, saw \(occurrences)")
        }
        // With every tunnelled device structurally claimed, the flat
        // "Other USB devices" fallback section has nothing to show. Its
        // heading ends in a colon; the per-port "Other USB devices on this
        // port" heading is a different section and may appear.
        #expect(!out.contains("Other USB devices:"), "no flat section when everything is port-scoped")
        // The OWC port's hub names nothing, so the CLI prints it under that
        // port's own other-devices heading.
        #expect(out.contains("Other USB devices on this port"))
        // The devices sit inside the @2 port section: between the @2 header
        // and the @3 header.
        if let lgSection = out.range(of: "Port-USB-C@2"), let nextSection = out.range(of: "Port-USB-C@3") {
            let section = out[lgSection.lowerBound..<nextSection.lowerBound]
            #expect(section.contains("VLI Product String"), "optical drive renders inside the LG port's section")
        } else {
            Issue.record("expected both port sections in output")
        }
    }

    @Test("JSONFormatter end-to-end: LG devices in the port's device list, no otherUSBDevices, no key changes")
    func jsonFormatterEndToEnd() throws {
        let (ports, switches, devices) = reporterTopology()
        let out = try JSONFormatter.render(
            ports: ports, sources: [], identities: [], showRaw: false,
            thunderboltSwitches: switches, usbDevices: devices
        )
        let root = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        #expect(root["otherUSBDevices"] == nil, "flat group empty when everything is port-scoped")
        let portsJSON = try #require(root["ports"] as? [[String: Any]])
        let lgPort = try #require(portsJSON.first { ($0["name"] as? String) == "Port-USB-C@2" })
        let deviceTree = lgPort["devices"] as? [[String: Any]] ?? []
        func flatNames(_ nodes: [[String: Any]]) -> [String] {
            nodes.flatMap { node -> [String] in
                [(node["name"] as? String) ?? ""] + flatNames(node["children"] as? [[String: Any]] ?? [])
            }
        }
        let names = flatNames(deviceTree)
        #expect(names.contains("VLI Product String"), "optical drive is in the LG port's JSON device list")
        #expect(names.contains("LG UltraFine Display Camera"))
        // Exactly once across the whole document.
        let occurrences = out.components(separatedBy: "VLI Product String").count - 1
        #expect(occurrences == 1, "device appears once in the whole JSON, saw \(occurrences)")
    }

    // MARK: - Widget (plan test 6, widget paths)

    @Test("WidgetSnapshot(from:) counts structurally scoped devices and reads the port live")
    func widgetSnapshotSeesScopedDevices() {
        let (ports, switches, devices) = reporterTopology()
        let cable = CableSnapshot(
            ports: ports,
            powerSources: [],
            identities: [],
            usbDevices: devices,
            adapter: nil,
            thunderboltSwitches: switches
        )
        let widget = WidgetSnapshot(from: cable)
        let lgEntry = widget.ports.first { $0.id == 2 }
        let entry = try! #require(lgEntry)
        #expect(entry.deviceCount == 3, "all three LG devices counted, got \(entry.deviceCount)")
    }

    @Test("Widget liveness is genuinely driven by scoped devices: an inactive-flag port with ONLY scoped devices does not read empty")
    func widgetLivenessNonVacuous() {
        // connectionActive nil (older macOS never publishes the flag): the
        // only liveness signal left is the device list, so this test goes
        // red if the union regresses to native matches (which are empty
        // here), unlike a fixture whose connectionActive already forces
        // live (review finding: vacuous liveness check).
        let host = hostRootSwitch(id: 2, socketID: "2", acioRootName: "acio1")
        let lg = pcieOnlySwitch(id: 13, parent: 2, depth: 1)
        let inactivePort = AppleHPMInterface(
            id: 2, serviceName: "Port-USB-C@2",
            className: "AppleHPMInterfaceType10", portDescription: nil,
            portTypeDescription: "USB-C", portNumber: 2,
            connectionActive: nil, activeCable: nil, opticalCable: nil,
            usbActive: nil, superSpeedActive: nil, usbModeType: nil,
            usbConnectString: nil, transportsSupported: ["CC", "USB3", "CIO"],
            transportsActive: [], transportsProvisioned: [],
            plugOrientation: nil, plugEventCount: nil, connectionCount: nil,
            overcurrentCount: nil, pinConfiguration: [:], powerCurrentLimits: [],
            firmwareVersion: nil, bootFlagsHex: nil, rawProperties: [:]
        )
        let camera = pcieDevice(id: 60, locationID: 0x20543000, rootName: "apciec1", product: "LG UltraFine Display Camera")
        let cable = CableSnapshot(
            ports: [inactivePort], powerSources: [], identities: [],
            usbDevices: [camera], adapter: nil, thunderboltSwitches: [host, lg]
        )
        let widget = WidgetSnapshot(from: cable)
        let entry = try! #require(widget.ports.first)
        #expect(entry.deviceCount == 1)
        #expect(entry.status != .empty, "a port carrying only PCIe-scoped devices must not read empty, got \(entry.status)")
    }
}
