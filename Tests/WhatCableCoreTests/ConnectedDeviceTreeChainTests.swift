import Foundation
import Testing
@testable import WhatCableCore

/// The chain layout of `ConnectedDeviceTree.rows`: the Thunderbolt chain as the
/// skeleton, with USB devices hanging off the device they are actually plugged
/// into.
///
/// The centrepiece is `referenceMachineRendersFourRows`, which replays the
/// reference machine's real registry contents (Mac -> Apple Studio Display ->
/// UGREEN TBT5 dock, with a Realtek Ethernet adapter in the dock) read with
/// `ioreg` rather than through the app, and asserts the exact rows. That setup
/// rendered twelve rows five levels deep, of which nine were hubs, and the two
/// things the user had actually plugged in were buried among them.
///
/// The layout gate matters as much as the layout: one chain device and no name
/// match means the port renders exactly as it did before, so the tests here that
/// assert "unchanged" are load-bearing.
@Suite("ConnectedDeviceTree chain layout")
struct ConnectedDeviceTreeChainTests {

    // MARK: - Fixtures

    private func makePort(serviceName: String = "Port-USB-C@4") -> AppleHPMInterface {
        AppleHPMInterface(
            id: 1,
            serviceName: serviceName,
            className: "AppleHPMInterfaceType10",
            portDescription: nil,
            portTypeDescription: "USB-C",
            portNumber: 4,
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

    /// A 40 Gbps active lane (TB4/USB4 dual-lane), the reference machine's link.
    private func lanePort(socketID: String? = nil, portNumber: Int = 1) -> IOThunderboltPort {
        IOThunderboltPort(
            portNumber: portNumber,
            socketID: socketID,
            adapterType: .lane,
            currentSpeed: LinkGeneration.from(rawSpeedCode: 0x4),
            currentWidth: LinkWidth(rawValue: 0x2),
            targetWidth: nil,
            rawTargetSpeed: nil,
            linkBandwidthRaw: nil,
            hopTable: []
        )
    }

    private func sw(
        id: Int64,
        parent: Int64?,
        vendor: String,
        model: String,
        depth: Int,
        socketID: String? = nil
    ) -> IOThunderboltSwitch {
        IOThunderboltSwitch(
            id: id,
            className: "IOThunderboltSwitchIntelJHL9580",
            vendorID: 0x8086,
            vendorName: vendor,
            modelName: model,
            routerID: depth,
            depth: depth,
            routeString: Int64(depth),
            upstreamPortNumber: 1,
            maxPortNumber: 12,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE),
            ports: [lanePort(socketID: socketID)],
            parentSwitchUID: parent
        )
    }

    private func usb(
        _ id: UInt64,
        _ locationID: UInt32,
        vid: UInt16,
        vendor: String?,
        product: String,
        hub: Bool,
        speed: UInt8,
        bus: Int? = nil
    ) -> USBDevice {
        USBDevice(
            id: id,
            locationID: locationID,
            vendorID: vid,
            productID: 0x0001,
            vendorName: vendor,
            productName: product,
            serialNumber: nil,
            usbVersion: nil,
            speedRaw: speed,
            busPowerMA: nil,
            currentMA: nil,
            busIndex: bus,
            deviceClass: hub ? 0x09 : 0x00,
            rawProperties: [:]
        )
    }

    private func displayPort(_ productName: String) -> IOPortTransportStateDisplayPort {
        IOPortTransportStateDisplayPort(
            link: DisplayPortLink(active: true, laneCount: 2, maxLaneCount: 4, linkRate: 0, tunneled: true, hpdState: 1),
            monitor: MonitorInfo(
                manufacturerName: nil, productName: productName, productId: nil,
                yearOfManufacture: nil, edid: nil
            )
        )
    }

    // MARK: - The reference machine

    /// Host root at socket 4 -> Studio Display (depth 1) -> UGREEN dock (depth 2).
    /// Model names verbatim from the fabric, trailing space on the display
    /// included: it is in the DROM and the match has to survive it.
    private var referenceSwitches: [IOThunderboltSwitch] {
        [
            sw(id: 100, parent: nil, vendor: "Apple, Inc.", model: "iOS", depth: 0, socketID: "4"),
            sw(id: 200, parent: 100, vendor: "Apple", model: "Studio Display ", depth: 1),
            sw(id: 300, parent: 200, vendor: "Ugreen Group Limited", model: "TBT5 Docking Station 10-in-1", depth: 2),
        ]
    }

    /// All twelve `IOUSBHostDevice` entries from the reference machine, with the
    /// real locationIDs, vendor IDs, product names, hub classes and speeds.
    /// Nine are hubs; the three real endpoints are the display, the dock and the
    /// Ethernet adapter.
    private var referenceDevices: [USBDevice] {
        [
            // USB 2.0 tree, rooted at the display's own hub.
            usb(1, 0x0310_0000, vid: 0x05AC, vendor: "Apple", product: "USB2.0 Hub", hub: true, speed: 2),
            usb(2, 0x0313_0000, vid: 0x05AC, vendor: "Apple Inc.", product: "Studio Display", hub: false, speed: 2),
            usb(3, 0x0312_0000, vid: 0x1D5C, vendor: "Fresco Logic, Inc.", product: "USB2.0 Hub", hub: true, speed: 2),
            usb(4, 0x0312_1000, vid: 0x2B89, vendor: "UGREEN", product: "TBT5 Docking Station 10-in-1", hub: false, speed: 1),
            usb(5, 0x0312_4000, vid: 0x2109, vendor: "VIA Labs, Inc.", product: "USB2.0 Hub", hub: true, speed: 2),
            usb(6, 0x0312_4100, vid: 0x2109, vendor: "VIA Labs, Inc.", product: "USB2.0 Hub", hub: true, speed: 2),
            // USB 3.x tree, which carries no name that matches anything.
            usb(7, 0x0320_0000, vid: 0x8087, vendor: "Intel Corporation", product: "USB3 HUB", hub: true, speed: 4),
            usb(8, 0x0321_0000, vid: 0x8087, vendor: "Intel Corporation", product: "USB3 HUB", hub: true, speed: 4),
            usb(9, 0x0321_4000, vid: 0x2109, vendor: "VIA Labs, Inc.", product: "USB3.1 Hub", hub: true, speed: 4),
            usb(10, 0x0321_4100, vid: 0x2109, vendor: "VIA Labs, Inc.", product: "USB3.0 Hub", hub: true, speed: 3),
            usb(11, 0x0321_4140, vid: 0x0BDA, vendor: "Realtek", product: "USB 10/100/1000 LAN", hub: false, speed: 3),
            usb(12, 0x0324_0000, vid: 0x05AC, vendor: "Apple", product: "USB3.1 Hub", hub: true, speed: 4),
        ]
    }

    private func referenceRows(hubs: ConnectedDeviceTree.HubDisplay) -> [ConnectedDeviceTree.Row] {
        ConnectedDeviceTree.rows(
            devices: referenceDevices,
            port: makePort(),
            thunderboltSwitches: referenceSwitches,
            displayPorts: [displayPort("StudioDisplay")],
            hubs: hubs
        )
    }

    @Test("The reference machine collapses from twelve rows to five, nothing drawn in a box without evidence")
    func referenceMachineRendersFourRows() throws {
        // This fixture carries no Container IDs and no hop tables, so only the
        // two identity endpoints have evidence (each is absorbed into its own
        // box row). The Ethernet adapter was placed in the dock by vendor
        // continuity before 2026-10-08; with evidence only, it moves under the
        // port's other-devices heading.
        let rows = referenceRows(hubs: .endpointsOnly)
        let rendered = rows.map { "\(String(repeating: "  ", count: $0.depth))\($0.label)" }
        #expect(rows.count == 5, "Expected five rows, got \(rows.count):\n\(rendered.joined(separator: "\n"))")
        try #require(rows.count == 5)

        #expect(rows[0].depth == 0)
        #expect(rows[0].label == "Apple Studio Display - Thunderbolt link active at 40 Gbps")

        #expect(rows[1].depth == 1)
        #expect(rows[1].label == "Display: StudioDisplay")

        #expect(rows[2].depth == 1)
        #expect(rows[2].label == "Ugreen Group Limited TBT5 Docking Station 10-in-1 - Thunderbolt link active at 40 Gbps")

        #expect(rows[3] == ConnectedDeviceTree.Row(label: "Other USB devices on this port", depth: 0))
        #expect(rows[4].depth == 1, "Under the heading, not inside the dock")
        #expect(rows[4].label == "USB 10/100/1000 LAN (Realtek) - Super Speed (5 Gbps) \u{00B7} via 4 hubs")
        #expect(rows[4].device?.device.id == 11)
    }

    @Test("The display's and the dock's own USB identity endpoints are not listed twice")
    func identityEndpointsAreAbsorbed() {
        let rows = referenceRows(hubs: .endpointsOnly)
        #expect(!rows.contains { $0.device?.device.id == 2 }, "The display's USB endpoint duplicates its chain row")
        #expect(!rows.contains { $0.device?.device.id == 4 }, "The dock's USB endpoint duplicates its chain row")
        // And they are not listed twice in the expanded view either.
        let all = referenceRows(hubs: .all)
        #expect(!all.contains { $0.device?.device.id == 2 })
        #expect(!all.contains { $0.device?.device.id == 4 })
    }

    @Test("The Ethernet adapter sits under the other-devices heading in BOTH hub modes")
    func placementAgreesAcrossHubModes() throws {
        // The bug this pins: an earlier draft placed the adapter differently in
        // the collapsed and expanded views. Both modes read the same ownership,
        // so the device cannot move when the user clicks "Show hubs".
        let collapsed = referenceRows(hubs: .endpointsOnly)
        let expanded = referenceRows(hubs: .all)

        let headerRow = try #require(expanded.firstIndex(of: ConnectedDeviceTree.Row(label: "Other USB devices on this port", depth: 0)))
        let lanRow = try #require(expanded.firstIndex { $0.device?.device.id == 11 })
        try #require(lanRow > headerRow, "The adapter must be rendered under the heading")
        // Nothing between the heading and the adapter may close the section.
        for row in expanded[(headerRow + 1)..<lanRow] {
            #expect(row.depth > 0, "Row '\(row.label)' closed the section before the adapter")
        }

        let collapsedHeader = try #require(collapsed.firstIndex(of: ConnectedDeviceTree.Row(label: "Other USB devices on this port", depth: 0)))
        let collapsedLAN = try #require(collapsed.firstIndex { $0.device?.device.id == 11 })
        #expect(collapsedLAN > collapsedHeader)
        #expect(collapsed[collapsedLAN].depth == 1)
    }

    @Test("Expanded, every device still renders exactly once")
    func expandedViewLosesNothing() {
        let all = referenceRows(hubs: .all)
        let ids = all.compactMap { $0.device?.device.id }
        #expect(Set(ids).count == ids.count, "A device rendered twice: \(ids)")
        // Twelve devices, less the two absorbed identity endpoints.
        #expect(Set(ids) == Set([1, 3, 5, 6, 7, 8, 9, 10, 11, 12]),
            "Expanded view should show all ten remaining devices, got \(ids.sorted())")
    }

