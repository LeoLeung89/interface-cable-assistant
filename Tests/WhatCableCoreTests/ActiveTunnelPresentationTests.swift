import Foundation
import Testing
@testable import WhatCableCore

/// Unit tests for `ActiveTunnelPresentation`
/// (`Sources/WhatCableCore/Thunderbolt/ActiveTunnelPresentation.swift`): the
/// shared "Video → device · adapter N" line builder used by both the CLI
/// (`TextFormatter`) and the app's technical details view.
///
/// Fixtures mirror `TunnelPathTests`' shape (host root + dock, hand-built
/// `IOThunderboltSwitch`/`IOThunderboltPort` values): no test-kit probe
/// captures `IOThunderboltSwitch` dumps, so this can't be corpus-replayed.
@Suite("ActiveTunnelPresentation: cross-cable tunnel lines")
struct ActiveTunnelPresentationTests {

    // MARK: - Fixtures

    private static let uuidVideo = "AAAAAAAA-0000-0000-0000-000000000001"
    private static let uuidUSB = "BBBBBBBB-0000-0000-0000-000000000002"
    private static let uuidPCIe = "CCCCCCCC-0000-0000-0000-000000000003"
    private static let uuidUnknown = "DDDDDDDD-0000-0000-0000-000000000004"

    private func lanePort(
        portNumber: Int = 1,
        socketID: String? = "1",
        hopTable: [HopTableEntry] = []
    ) -> IOThunderboltPort {
        IOThunderboltPort(
            portNumber: portNumber,
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

    private func protocolPort(
        portNumber: Int,
        adapterType: AdapterType,
        hopTable: [HopTableEntry] = []
    ) -> IOThunderboltPort {
        IOThunderboltPort(
            portNumber: portNumber,
            socketID: nil,
            adapterType: adapterType,
            currentSpeed: nil,
            currentWidth: nil,
            targetWidth: nil,
            rawTargetSpeed: nil,
            linkBandwidthRaw: nil,
            hopTable: hopTable
        )
    }

    private func sw(
        id: Int64,
        depth: Int,
        vendorName: String = "Ugreen Group Limited",
        modelName: String = "TBT5 Docking Station",
        ports: [IOThunderboltPort],
        parentSwitchUID: Int64? = nil
    ) -> IOThunderboltSwitch {
        IOThunderboltSwitch(
            id: id,
            className: depth == 0 ? "IOThunderboltSwitchType5" : "IOThunderboltSwitchType7",
            vendorID: depth == 0 ? 1452 : 0x2B89,
            vendorName: depth == 0 ? "Apple Inc." : vendorName,
            modelName: depth == 0 ? "Mac" : modelName,
            routerID: depth,
            depth: depth,
            routeString: Int64(depth),
            upstreamPortNumber: depth == 0 ? 0 : 1,
            maxPortNumber: 12,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE),
            ports: ports,
            parentSwitchUID: parentSwitchUID
        )
    }

    private func hopEntry(pathUUID: String, counter: Int = 0) -> HopTableEntry {
        HopTableEntry(counter: counter, hopID: 8, dstHopID: 8, dstPort: 1, pathUUID: pathUUID)
    }

    /// Host root + dock with three cross-cable tunnels (video/usb/pcie),
    /// same shape as `TunnelPathTests.hostRootPlusDockThreeTunnels`.
    private func rootAndDockWithThreeTunnels() -> (root: IOThunderboltSwitch, dock: IOThunderboltSwitch) {
        let root = sw(
            id: 100, depth: 0,
            ports: [lanePort(portNumber: 1, hopTable: [
                hopEntry(pathUUID: Self.uuidVideo),
                hopEntry(pathUUID: Self.uuidUSB),
                hopEntry(pathUUID: Self.uuidPCIe),
            ])]
        )
        let dock = sw(
            id: 200, depth: 1,
            ports: [
                protocolPort(portNumber: 5, adapterType: .dpIn, hopTable: [hopEntry(pathUUID: Self.uuidVideo)]),
                protocolPort(portNumber: 6, adapterType: .usb3Down, hopTable: [hopEntry(pathUUID: Self.uuidUSB)]),
                protocolPort(portNumber: 7, adapterType: .pcieDown, hopTable: [hopEntry(pathUUID: Self.uuidPCIe)]),
            ],
            parentSwitchUID: 100
        )
        return (root, dock)
    }

    // MARK: - lines()

    @Test("Cross-cable video/usb/pcie tunnels each render one line, kind → device · adapter N")
    func crossCableThreeTunnelsRenderThreeLines() throws {
        let (root, dock) = rootAndDockWithThreeTunnels()
        let tunnels = ThunderboltTopology.tunnels(from: root, in: [root, dock])
        let lines = ActiveTunnelPresentation.lines(tunnels: tunnels, switches: [root, dock], bundle: _coreLocalizedBundle)
        try #require(lines.count == 3)
        #expect(lines[0] == "Video \u{2192} Ugreen Group Limited TBT5 Docking Station \u{00B7} adapter 5")
        #expect(lines[1] == "USB data \u{2192} Ugreen Group Limited TBT5 Docking Station \u{00B7} adapter 6")
        #expect(lines[2] == "PCIe data \u{2192} Ugreen Group Limited TBT5 Docking Station \u{00B7} adapter 7")
    }

    @Test("Host-internal tunnel (terminal = host root, depth 0) is filtered out")
    func hostInternalTunnelFilteredOut() throws {
        // The UUID is carried only by a protocol adapter ON the host root
        // itself: segmentCount 1, terminal switch = the root (depth 0).
        // Locked design rule: never rendered, it doesn't cross a cable.
        let root = sw(
            id: 100, depth: 0,
            ports: [
                lanePort(portNumber: 1),
                protocolPort(portNumber: 9, adapterType: .pcieDown, hopTable: [hopEntry(pathUUID: Self.uuidPCIe)]),
            ]
        )
        let dock = sw(id: 200, depth: 1, ports: [lanePort(portNumber: 1)], parentSwitchUID: 100)

        let tunnels = ThunderboltTopology.tunnels(from: root, in: [root, dock])
        try #require(tunnels.count == 1)
        #expect(tunnels[0].terminalSwitchUID == 100, "Sanity: terminal really is the host root")

        let lines = ActiveTunnelPresentation.lines(tunnels: tunnels, switches: [root, dock], bundle: _coreLocalizedBundle)
        #expect(lines.isEmpty)
    }

    @Test("Unknown-kind tunnel (no non-lane adapter anywhere) is filtered out")
    func unknownKindTunnelFilteredOut() throws {
        let root = sw(
            id: 100, depth: 0,
            ports: [lanePort(portNumber: 1, hopTable: [hopEntry(pathUUID: Self.uuidUnknown)])]
        )
        let dock = sw(
            id: 200, depth: 1,
            ports: [lanePort(portNumber: 1, hopTable: [hopEntry(pathUUID: Self.uuidUnknown)])],
            parentSwitchUID: 100
        )

        let tunnels = ThunderboltTopology.tunnels(from: root, in: [root, dock])
        try #require(tunnels.count == 1)
        #expect(tunnels[0].kind == .unknown, "Sanity: no non-lane member anywhere in the group")
        #expect(tunnels[0].terminalSwitchUID == 200, "Terminal is downstream (depth 1), so only kind excludes it")

        let lines = ActiveTunnelPresentation.lines(tunnels: tunnels, switches: [root, dock], bundle: _coreLocalizedBundle)
        #expect(lines.isEmpty)
    }

    @Test("Terminal switch has no protocol adapter for this UUID (pass-through lane only): adapter part is dropped")
    func missingTerminalAdapterDropsAdapterPart() throws {
        // Daisy chain: dock's DP adapter gives the kind (video); the deepest
        // switch only carries the UUID on its LANE (a pass-through leg, not
        // a resolved protocol adapter at that depth). Mirrors the "kind
        // derived from ANY non-lane adapter" design note in TunnelPath.swift.
        let root = sw(
            id: 100, depth: 0,
            ports: [lanePort(portNumber: 1, hopTable: [hopEntry(pathUUID: Self.uuidVideo)])]
        )
        let dock = sw(
            id: 200, depth: 1,
            ports: [
                protocolPort(portNumber: 5, adapterType: .dpIn, hopTable: [hopEntry(pathUUID: Self.uuidVideo)]),
                lanePort(portNumber: 2, hopTable: [hopEntry(pathUUID: Self.uuidVideo)]),
            ],
            parentSwitchUID: 100
        )
        let device = sw(
            id: 300, depth: 2,
            vendorName: "Example Corp", modelName: "Passthrough Box",
            ports: [lanePort(portNumber: 1, hopTable: [hopEntry(pathUUID: Self.uuidVideo)])],
            parentSwitchUID: 200
        )

        let tunnels = ThunderboltTopology.tunnels(from: root, in: [root, dock, device])
        try #require(tunnels.count == 1)
        #expect(tunnels[0].kind == .video)
        #expect(tunnels[0].terminalSwitchUID == 300)
        #expect(tunnels[0].terminalAdapterPortNumber == nil, "Sanity: terminal switch's only member is its lane")

        let lines = ActiveTunnelPresentation.lines(tunnels: tunnels, switches: [root, dock, device], bundle: _coreLocalizedBundle)
        try #require(lines.count == 1)
        #expect(lines[0] == "Video \u{2192} Example Corp Passthrough Box", "No '· adapter N' suffix when the port number is unknown")
    }

    @Test("Ordering is preserved: lines follow the tunnels array order (video, usb, pcie)")
    func orderingPreserved() throws {
        let (root, dock) = rootAndDockWithThreeTunnels()
        let tunnels = ThunderboltTopology.tunnels(from: root, in: [root, dock])
        let lines = ActiveTunnelPresentation.lines(tunnels: tunnels, switches: [root, dock], bundle: _coreLocalizedBundle)
        try #require(lines.count == 3)
        #expect(lines[0].hasPrefix("Video"))
        #expect(lines[1].hasPrefix("USB data"))
        #expect(lines[2].hasPrefix("PCIe data"))
    }

    @Test("Empty tunnels input: lines returns []")
    func emptyInputReturnsEmpty() {
        let lines = ActiveTunnelPresentation.lines(tunnels: [], switches: [], bundle: _coreLocalizedBundle)
        #expect(lines.isEmpty)
    }

    @Test("Dock-internal-only tunnel (distinctSwitchCount 1): filtered out even though the terminal switch is depth > 0")
    func dockInternalOnlyTunnelFilteredOutDespiteDownstreamDepth() throws {
        // Mirrors the real ASUS-internal PCIe UUID 93B7660C-35ED-4194-8BA4-
        // A48A9A9A1EDE in research/dumps/tb-fabric/052-joeshaw-m2pro-asus-
        // caldigit-daisychain.md (occurs exactly once, only on the ASUS
        // switch's own PCIe adapter Port 10). Before this fix, kind !=
        // .unknown and terminal depth > 0 were enough on their own to
        // wrongly surface a dock-internal routing detail as a cross-cable
        // tunnel.
        let root = sw(id: 100, depth: 0, ports: [lanePort(portNumber: 1)])
        let dock = sw(
            id: 200, depth: 1,
            ports: [protocolPort(portNumber: 10, adapterType: .pcieDown, hopTable: [hopEntry(pathUUID: Self.uuidPCIe)])],
            parentSwitchUID: 100
        )

        let tunnels = ThunderboltTopology.tunnels(from: root, in: [root, dock])
        try #require(tunnels.count == 1)
        #expect(tunnels[0].kind == .pcie, "Sanity: kind resolves fine")
        #expect(tunnels[0].terminalSwitchUID == 200, "Sanity: terminal really is downstream, depth 1")
        #expect(tunnels[0].distinctSwitchCount == 1, "Sanity: only the dock switch carries this UUID")

        let lines = ActiveTunnelPresentation.lines(tunnels: tunnels, switches: [root, dock], bundle: _coreLocalizedBundle)
        #expect(lines.isEmpty, "Dock-internal path UUID must not render as a cross-cable tunnel")
    }
}
