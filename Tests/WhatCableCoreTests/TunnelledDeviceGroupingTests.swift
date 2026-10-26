import Testing
@testable import WhatCableCore

/// Tests the decision in `TunnelledDeviceGrouping`: collect Thunderbolt-tunnelled
/// USB devices, and nest them under a port only when exactly one Thunderbolt
/// device is connected (issue #274). The IOKit detection of the tunnel flag is
/// not unit-testable (no registry in tests); these cover the pure grouping.
struct TunnelledDeviceGroupingTests {
    // MARK: Fixtures

    private func device(
        id: UInt64,
        name: String,
        tunnelled: Bool,
        behindInternalHub: Bool = false,
        deviceClass: UInt8? = nil,
        locationID: UInt32? = nil
    ) -> USBDevice {
        USBDevice(
            id: id,
            locationID: locationID ?? UInt32(truncatingIfNeeded: id),
            vendorID: 0x05AC,
            productID: 0x1234,
            vendorName: "Apple",
            productName: name,
            serialNumber: nil,
            usbVersion: nil,
            speedRaw: 2,
            busPowerMA: nil,
            currentMA: nil,
            isThunderboltTunnelled: tunnelled,
            isBehindInternalHub: behindInternalHub,
            deviceClass: deviceClass,
            rawProperties: [:]
        )
    }

    private func port(socketID: String) -> AppleHPMInterface {
        AppleHPMInterface(
            id: UInt64(socketID) ?? 1,
            serviceName: "Port-USB-C@\(socketID)",
            className: "AppleHPMInterfaceType10",
            portDescription: nil,
            portTypeDescription: "USB-C",
            portNumber: Int(socketID) ?? 1,
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

    private func hostSwitch(id: Int64, socketID: String) -> IOThunderboltSwitch {
        let lane = IOThunderboltPort(
            portNumber: 1,
            socketID: socketID,
            adapterType: .lane,
            currentSpeed: .usb4Tb4,
            currentWidth: LinkWidth(rawValue: 0x2),
            targetWidth: nil,
            rawTargetSpeed: nil,
            linkBandwidthRaw: nil
        )
        return IOThunderboltSwitch(
            id: id,
            className: "IOThunderboltSwitchType7",
            vendorID: 1452,
            vendorName: "Apple Inc.",
            modelName: "Mac",
            routerID: 0,
            depth: 0,
            routeString: 0,
            upstreamPortNumber: 7,
            maxPortNumber: 8,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE),
            ports: [lane],
            parentSwitchUID: nil
        )
    }

    /// A downstream device switch (the dock/display) hanging off a host root.
    private func deviceSwitch(id: Int64, parent: Int64) -> IOThunderboltSwitch {
        IOThunderboltSwitch(
            id: id,
            className: "IOThunderboltSwitchType3",
            vendorID: 1452,
            vendorName: "Apple Inc.",
            modelName: "Studio Display",
            routerID: 0,
            depth: 1,
            routeString: 1,
            upstreamPortNumber: 1,
            maxPortNumber: 13,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE),
            ports: [],
            parentSwitchUID: parent
        )
    }

    // MARK: Tests

    @Test("No tunnelled devices yields an empty result")
    func noTunnelled() {
        let result = TunnelledDeviceGrouping.group(
            devices: [device(id: 1, name: "Mouse", tunnelled: false)],
            ports: [port(socketID: "1")],
            thunderboltSwitches: []
        )
        #expect(result.devices.isEmpty)
        #expect(result.hostPortServiceName == nil)
    }

    @Test("Only tunnelled devices are returned; native ones are excluded")
    func filtersToTunnelled() {
        let result = TunnelledDeviceGrouping.group(
            devices: [
                device(id: 1, name: "Native Mouse", tunnelled: false),
                device(id: 2, name: "TB Keyboard", tunnelled: true)
            ],
            ports: [port(socketID: "2")],
            thunderboltSwitches: []
        )
        #expect(result.devices.map(\.productName) == ["TB Keyboard"])
    }