    @Test("The hidden-hub count the app shows is nine, and the collapsed view hides only hubs")
    func hiddenHubCountIsNine() {
        // The app derives its "Show N hubs" caption by diffing the two views.
        let shown = Set(referenceRows(hubs: .endpointsOnly).compactMap { $0.device?.device.id })
        let all = referenceRows(hubs: .all).compactMap { $0.device?.device.id }
        let hidden = all.filter { !shown.contains($0) }
        #expect(hidden.count == 9, "Expected the nine hubs to be the only hidden rows, got \(hidden.sorted())")
        let hubIDs = Set(referenceDevices.filter(\.isHub).map(\.id))
        #expect(Set(hidden) == hubIDs)
    }

    @Test("Collapsed rows carry a hop count only under the other-devices heading")
    func attributedRowsDropTheHopCount() throws {
        // The count stays on rows that could not be placed, where nothing else
        // says how far away the device is. Rows inside a box never carry it
        // (the private chain-step fixtures pin that on a placed adapter).
        let rows = referenceRows(hubs: .endpointsOnly)
        let header = try #require(rows.firstIndex(of: ConnectedDeviceTree.Row(label: "Other USB devices on this port", depth: 0)))
        #expect(!rows[..<header].contains { $0.label.contains("via") },
            "Rows above the heading should not claim a hop count: \(rows.map(\.label))")
        #expect(rows[(header + 1)...].contains { $0.label.contains("via 4 hubs") })
    }

    // MARK: - The layout gate

    @Test("One chain device and no evidence: the devices move under the other-devices heading")
    func singleDeviceNoMatchIsUnchanged() throws {
        // The old layout's device rows, hop counts and all, now under the
        // port's other-devices heading instead of inside the box.
        let switches = [
            sw(id: 100, parent: nil, vendor: "Apple, Inc.", model: "iOS", depth: 0, socketID: "4"),
            sw(id: 200, parent: 100, vendor: "CalDigit, Inc.", model: "TS3 Plus", depth: 1),
        ]
        let devices = [
            usb(1, 0x0310_0000, vid: 0x2109, vendor: "VIA Labs, Inc.", product: "USB3.1 Hub", hub: true, speed: 4),
            usb(2, 0x0311_0000, vid: 0x0BDA, vendor: "Realtek", product: "USB 10/100/1000 LAN", hub: false, speed: 3),
        ]
        let rows = ConnectedDeviceTree.rows(
            devices: devices, port: makePort(),
            thunderboltSwitches: switches, displayPorts: [], hubs: .endpointsOnly
        )
        try #require(rows.count == 3)
        #expect(rows[0].depth == 0)
        #expect(rows[0].label == "CalDigit, Inc. TS3 Plus - Thunderbolt link active at 40 Gbps")
        #expect(rows[1] == ConnectedDeviceTree.Row(label: "Other USB devices on this port", depth: 0))
        #expect(rows[2].depth == 1)
        #expect(rows[2].label.contains("via 1 hub"), "The old layout's hop count still applies: \(rows[2].label)")
    }

    /// One hub and one endpoint on each of two USB controllers. The old layout
    /// groups these under a header per bus; the chain layout does not.
    private var twoBusDevices: [USBDevice] {
        [
            usb(1, 0x0310_0000, vid: 0x2109, vendor: "VIA Labs, Inc.", product: "USB3.1 Hub", hub: true, speed: 4, bus: 0x03),
            usb(2, 0x0311_0000, vid: 0x0BDA, vendor: "Realtek", product: "USB 10/100/1000 LAN", hub: false, speed: 3, bus: 0x03),
            usb(3, 0x2110_0000, vid: 0x2109, vendor: "VIA Labs, Inc.", product: "USB2.0 Hub", hub: true, speed: 2, bus: 0x21),
            usb(4, 0x2111_0000, vid: 0x05AC, vendor: "Apple", product: "Magic Keyboard", hub: false, speed: 1, bus: 0x21),
        ]
    }

    @Test("Old layout: devices spanning two controllers still get a bus header each")
    func oldLayoutKeepsBusHeaders() {
        let switches = [
            sw(id: 100, parent: nil, vendor: "Apple, Inc.", model: "iOS", depth: 0, socketID: "4"),
            sw(id: 200, parent: 100, vendor: "CalDigit, Inc.", model: "TS3 Plus", depth: 1),
        ]
        let rows = ConnectedDeviceTree.rows(
            devices: twoBusDevices, port: makePort(),
            thunderboltSwitches: switches, displayPorts: [], hubs: .endpointsOnly
        )
        #expect(rows.filter { $0.label.hasPrefix("USB bus") }.count == 2,
            "The gate must leave the old layout's bus grouping in place: \(rows.map(\.label))")
    }

    @Test("Chain layout: bus headers are dropped, deliberately")
    func chainLayoutDropsBusHeaders() {
        // `groupedByBus` answers "which devices share a controller"; the chain
        // grouping answers "what is plugged into what", which is the question
        // this section exists for. Stacking both puts back the indentation the
        // grouping removes. The bus stays in `--json` and the Pro screen.
        let switches = [
            sw(id: 100, parent: nil, vendor: "Apple, Inc.", model: "iOS", depth: 0, socketID: "4"),
            sw(id: 200, parent: 100, vendor: "CalDigit, Inc.", model: "TS3 Plus", depth: 1),
            sw(id: 300, parent: 200, vendor: "Seagate", model: "Drive Dock", depth: 2),
        ]
        let rows = ConnectedDeviceTree.rows(
            devices: twoBusDevices, port: makePort(),
            thunderboltSwitches: switches, displayPorts: [], hubs: .endpointsOnly
        )
        #expect(!rows.contains { $0.label.hasPrefix("USB bus") },
            "The chain layout groups by device, not by controller: \(rows.map(\.label))")
        #expect(rows.compactMap { $0.device?.device.id }.sorted() == [2, 4])
    }

    @Test("Old layout: an all-hub port still falls back to showing the hubs")
    func oldLayoutKeepsAllHubFallback() {
        // Collapsing an all-hub port leaves nothing, and an empty "Connected
        // devices" section is worse than showing the plumbing. That fallback is
        // untouched here, and unnecessary in the chain layout, where the chain
        // row carries the section (see `bareDockShowsItselfNotItsPlumbing`).
        let switches = [
            sw(id: 100, parent: nil, vendor: "Apple, Inc.", model: "iOS", depth: 0, socketID: "4"),
            sw(id: 200, parent: 100, vendor: "CalDigit, Inc.", model: "TS3 Plus", depth: 1),
        ]
        let devices = [
            usb(1, 0x0310_0000, vid: 0x2109, vendor: "VIA Labs, Inc.", product: "USB3.1 Hub", hub: true, speed: 4),
            usb(2, 0x0311_0000, vid: 0x2109, vendor: "VIA Labs, Inc.", product: "USB2.0 Hub", hub: true, speed: 2),
        ]
        let rows = ConnectedDeviceTree.rows(
            devices: devices, port: makePort(),
            thunderboltSwitches: switches, displayPorts: [], hubs: .endpointsOnly
        )
        #expect(rows.compactMap { $0.device?.device.id }.sorted() == [1, 2],
            "Expected the fallback to show both hubs: \(rows.map(\.label))")
    }

    @Test("One chain device WITH a name match: the identity endpoint is absorbed, the rest goes under the other-devices heading")
    func singleDeviceWithMatchAbsorbsOnly() throws {
        let switches = [
            sw(id: 100, parent: nil, vendor: "Apple, Inc.", model: "iOS", depth: 0, socketID: "4"),
            sw(id: 200, parent: 100, vendor: "Ugreen Group Limited", model: "TBT5 Docking Station 10-in-1", depth: 1),
        ]
        let devices = [
            usb(1, 0x0310_0000, vid: 0x1D5C, vendor: "Fresco Logic, Inc.", product: "USB2.0 Hub", hub: true, speed: 2),
            usb(2, 0x0311_0000, vid: 0x2B89, vendor: "UGREEN", product: "TBT5 Docking Station 10-in-1", hub: false, speed: 1),
            usb(3, 0x0312_0000, vid: 0x0BDA, vendor: "Realtek", product: "USB 10/100/1000 LAN", hub: false, speed: 3),
        ]
        let rows = ConnectedDeviceTree.rows(
            devices: devices, port: makePort(),
            thunderboltSwitches: switches, displayPorts: [], hubs: .endpointsOnly
        )
        // The Billboard's name marks only itself, so the Fresco hub and the
        // adapter behind it have no evidence.
        try #require(rows.count == 3)
        #expect(rows[0].label.contains("TBT5 Docking Station"))
        #expect(rows[1] == ConnectedDeviceTree.Row(label: "Other USB devices on this port", depth: 0))
        #expect(rows[2].device?.device.id == 3)
        #expect(rows[2].depth == 1)
        #expect(!rows.contains { $0.device?.device.id == 2 })
    }

    @Test("A daisy chain nobody can name shows both devices, and the USB tree under its own heading")
    func unmatchedDaisyChainDegradesSafely() throws {
        // 22 of the 24 multi-device chains in the corpus look like this. The
        // chain rows are read from the fabric so they are exact; the devices are
        // not attributable, so they go under the port's other-devices heading
        // with their hop counts, never under the first hop.
        let switches = [
            sw(id: 100, parent: nil, vendor: "Apple, Inc.", model: "iOS", depth: 0, socketID: "4"),
            sw(id: 200, parent: 100, vendor: "CalDigit, Inc.", model: "TS3 Plus", depth: 1),
            sw(id: 300, parent: 200, vendor: "Seagate", model: "Drive Dock", depth: 2),
        ]
        let devices = [
            usb(1, 0x0310_0000, vid: 0x2109, vendor: "VIA Labs, Inc.", product: "USB3.1 Hub", hub: true, speed: 4),
            usb(2, 0x0311_0000, vid: 0x0BDA, vendor: "Realtek", product: "USB 10/100/1000 LAN", hub: false, speed: 3),
        ]
        let rows = ConnectedDeviceTree.rows(
            devices: devices, port: makePort(),
            thunderboltSwitches: switches, displayPorts: [], hubs: .endpointsOnly
        )
        try #require(rows.count == 4)
        #expect(rows[0].depth == 0 && rows[0].label.contains("TS3 Plus"))
        #expect(rows[1].depth == 1 && rows[1].label.contains("Drive Dock"))
        #expect(rows[2] == ConnectedDeviceTree.Row(label: "Other USB devices on this port", depth: 0), "An unplaceable device is not drawn inside any box")
        #expect(rows[3].depth == 1)
        #expect(rows[3].device?.device.id == 2)
        #expect(rows[3].label.contains("via 1 hub"))
    }

    @Test("A bare dock with nothing plugged in shows the dock, not nine hubs")
    func bareDockShowsItselfNotItsPlumbing() throws {
        // The old layout falls back to the full tree when collapsing leaves
        // nothing, because an empty "Connected devices" section is worse than
        // showing the plumbing. In the chain layout the chain row carries the
        // section, so there is nothing to fall back for.
        let switches = [
            sw(id: 100, parent: nil, vendor: "Apple, Inc.", model: "iOS", depth: 0, socketID: "4"),
            sw(id: 200, parent: 100, vendor: "Ugreen Group Limited", model: "TBT5 Docking Station 10-in-1", depth: 1),
        ]
        let devices = [
            usb(1, 0x0310_0000, vid: 0x1D5C, vendor: "Fresco Logic, Inc.", product: "USB2.0 Hub", hub: true, speed: 2),
            usb(2, 0x0311_0000, vid: 0x2B89, vendor: "UGREEN", product: "TBT5 Docking Station 10-in-1", hub: false, speed: 1),
            usb(3, 0x0311_1000, vid: 0x2109, vendor: "VIA Labs, Inc.", product: "USB2.0 Hub", hub: true, speed: 2),
        ]
        let rows = ConnectedDeviceTree.rows(
            devices: devices, port: makePort(),
            thunderboltSwitches: switches, displayPorts: [], hubs: .endpointsOnly
        )
        try #require(rows.count == 1)
        #expect(rows[0].label.contains("TBT5 Docking Station"))
    }

    @Test("Two first hops on one port: the chain layout refuses and the old one renders")
    func twoFirstHopsFallBack() throws {
        // One connector carries one cable, and on Apple Silicon each host root
        // serves exactly one socket, so this should not exist. If it ever does,
        // the chain layout would put both devices at depth 0 and everything
        // unplaceable at depth 1, where it reads as belonging to whichever came
        // last. Refusing is honest; the old layout shows the first hop only,
        // exactly as it does today.
        let switches = [
            sw(id: 100, parent: nil, vendor: "Apple, Inc.", model: "iOS", depth: 0, socketID: "4"),
            sw(id: 200, parent: 100, vendor: "Ugreen Group Limited", model: "TBT5 Docking Station 10-in-1", depth: 1),
            sw(id: 300, parent: 100, vendor: "CalDigit, Inc.", model: "TS3 Plus", depth: 1),
        ]
        let devices = [
            usb(1, 0x0310_0000, vid: 0x1D5C, vendor: "Fresco Logic, Inc.", product: "USB2.0 Hub", hub: true, speed: 2),
            usb(2, 0x0311_0000, vid: 0x2B89, vendor: "UGREEN", product: "TBT5 Docking Station 10-in-1", hub: false, speed: 1),
            usb(3, 0x0312_0000, vid: 0x0BDA, vendor: "Realtek", product: "USB 10/100/1000 LAN", hub: false, speed: 3),
        ]
        let rows = ConnectedDeviceTree.rows(
            devices: devices, port: makePort(),
            thunderboltSwitches: switches, displayPorts: [], hubs: .endpointsOnly
        )
        let boxRows = rows.filter { $0.depth == 0 && $0 != ConnectedDeviceTree.Row(label: "Other USB devices on this port", depth: 0) }
        #expect(boxRows.count == 1, "Only one box row may sit at depth 0: \(rows.map(\.label))")
        #expect(rows.contains(ConnectedDeviceTree.Row(label: "Other USB devices on this port", depth: 0)), "the devices sit under the other-devices heading")
        // And the identity endpoint is NOT absorbed here, because the old layout
        // knows nothing about attribution.
        #expect(rows.contains { $0.device?.device.id == 2 })
        #expect(rows.contains { $0.device?.device.id == 3 })
    }

    @Test("No Thunderbolt device downstream: the chain layout never runs")
    func noFabricNoChainLayout() throws {
        let devices = [
            usb(1, 0x0310_0000, vid: 0x2109, vendor: "VIA Labs, Inc.", product: "USB3.1 Hub", hub: true, speed: 4),
            usb(2, 0x0311_0000, vid: 0x0BDA, vendor: "Realtek", product: "USB 10/100/1000 LAN", hub: false, speed: 3),
        ]
        let rows = ConnectedDeviceTree.rows(
            devices: devices, port: makePort(), thunderboltSwitches: [], displayPorts: [], hubs: .all
        )
        #expect(rows.count == 2)
        #expect(rows[0].depth == 0, "Without a fabric root there is nothing to indent under")
    }

    @Test("Chain rows carry no USB node, so they render as plain text")
    func chainRowsCarryNoDevice() throws {
        let rows = referenceRows(hubs: .endpointsOnly)
        try #require(rows.count == 5)
        #expect(rows[0].device == nil)
        #expect(rows[1].device == nil)
        #expect(rows[2].device == nil)
        #expect(rows[3].device == nil, "the other-devices heading is plain text too")
        #expect(rows[4].device != nil)
    }

    @Test("Every row's depth is one more than a row above it, so no row hangs in space")
    func depthsAreContiguous() {
        // A gap (depth jumping from 1 to 3) renders as a device indented under
        // nothing, which is the visual bug this whole ticket is about.
        for mode in [ConnectedDeviceTree.HubDisplay.endpointsOnly, .all] {
            let rows = referenceRows(hubs: mode)
            var seen: Set<Int> = []
            for (index, row) in rows.enumerated() {
                if row.depth > 0 {
                    #expect(seen.contains(row.depth - 1),
                        "Row \(index) ('\(row.label)') is at depth \(row.depth) with no depth \(row.depth - 1) above it, mode \(mode)")
                }
                seen.insert(row.depth)
                // A row closes every deeper level.
                seen = seen.filter { $0 <= row.depth }
            }
        }
    }
}