    @Test("Hubs (class 0x09) are kept so the device tree can nest under them (issues #106, #375)")
    func keepsHubs() {
        let result = TunnelledDeviceGrouping.group(
            devices: [
                device(id: 1, name: "USB2 Hub", tunnelled: true, deviceClass: 0x09),
                device(id: 2, name: "USB3 Gen2 Hub", tunnelled: true, deviceClass: 0x09),
                device(id: 3, name: "Studio Display", tunnelled: true, deviceClass: 0xEF),
                device(id: 4, name: "Magic Keyboard", tunnelled: true, deviceClass: 0x00)
            ],
            ports: [port(socketID: "2")],
            thunderboltSwitches: []
        )
        // The hubs used to be dropped, which flattened the topology. They are now
        // retained alongside the real devices, so nothing the user plugged in is
        // hidden and the renderer can show which device hangs off which hub.
        #expect(Set(result.devices.map(\.productName))
            == ["USB2 Hub", "USB3 Gen2 Hub", "Studio Display", "Magic Keyboard"])
    }

    @Test("A kept hub nests its child in the rendered tree (the #106 / #375 case)")
    func hubNestsChildInTree() {
        // A dock with a hub (locationID 0x0A100000) and a trackpad one hop
        // behind it (0x0A110000, whose parent nibble resolves back to the hub).
        let result = TunnelledDeviceGrouping.group(
            devices: [
                device(id: 1, name: "USB2.1 Hub", tunnelled: true, deviceClass: 0x09,
                       locationID: 0x0A10_0000),
                device(id: 2, name: "Magic Trackpad", tunnelled: true, deviceClass: 0x00,
                       locationID: 0x0A11_0000)
            ],
            ports: [port(socketID: "2")],
            thunderboltSwitches: []
        )
        // The grouping keeps both; buildTree (used by every renderer) then nests
        // the trackpad under the hub instead of listing it as a flat top-level row.
        let tree = USBDeviceNode.buildTree(from: result.devices)
        #expect(tree.count == 1)
        #expect(tree.first?.device.productName == "USB2.1 Hub")
        #expect(tree.first?.children.map(\.device.productName) == ["Magic Trackpad"])
        #expect(tree.first?.children.first?.depth == 1)
    }

    @Test("One connected Thunderbolt device nests tunnelled devices under that port")
    func singleDeviceNests() {
        let host = hostSwitch(id: 100, socketID: "2")
        let display = deviceSwitch(id: 200, parent: 100)
        let result = TunnelledDeviceGrouping.group(
            devices: [
                device(id: 1, name: "Mouse", tunnelled: true),
                device(id: 2, name: "Keyboard", tunnelled: true)
            ],
            ports: [port(socketID: "1"), port(socketID: "2")],
            thunderboltSwitches: [host, display]
        )
        #expect(result.devices.count == 2)
        #expect(result.hostPortServiceName == "Port-USB-C@2")
    }

    @Test("A hub-behind-a-hub dock cascade nests two levels deep")
    func hubChainNestsTwoLevels() {
        // Real dock cascades chain hubs (the corpus has setups 6 levels deep).
        // Dock hub A (0x0C100000) -> hub B one hop behind it (0x0C110000) ->
        // a drive one hop behind B (0x0C111000). Each parent nibble resolves to
        // the level above, so buildTree must produce A > B > drive.
        let result = TunnelledDeviceGrouping.group(
            devices: [
                device(id: 1, name: "Dock hub", tunnelled: true, deviceClass: 0x09, locationID: 0x0C10_0000),
                device(id: 2, name: "Second hub", tunnelled: true, deviceClass: 0x09, locationID: 0x0C11_0000),
                device(id: 3, name: "SSD", tunnelled: true, deviceClass: 0x08, locationID: 0x0C11_1000)
            ],
            ports: [port(socketID: "2")],
            thunderboltSwitches: []
        )
        let tree = USBDeviceNode.buildTree(from: result.devices)
        #expect(tree.count == 1)
        #expect(tree.first?.device.productName == "Dock hub")
        let second = tree.first?.children.first
        #expect(second?.device.productName == "Second hub")
        #expect(second?.depth == 1)
        #expect(second?.children.map(\.device.productName) == ["SSD"])
        #expect(second?.children.first?.depth == 2)
    }

    @Test("Two connected Thunderbolt devices fall back to a flat list (no host port)")
    func twoDevicesFlat() {
        let host1 = hostSwitch(id: 100, socketID: "1")
        let dev1 = deviceSwitch(id: 200, parent: 100)
        let host2 = hostSwitch(id: 101, socketID: "2")
        let dev2 = deviceSwitch(id: 201, parent: 101)
        let result = TunnelledDeviceGrouping.group(
            devices: [device(id: 1, name: "Mouse", tunnelled: true)],
            ports: [port(socketID: "1"), port(socketID: "2")],
            thunderboltSwitches: [host1, dev1, host2, dev2]
        )
        #expect(result.devices.count == 1)
        #expect(result.hostPortServiceName == nil)
    }

    @Test("Tunnelled devices but no connected Thunderbolt device falls back to flat")
    func noTBDeviceFlat() {
        let host = hostSwitch(id: 100, socketID: "2")   // host root, nothing downstream
        let result = TunnelledDeviceGrouping.group(
            devices: [device(id: 1, name: "Mouse", tunnelled: true)],
            ports: [port(socketID: "2")],
            thunderboltSwitches: [host]
        )
        #expect(result.devices.count == 1)
        #expect(result.hostPortServiceName == nil)
    }

    // MARK: Internal-hub / front-port (issue #348)

    @Test("Internal-hub devices appear in internalHubDevices, separate from tunnelled")
    func internalHubFlat() {
        let result = TunnelledDeviceGrouping.group(
            devices: [
                device(id: 1, name: "Front USB drive", tunnelled: false, behindInternalHub: true),
                device(id: 2, name: "Native mouse", tunnelled: false)
            ],
            ports: [port(socketID: "1")],
            thunderboltSwitches: [],
            isDesktopMac: true
        )
        #expect(result.devices.isEmpty)
        #expect(result.hostPortServiceName == nil)
        #expect(result.internalHubDevices.map(\.productName) == ["Front USB drive"])
    }

    @Test("Internal-hub devices are gated off on a laptop (desktop-only policy)")
    func internalHubGatedOffOnLaptop() {
        let devices = [
            device(id: 1, name: "Front USB drive", tunnelled: false, behindInternalHub: true),
            device(id: 2, name: "TB mouse", tunnelled: true)
        ]
        // isDesktopMac defaults to false: the structural flag is set but the
        // front-port set is empty. The tunnelled set is unaffected by the gate.
        let laptop = TunnelledDeviceGrouping.group(
            devices: devices,
            ports: [port(socketID: "1")],
            thunderboltSwitches: []
        )
        #expect(laptop.internalHubDevices.isEmpty)
        #expect(laptop.devices.map(\.productName) == ["TB mouse"])

        // Same input on a desktop surfaces the front-port device.
        let desktop = TunnelledDeviceGrouping.group(
            devices: devices,
            ports: [port(socketID: "1")],
            thunderboltSwitches: [],
            isDesktopMac: true
        )
        #expect(desktop.internalHubDevices.map(\.productName) == ["Front USB drive"])
    }

    @Test("An external hub on a front port is kept in the front list, not dropped")
    func internalHubKeepsExternalHub() {
        // A hub the user plugs into a front port hangs off the Mac's internal
        // hub, so the parent walk flags it behindInternalHub. It is a real thing
        // the user attached, so it is kept (and its children nest under it). Only
        // the Mac's own internal hub is excluded, and that is never a member of
        // this set (it is the boundary the walk stops at), so it cannot appear
        // here regardless of the class check.
        let result = TunnelledDeviceGrouping.group(
            devices: [
                device(id: 1, name: "External USB3 Hub", tunnelled: false, behindInternalHub: true, deviceClass: 0x09),
                device(id: 2, name: "Front drive", tunnelled: false, behindInternalHub: true)
            ],
            ports: [port(socketID: "1")],
            thunderboltSwitches: [],
            isDesktopMac: true
        )
        #expect(Set(result.internalHubDevices.map(\.productName)) == ["External USB3 Hub", "Front drive"])
    }

    @Test("A device behind an external front-port hub nests under that hub")
    func internalHubChildNests() {
        let result = TunnelledDeviceGrouping.group(
            devices: [
                device(id: 1, name: "External hub", tunnelled: false, behindInternalHub: true,
                       deviceClass: 0x09, locationID: 0x0B10_0000),
                device(id: 2, name: "Keyboard", tunnelled: false, behindInternalHub: true,
                       deviceClass: 0x00, locationID: 0x0B11_0000)
            ],
            ports: [port(socketID: "1")],
            thunderboltSwitches: [],
            isDesktopMac: true
        )
        let tree = USBDeviceNode.buildTree(from: result.internalHubDevices)
        #expect(tree.count == 1)
        #expect(tree.first?.device.productName == "External hub")
        #expect(tree.first?.children.map(\.device.productName) == ["Keyboard"])
    }

    @Test("Tunnelled-and-nested coexists with a front-port section")
    func tunnelledNestedPlusInternalHub() {
        let host = hostSwitch(id: 100, socketID: "2")
        let display = deviceSwitch(id: 200, parent: 100)
        let result = TunnelledDeviceGrouping.group(
            devices: [
                device(id: 1, name: "TB mouse", tunnelled: true),
                device(id: 2, name: "Front drive", tunnelled: false, behindInternalHub: true)
            ],
            ports: [port(socketID: "1"), port(socketID: "2")],
            thunderboltSwitches: [host, display],
            isDesktopMac: true
        )
        #expect(result.devices.map(\.productName) == ["TB mouse"])
        #expect(result.hostPortServiceName == "Port-USB-C@2")
        #expect(result.internalHubDevices.map(\.productName) == ["Front drive"])
    }

    @Test("No off-port device is silently dropped: hubs and leaves are all accounted for")
    func noOffPortDeviceIsHidden() {
        // The recurring complaint (issues #106, #280, #348, #373, #375) was always
        // "device counted but listed nowhere". This pins the contract for the two
        // sets this function owns: every device flagged tunnelled, or (on a
        // desktop) behind the internal hub, must come back in exactly one of the
        // sets, hubs included. A native-port device belongs to a port card and so
        // appears in neither set here.
        let devices = [
            device(id: 1, name: "Native port mouse", tunnelled: false),
            device(id: 2, name: "Dock hub", tunnelled: true, deviceClass: 0x09),
            device(id: 3, name: "Dock SSD", tunnelled: true),
            device(id: 4, name: "Front external hub", tunnelled: false, behindInternalHub: true, deviceClass: 0x09),
            device(id: 5, name: "Front keyboard", tunnelled: false, behindInternalHub: true)
        ]
        let result = TunnelledDeviceGrouping.group(
            devices: devices,
            ports: [port(socketID: "1")],
            thunderboltSwitches: [],
            isDesktopMac: true
        )
        let shown = Set(result.devices.map(\.id)).union(result.internalHubDevices.map(\.id))
        let expectedOffPort = Set(devices.filter { $0.isThunderboltTunnelled || $0.isBehindInternalHub }.map(\.id))
        #expect(shown == expectedOffPort)          // every off-port device, including both hubs
        #expect(!shown.contains(1))                // the native-port device is not pulled off-port
    }

    @Test("A device flagged both tunnelled and internal-hub goes only to the tunnelled set")
    func bothFlagsTunnelledWins() {
        let result = TunnelledDeviceGrouping.group(
            devices: [device(id: 1, name: "Odd device", tunnelled: true, behindInternalHub: true)],
            ports: [port(socketID: "1")],
            thunderboltSwitches: [],
            isDesktopMac: true
        )
        #expect(result.devices.map(\.productName) == ["Odd device"])
        #expect(result.internalHubDevices.isEmpty)
    }
}
