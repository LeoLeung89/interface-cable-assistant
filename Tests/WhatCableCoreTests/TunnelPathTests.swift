import Foundation
import Testing
@testable import WhatCableCore

/// Fixture tests for `HopTableEntry` parsing (`IOThunderboltPort.from(read:)`)
/// and tunnel grouping (`ThunderboltTopology.tunnels(from:in:)`), both in
/// `Sources/WhatCableCore/Thunderbolt/`.
///
/// See `TunnelPath.swift`'s file header for the "kind is derived from ANY
/// non-lane adapter, not just the host root's" design decision; the "Host
/// root + dock" fixture below is built the same shape the real corpus
/// example that decision is based on (host root LANE carries the UUID,
/// the dock's PROTOCOL adapter carries the matching UUID; the host root
/// itself never has a matching protocol adapter).
@Suite("TunnelPath: hop table parsing and grouping")
struct TunnelPathTests {

    // MARK: - Fixtures

    private static let uuidVideo = "AAAAAAAA-0000-0000-0000-000000000001"
    private static let uuidUSB = "BBBBBBBB-0000-0000-0000-000000000002"
    private static let uuidPCIe = "CCCCCCCC-0000-0000-0000-000000000003"
    private static let uuidHostOnly = "DDDDDDDD-0000-0000-0000-000000000004"

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
        upstreamPortNumber: Int = 0,
        ports: [IOThunderboltPort],
        parentSwitchUID: Int64? = nil
    ) -> IOThunderboltSwitch {
        IOThunderboltSwitch(
            id: id,
            className: depth == 0 ? "IOThunderboltSwitchType5" : "IOThunderboltSwitchType7",
            vendorID: depth == 0 ? 1452 : 0x2B89,
            vendorName: depth == 0 ? "Apple Inc." : "Ugreen Group Limited",
            modelName: depth == 0 ? "Mac" : "TBT5 Docking Station",
            routerID: depth,
            depth: depth,
            routeString: Int64(depth),
            upstreamPortNumber: upstreamPortNumber,
            maxPortNumber: 12,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE),
            ports: ports,
            parentSwitchUID: parentSwitchUID
        )
    }

    private func hopEntry(pathUUID: String, counter: Int = 0) -> HopTableEntry {
        HopTableEntry(counter: counter, hopID: 8, dstHopID: 8, dstPort: 1, pathUUID: pathUUID)
    }

    // MARK: - A1: Hop-entry parsing via IOThunderboltPort.from(read:)

    @Test("Hop Table with all keys parses into one HopTableEntry")
    func hopTableAllKeysParses() throws {
        let dict: [String: Any] = [
            "Port Number": NSNumber(value: 1),
            "Adapter Type": NSNumber(value: 1),
            "Hop Table": [
                [
                    "Counter": NSNumber(value: 0),
                    "Hop ID": NSNumber(value: 8),
                    "Dst Hop ID": NSNumber(value: 9),
                    "Dst Port": NSNumber(value: 3),
                    "Path": "2D7E18C7-3762-4723-B05B-486F6A45963B",
                ]
            ],
        ]
        let port = IOThunderboltPort.from(read: { dict[$0] })
        try #require(port != nil)
        #expect(port?.hopTable.count == 1)
        let entry = port?.hopTable.first
        #expect(entry?.counter == 0)
        #expect(entry?.hopID == 8)
        #expect(entry?.dstHopID == 9)
        #expect(entry?.dstPort == 3)
        #expect(entry?.pathUUID == "2D7E18C7-3762-4723-B05B-486F6A45963B")
    }

    @Test("Hop Table absent entirely: hopTable is empty, port still parses")
    func hopTableAbsentIsEmpty() {
        let dict: [String: Any] = [
            "Port Number": NSNumber(value: 1),
            "Adapter Type": NSNumber(value: 1),
        ]
        let port = IOThunderboltPort.from(read: { dict[$0] })
        #expect(port != nil)
        #expect(port?.hopTable.isEmpty == true)
    }

    @Test("Hop Table present but empty array: hopTable is empty")
    func hopTableEmptyArrayIsEmpty() {
        let dict: [String: Any] = [
            "Port Number": NSNumber(value: 1),
            "Adapter Type": NSNumber(value: 1),
            "Hop Table": [[String: Any]](),
        ]
        let port = IOThunderboltPort.from(read: { dict[$0] })
        #expect(port?.hopTable.isEmpty == true)
    }

    @Test("Hop Table with one malformed entry (missing Path): malformed entry skipped, good entry kept")
    func hopTableMalformedEntrySkipped() {
        let dict: [String: Any] = [
            "Port Number": NSNumber(value: 1),
            "Adapter Type": NSNumber(value: 1),
            "Hop Table": [
                [
                    "Counter": NSNumber(value: 0),
                    "Hop ID": NSNumber(value: 8),
                    "Dst Hop ID": NSNumber(value: 9),
                    "Dst Port": NSNumber(value: 3),
                    // "Path" missing: malformed, must be skipped.
                ],
                [
                    "Counter": NSNumber(value: 1),
                    "Hop ID": NSNumber(value: 10),
                    "Dst Hop ID": NSNumber(value: 11),
                    "Dst Port": NSNumber(value: 5),
                    "Path": "73A55C7B-617A-4308-8C46-9302284AA2E1",
                ],
            ],
        ]
        let port = IOThunderboltPort.from(read: { dict[$0] })
        #expect(port?.hopTable.count == 1, "The malformed entry must be dropped, not crash or produce a bogus entry")
        #expect(port?.hopTable.first?.pathUUID == "73A55C7B-617A-4308-8C46-9302284AA2E1")
    }

    /// Counter is NOT required, and an unreadable one must not cost the tunnel.
    ///
    /// This test previously asserted the whole entry was dropped. The corpus
    /// disproved that expectation: a hop table set up by firmware before macOS
    /// booted carries `Inherited From EFI` in place of `Counter`, and dropping
    /// the row meant those tunnels never reached the Active tunnels list at all
    /// (8 entries across 2 Intel Macs, found by the probe-29 sweep once 326
    /// back-filled machines landed). Counter is a sequence number that nothing
    /// downstream groups on; tunnel reconstruction keys on pathUUID alone. So
    /// the row is kept and the counter falls back to its position, while the
    /// genuinely identifying fields stay required.
    ///
    /// The counter-less row is deliberately placed at index 2, NOT index 0.
    /// With it at index 0 the assertion `counter == 0` would pass just as
    /// happily against an implementation that always defaulted to zero, so the
    /// test could not tell "falls back to the row's position" from "falls back
    /// to a constant". Review caught that. A non-zero index makes the two
    /// outcomes distinguishable.
    @Test("Hop Table entry with a non-numeric Counter is KEPT, with the counter defaulted")
    func hopTableNonNumericFieldSkipped() {
        let dict: [String: Any] = [
            "Port Number": NSNumber(value: 1),
            "Adapter Type": NSNumber(value: 1),
            "Hop Table": [
                [
                    "Counter": NSNumber(value: 40),
                    "Hop ID": NSNumber(value: 1),
                    "Dst Hop ID": NSNumber(value: 2),
                    "Dst Port": NSNumber(value: 1),
                    "Path": "11111111-1111-1111-1111-111111111111",
                ],
                [
                    "Counter": NSNumber(value: 41),
                    "Hop ID": NSNumber(value: 3),
                    "Dst Hop ID": NSNumber(value: 4),
                    "Dst Port": NSNumber(value: 2),
                    "Path": "22222222-2222-2222-2222-222222222222",
                ],
                [
                    "Counter": "not-a-number",
                    "Hop ID": NSNumber(value: 8),
                    "Dst Hop ID": NSNumber(value: 9),
                    "Dst Port": NSNumber(value: 3),
                    "Path": "2D7E18C7-3762-4723-B05B-486F6A45963B",
                ],
            ],
        ]
        let port = IOThunderboltPort.from(read: { dict[$0] })
        #expect(port?.hopTable.count == 3, "an unreadable Counter must not discard a real tunnel")
        #expect(port?.hopTable.last?.pathUUID == "2D7E18C7-3762-4723-B05B-486F6A45963B")
        #expect(port?.hopTable.last?.counter == 2,
            "counter falls back to the row's POSITION (index 2), not to a constant zero")
        // The readable counters on the rows before it must survive untouched,
        // so the fallback cannot be masking a wholesale overwrite.
        #expect(port?.hopTable.first?.counter == 40)
        #expect(port?.hopTable.dropFirst().first?.counter == 41)
        // The identifying fields are still required: drop Path and the row goes.
        var missingPath = dict
        missingPath["Hop Table"] = [["Counter": NSNumber(value: 1), "Hop ID": NSNumber(value: 8),
                                     "Dst Hop ID": NSNumber(value: 9), "Dst Port": NSNumber(value: 3)]]
        #expect(IOThunderboltPort.from(read: { missingPath[$0] })?.hopTable.isEmpty == true)
    }

    @Test("Hop Table with a non-dict element mixed in: valid dict rows kept, the non-dict element skipped")
    func hopTableHeterogeneousArrayKeepsValidDicts() throws {
        // Reads "Hop Table" as `[Any]` and casts each element individually
        // (rather than casting the whole array to `[[String: Any]]` at
        // once), so one malformed element can't take down every good row
        // in the same array with it.
        let dict: [String: Any] = [
            "Port Number": NSNumber(value: 1),
            "Adapter Type": NSNumber(value: 1),
            "Hop Table": [
                [
                    "Counter": NSNumber(value: 0),
                    "Hop ID": NSNumber(value: 8),
                    "Dst Hop ID": NSNumber(value: 9),
                    "Dst Port": NSNumber(value: 3),
                    "Path": "2D7E18C7-3762-4723-B05B-486F6A45963B",
                ],
                "not-a-dict-element",
                [
                    "Counter": NSNumber(value: 1),
                    "Hop ID": NSNumber(value: 10),
                    "Dst Hop ID": NSNumber(value: 11),
                    "Dst Port": NSNumber(value: 5),
                    "Path": "73A55C7B-617A-4308-8C46-9302284AA2E1",
                ],
            ] as [Any],
        ]
        let port = IOThunderboltPort.from(read: { dict[$0] })
        #expect(port?.hopTable.count == 2, "The non-dict element must be dropped, both valid dict rows kept")
        #expect(port?.hopTable.map(\.pathUUID) == [
            "2D7E18C7-3762-4723-B05B-486F6A45963B",
            "73A55C7B-617A-4308-8C46-9302284AA2E1",
        ])
    }

    @Test("Hop Table entry whose Path is not exactly 36 characters is skipped")
    func hopTableShortPathSkipped() throws {
        // Keeps production consistent with TunnelPathCorpusTests'
        // independent `uuidPathRegex`, which only matches Path strings
        // in the full 8-4-4-4-12 UUID shape (36 characters). A shorter
        // string here isn't a well-formed path UUID; grouping on it would
        // risk a bogus collision with an unrelated tunnel.
        let dict: [String: Any] = [
            "Port Number": NSNumber(value: 1),
            "Adapter Type": NSNumber(value: 1),
            "Hop Table": [
                [
                    "Counter": NSNumber(value: 0),
                    "Hop ID": NSNumber(value: 8),
                    "Dst Hop ID": NSNumber(value: 9),
                    "Dst Port": NSNumber(value: 3),
                    "Path": "short-path", // 10 characters, not UUID-shaped
                ],
                [
                    "Counter": NSNumber(value: 1),
                    "Hop ID": NSNumber(value: 10),
                    "Dst Hop ID": NSNumber(value: 11),
                    "Dst Port": NSNumber(value: 5),
                    "Path": "73A55C7B-617A-4308-8C46-9302284AA2E1",
                ],
            ],
        ]
        let port = IOThunderboltPort.from(read: { dict[$0] })
        #expect(port?.hopTable.count == 1, "The 10-character Path must be dropped")
        #expect(port?.hopTable.first?.pathUUID == "73A55C7B-617A-4308-8C46-9302284AA2E1")
    }

    // MARK: - A2: tunnel grouping

    @Test("Host root + dock: three tunnels (video/usb/pcie), each classified, each terminating at the dock's matching protocol adapter")
    func hostRootPlusDockThreeTunnels() throws {
        let root = sw(
            id: 100, depth: 0,
            ports: [lanePort(portNumber: 1, hopTable: [
                hopEntry(pathUUID: Self.uuidVideo),
                hopEntry(pathUUID: Self.uuidUSB),
                hopEntry(pathUUID: Self.uuidPCIe),
            ])]
        )
        let dock = sw(
            id: 200, depth: 1, upstreamPortNumber: 1,
            ports: [
                protocolPort(portNumber: 5, adapterType: .dpIn, hopTable: [hopEntry(pathUUID: Self.uuidVideo)]),
                protocolPort(portNumber: 6, adapterType: .usb3Down, hopTable: [hopEntry(pathUUID: Self.uuidUSB)]),
                protocolPort(portNumber: 7, adapterType: .pcieDown, hopTable: [hopEntry(pathUUID: Self.uuidPCIe)]),
            ],
            parentSwitchUID: 100
        )

        let tunnels = ThunderboltTopology.tunnels(from: root, in: [root, dock])
        try #require(tunnels.count == 3)

        #expect(tunnels[0].kind == .video)
        #expect(tunnels[0].pathUUID == Self.uuidVideo)
        #expect(tunnels[0].terminalSwitchUID == 200)
        #expect(tunnels[0].terminalAdapterPortNumber == 5)
        #expect(tunnels[0].terminalAdapterType == .dpIn)
        #expect(tunnels[0].segmentCount == 2)

        #expect(tunnels[1].kind == .usb)
        #expect(tunnels[1].terminalAdapterPortNumber == 6)
        #expect(tunnels[1].terminalAdapterType == .usb3Down)

        #expect(tunnels[2].kind == .pcie)
        #expect(tunnels[2].terminalAdapterPortNumber == 7)
        #expect(tunnels[2].terminalAdapterType == .pcieDown)

        for t in tunnels {
            #expect(t.originAdapterPortNumber == 1, "Origin must be the host root's lane port")
        }
    }

    @Test("UUID present only on the host root: segmentCount 1, terminal = host root")
    func hostOnlyUUIDSegmentCountOne() throws {
        let root = sw(
            id: 100, depth: 0,
            ports: [
                lanePort(portNumber: 1),
                protocolPort(portNumber: 9, adapterType: .pcieDown, hopTable: [hopEntry(pathUUID: Self.uuidHostOnly)]),
            ]
        )
        let dock = sw(id: 200, depth: 1, upstreamPortNumber: 1, ports: [lanePort(portNumber: 1)], parentSwitchUID: 100)

        let tunnels = ThunderboltTopology.tunnels(from: root, in: [root, dock])
        try #require(tunnels.count == 1)
        #expect(tunnels[0].pathUUID == Self.uuidHostOnly)
        #expect(tunnels[0].segmentCount == 1)
        #expect(tunnels[0].terminalSwitchUID == 100, "Terminal must be the host root itself, not the dock")
        #expect(tunnels[0].kind == .pcie)
    }

    @Test("Empty hop tables everywhere: tunnels returns []")
    func emptyHopTablesReturnsEmpty() {
        let root = sw(id: 100, depth: 0, ports: [lanePort(portNumber: 1)])
        let dock = sw(id: 200, depth: 1, upstreamPortNumber: 1, ports: [lanePort(portNumber: 1)], parentSwitchUID: 100)

        let tunnels = ThunderboltTopology.tunnels(from: root, in: [root, dock])
        #expect(tunnels.isEmpty)
    }

    @Test("Daisy chain: tunnel to the deeper device terminates at depth 2, not the dock")
    func daisyChainTerminatesAtDeepestDevice() throws {
        let root = sw(
            id: 100, depth: 0,
            ports: [lanePort(portNumber: 1, hopTable: [hopEntry(pathUUID: Self.uuidPCIe)])]
        )
        // The dock's downstream lane carries the same UUID: a pass-through
        // hop, not the tunnel's terminus. Mirrors the real CalDigit-behind-
        // ASUS daisy chain in research/dumps/tb-fabric/052-joeshaw-....
        let dock = sw(
            id: 200, depth: 1, upstreamPortNumber: 1,
            ports: [lanePort(portNumber: 2, hopTable: [hopEntry(pathUUID: Self.uuidPCIe)])],
            parentSwitchUID: 100
        )
        let device = sw(
            id: 300, depth: 2, upstreamPortNumber: 1,
            ports: [protocolPort(portNumber: 4, adapterType: .pcieUp, hopTable: [hopEntry(pathUUID: Self.uuidPCIe)])],
            parentSwitchUID: 200
        )

        let tunnels = ThunderboltTopology.tunnels(from: root, in: [root, dock, device])
        try #require(tunnels.count == 1)
        #expect(tunnels[0].terminalSwitchUID == 300, "Terminal must be the deepest device, not the intermediate dock")
        #expect(tunnels[0].terminalAdapterPortNumber == 4)
        #expect(tunnels[0].terminalAdapterType == .pcieUp)
        #expect(tunnels[0].segmentCount == 3)
        #expect(tunnels[0].kind == .pcie)
    }

    @Test("Deterministic ordering: video, usb, pcie, unknown; ties broken by pathUUID")
    func deterministicOrdering() throws {
        // Scrambled UUID order (usb < video alphabetically in the raw
        // strings) so a naive UUID-only sort would put usb first; kind
        // rank must win.
        let uuidUnknown = "ZZZZZZZZ-0000-0000-0000-000000000009"
        let uuidVideoB = "AAAAAAAA-0000-0000-0000-000000000099" // sorts after uuidVideo

        let root = sw(
            id: 100, depth: 0,
            ports: [
                lanePort(portNumber: 1, hopTable: [
                    hopEntry(pathUUID: Self.uuidUSB),
                    hopEntry(pathUUID: Self.uuidPCIe),
                    hopEntry(pathUUID: uuidUnknown),
                    hopEntry(pathUUID: Self.uuidVideo),
                    hopEntry(pathUUID: uuidVideoB),
                ]),
            ]
        )
        let dock = sw(
            id: 200, depth: 1, upstreamPortNumber: 1,
            ports: [
                protocolPort(portNumber: 5, adapterType: .dpOut, hopTable: [hopEntry(pathUUID: Self.uuidVideo)]),
                protocolPort(portNumber: 6, adapterType: .dpOut, hopTable: [hopEntry(pathUUID: uuidVideoB)]),
                protocolPort(portNumber: 7, adapterType: .usb3Up, hopTable: [hopEntry(pathUUID: Self.uuidUSB)]),
                protocolPort(portNumber: 8, adapterType: .pcieUp, hopTable: [hopEntry(pathUUID: Self.uuidPCIe)]),
                // uuidUnknown deliberately has NO non-lane member anywhere.
            ],
            parentSwitchUID: 100
        )

        let tunnels = ThunderboltTopology.tunnels(from: root, in: [root, dock])
        try #require(tunnels.count == 5)
        #expect(tunnels.map(\.kind) == [.video, .video, .usb, .pcie, .unknown])
        // The two video tunnels tie on kind; pathUUID breaks the tie.
        #expect(tunnels[0].pathUUID < tunnels[1].pathUUID)
        #expect(tunnels[0].pathUUID == Self.uuidVideo)
        #expect(tunnels[1].pathUUID == uuidVideoB)
        #expect(tunnels[4].pathUUID == uuidUnknown)
        #expect(tunnels[4].terminalAdapterPortNumber == nil, "Lane-only group: no protocol adapter to report")
    }

    // MARK: - usbTunnelTerminalSwitchUIDs (review round, strict derivation)
    //
    // `TunnelPath.kind == .usb` alone is not a safe filter for "this switch
    // terminates a USB tunnel": kind is classified from ANY classifiable
    // member of the UUID group, while `terminalSwitchUID` is independently
    // the DEEPEST member, so the two can point at different adapters. These
    // two fixtures pin the failure mode a loose `.filter { $0.kind == .usb }
    // .compactMap(\.terminalSwitchUID)` derivation would get wrong, and that
    // `usbTunnelTerminalSwitchUIDs` gets right.

    @Test("A .usb-classified path whose DEEPEST member is lane-only contributes nothing")
    func usbClassifiedPathWithLaneOnlyTerminalContributesNothing() throws {
        let uuid = "11111111-0000-0000-0000-000000000001"
        let root = sw(
            id: 100, depth: 0,
            ports: [lanePort(portNumber: 1, hopTable: [hopEntry(pathUUID: uuid)])]
        )
        // dockA's USB3 adapter is what classifies the whole group as `.usb`
        // (the shallowest classifiable member).
        let dockA = sw(
            id: 200, depth: 1, upstreamPortNumber: 1,
            ports: [
                lanePort(portNumber: 2, hopTable: [hopEntry(pathUUID: uuid)]),
                protocolPort(portNumber: 5, adapterType: .usb3Down, hopTable: [hopEntry(pathUUID: uuid)]),
            ],
            parentSwitchUID: 100
        )
        // dockB is the DEEPEST member (the terminal), but only a lane
        // pass-through carries this UUID there, not a USB adapter: a
        // real corpus shape for a device chained behind a USB hub whose
        // own onward link happens to share the tunnel's path UUID.
        let dockB = sw(
            id: 300, depth: 2, upstreamPortNumber: 1,
            ports: [lanePort(portNumber: 1, hopTable: [hopEntry(pathUUID: uuid)])],
            parentSwitchUID: 200
        )
        let switches = [root, dockA, dockB]

        let tunnels = ThunderboltTopology.tunnels(from: root, in: switches)
        let tunnel = try #require(tunnels.first)
        // Confirms the SHAPE this test depends on: kind says .usb, but the
        // terminal (dockB, the deepest member) carries no classifiable
        // adapter at all.
        #expect(tunnel.kind == .usb)
        #expect(tunnel.terminalSwitchUID == 300)
        #expect(tunnel.terminalAdapterType == nil, "dockB's only member is lane-only: no USB adapter to report")

        let result = ThunderboltTopology.usbTunnelTerminalSwitchUIDs(from: root, in: switches)
        #expect(result.isEmpty, "kind == .usb is not enough: the terminal itself must carry a USB adapter")
    }

    @Test("A single-switch USB UUID group (device-internal routing) contributes nothing")
    func singleSwitchUSBGroupContributesNothing() throws {
        let uuid = "22222222-0000-0000-0000-000000000002"
        let root = sw(id: 100, depth: 0, ports: [lanePort(portNumber: 1)])
        // Both members of this UUID sit on the SAME switch (dock's own two
        // USB adapters sharing an internal routing UUID): never crosses a
        // cable, so distinctSwitchCount is 1, even though kind classifies
        // .usb and the terminal is genuinely a USB adapter type.
        let dock = sw(
            id: 200, depth: 1, upstreamPortNumber: 1,
            ports: [
                lanePort(portNumber: 2),
                protocolPort(portNumber: 5, adapterType: .usb3Down, hopTable: [hopEntry(pathUUID: uuid)]),
                protocolPort(portNumber: 6, adapterType: .usb3Up, hopTable: [hopEntry(pathUUID: uuid)]),
            ],
            parentSwitchUID: 100
        )
        let switches = [root, dock]

        let tunnels = ThunderboltTopology.tunnels(from: root, in: switches)
        let tunnel = try #require(tunnels.first)
        #expect(tunnel.kind == .usb)
        #expect(tunnel.distinctSwitchCount == 1, "both members are on the same switch: device-internal routing")

        let result = ThunderboltTopology.usbTunnelTerminalSwitchUIDs(from: root, in: switches)
        #expect(result.isEmpty, "a UUID confined to one switch never crossed a cable, so it is not a tunnel")
    }

    @Test("The ground-truth shape (LaCie/Studio Display) still resolves under the strict derivation")
    func groundTruthShapeStillResolves() {
        // Sanity check that the stricter derivation does not regress the
        // real case it exists to serve: a genuine cross-cable USB tunnel
        // whose terminal IS its own USB adapter.
        let uuid = "33333333-0000-0000-0000-000000000003"
        let root = sw(id: 100, depth: 0, ports: [lanePort(portNumber: 1, hopTable: [hopEntry(pathUUID: uuid)])])
        let laCie = sw(
            id: 200, depth: 1, upstreamPortNumber: 1,
            ports: [protocolPort(portNumber: 5, adapterType: .usb3Down, hopTable: [hopEntry(pathUUID: uuid)])],
            parentSwitchUID: 100
        )
        let switches = [root, laCie]

        let result = ThunderboltTopology.usbTunnelTerminalSwitchUIDs(from: root, in: switches)
        #expect(result == [200])
    }

    // MARK: - A3: distinctSwitchCount (cross-cable = spans >= 2 switches)

    @Test("UUID that only ever appears on ONE downstream switch: distinctSwitchCount 1, even though the terminal is depth > 0")
    func dockOnlyUUIDDistinctSwitchCountOne() throws {
        // Mirrors the real ASUS-internal PCIe UUID 93B7660C-35ED-4194-8BA4-
        // A48A9A9A1EDE in research/dumps/tb-fabric/052-joeshaw-m2pro-asus-
        // caldigit-daisychain.md (grep -c 93B7660C == 1, only on the ASUS
        // switch's own PCIe adapter Port 10): a dock-internal routing
        // detail, not a tunnel that crossed the cable to reach the dock.
        let root = sw(id: 100, depth: 0, ports: [lanePort(portNumber: 1)])
        let dock = sw(
            id: 200, depth: 1, upstreamPortNumber: 1,
            ports: [protocolPort(portNumber: 10, adapterType: .pcieDown, hopTable: [hopEntry(pathUUID: Self.uuidPCIe)])],
            parentSwitchUID: 100
        )

        let tunnels = ThunderboltTopology.tunnels(from: root, in: [root, dock])
        try #require(tunnels.count == 1)
        #expect(tunnels[0].terminalSwitchUID == 200, "Sanity: terminal really is downstream, depth 1")
        #expect(tunnels[0].kind == .pcie, "Sanity: kind still resolves fine")
        #expect(tunnels[0].distinctSwitchCount == 1, "Only the dock switch carries this UUID")
    }

    @Test("UUID present on host root's lane AND the dock's protocol adapter: distinctSwitchCount 2")
    func hostAndDockUUIDDistinctSwitchCountTwo() throws {
        let root = sw(id: 100, depth: 0, ports: [lanePort(portNumber: 1, hopTable: [hopEntry(pathUUID: Self.uuidVideo)])])
        let dock = sw(
            id: 200, depth: 1, upstreamPortNumber: 1,
            ports: [protocolPort(portNumber: 5, adapterType: .dpIn, hopTable: [hopEntry(pathUUID: Self.uuidVideo)])],
            parentSwitchUID: 100
        )

        let tunnels = ThunderboltTopology.tunnels(from: root, in: [root, dock])
        try #require(tunnels.count == 1)
        #expect(tunnels[0].distinctSwitchCount == 2)
    }

    // MARK: - A4: USB Gen T adapter (TB5-era USB tunnel, 0x210101/0x210102)

    @Test("USB Gen T Adapter (raw 2162945): classifies as .usb, same tunnel kind as USB3 Up/Down")
    func usbGenTAdapterClassifiesAsUSB() throws {
        // research/dumps/tb-fabric/052-nofr1ends-m5pro-ugreen-tb5-dock.md
        // lines 215-217: "Adapter Type = 2162945", Description = "USB Gen
        // T Adapter" on a Ugreen TB5 dock port. 2162945 == 0x210101
        // (usbGenTDown), a TB5-era USB tunneling adapter distinct from the
        // USB3 pair but carrying the same kind of data.
        let uuidGenT = "EEEEEEEE-0000-0000-0000-000000000005"
        let root = sw(id: 100, depth: 0, ports: [lanePort(portNumber: 1, hopTable: [hopEntry(pathUUID: uuidGenT)])])
        let dock = sw(
            id: 200, depth: 1, upstreamPortNumber: 1,
            ports: [protocolPort(portNumber: 11, adapterType: AdapterType.from(rawValue: 2162945), hopTable: [hopEntry(pathUUID: uuidGenT)])],
            parentSwitchUID: 100
        )

        let tunnels = ThunderboltTopology.tunnels(from: root, in: [root, dock])
        try #require(tunnels.count == 1)
        #expect(tunnels[0].kind == .usb, "USB Gen T must classify the same as USB3 Up/Down: it's USB data over the fabric")
        #expect(tunnels[0].terminalAdapterType == .usbGenTDown)
        #expect(tunnels[0].terminalAdapterPortNumber == 11)
    }

    // MARK: - A5: kind/terminal restricted to classifiable adapters (NHI excluded)

    @Test("NHI adapter (host-interface, depth 0) sharing a UUID with a downstream DP adapter: classified .video, not suppressed to .unknown")
    func nhiAdapterDoesNotSuppressClassification() throws {
        // NHI (Adapter Type = 2) exists only on host roots (depth 0). Before
        // this fix, kind classification picked the SHALLOWEST non-lane
        // member; an NHI row sharing this UUID with a real downstream
        // protocol adapter would always win that pick (depth 0 beats any
        // downstream depth), and `tunnelKind(for:)`'s `default` case maps
        // NHI to `.unknown`, silently suppressing a real tunnel. Corpus
        // has 1313 NHI adapters, 3 with populated hop tables, none
        // overlapping today, so this is a fixture, not a corpus replay.
        let root = sw(
            id: 100, depth: 0,
            ports: [protocolPort(portNumber: 2, adapterType: .nhi, hopTable: [hopEntry(pathUUID: Self.uuidVideo)])]
        )
        let dock = sw(
            id: 200, depth: 1, upstreamPortNumber: 1,
            ports: [protocolPort(portNumber: 5, adapterType: .dpOut, hopTable: [hopEntry(pathUUID: Self.uuidVideo)])],
            parentSwitchUID: 100
        )

        let tunnels = ThunderboltTopology.tunnels(from: root, in: [root, dock])
        try #require(tunnels.count == 1)
        #expect(tunnels[0].kind == .video, "The dock's dpOut adapter must classify the tunnel, not the host root's NHI")
        #expect(tunnels[0].terminalSwitchUID == 200)
        #expect(tunnels[0].terminalAdapterPortNumber == 5)
        #expect(tunnels[0].terminalAdapterType == .dpOut)
    }

    // MARK: - A6: deterministic terminal pick

    @Test("Terminal port pick is deterministic regardless of the terminal switch's ports array construction order")
    func terminalPortPickDeterministicRegardlessOfPortsOrder() throws {
        // Two protocol adapters on the SAME terminal switch both carry the
        // UUID (an edge case, but the hop-table read has no ordering
        // guarantee from IOKit). Before this fix, `terminalMembers.first`
        // picked whichever port happened to come first in the `ports:`
        // array the switch was constructed with; sorting by
        // (switch UID, port number) first makes the pick stable no matter
        // which order the ports were read/constructed in.
        let root = sw(id: 100, depth: 0, ports: [lanePort(portNumber: 1, hopTable: [hopEntry(pathUUID: Self.uuidPCIe)])])
        let portLow = protocolPort(portNumber: 5, adapterType: .pcieUp, hopTable: [hopEntry(pathUUID: Self.uuidPCIe)])
        let portHigh = protocolPort(portNumber: 9, adapterType: .usb3Up, hopTable: [hopEntry(pathUUID: Self.uuidPCIe)])

        let dockLowFirst = sw(id: 200, depth: 1, upstreamPortNumber: 1, ports: [portLow, portHigh], parentSwitchUID: 100)
        let dockHighFirst = sw(id: 200, depth: 1, upstreamPortNumber: 1, ports: [portHigh, portLow], parentSwitchUID: 100)

        let tunnelsLowFirst = ThunderboltTopology.tunnels(from: root, in: [root, dockLowFirst])
        let tunnelsHighFirst = ThunderboltTopology.tunnels(from: root, in: [root, dockHighFirst])

        try #require(tunnelsLowFirst.count == 1 && tunnelsHighFirst.count == 1)
        #expect(tunnelsLowFirst[0].terminalAdapterPortNumber == tunnelsHighFirst[0].terminalAdapterPortNumber,
            "Terminal pick must not depend on the switch's ports array order")
        #expect(tunnelsLowFirst[0].terminalAdapterPortNumber == 5, "Sorted by port number, the lower port number wins")
    }

    @Test("Terminal switch pick is deterministic regardless of the switches array feed order (two sibling docks, same depth, same UUID)")
    func terminalSwitchPickDeterministicRegardlessOfSwitchesArrayOrder() throws {
        // Regression lock, not a bug-proving case: sibling switches are
        // already re-sorted by UID inside `ThunderboltTopology.tree(from:
        // in:)`, so this specific shape (two DIRECT children of the same
        // parent) was already order-independent before this fix. Kept
        // alongside `terminalPortPickDeterministicRegardlessOfPortsOrder`
        // (the fixture that DOES fail without the fix, via same-switch
        // port ordering) so the explicit (sw.id, port.portNumber) sort is
        // pinned as the single source of terminal-pick determinism, not
        // an incidental side effect of `tree()`'s own sort.
        let root = sw(id: 100, depth: 0, ports: [lanePort(portNumber: 1, hopTable: [hopEntry(pathUUID: Self.uuidUSB)])])
        let dockA = sw(
            id: 500, depth: 1, upstreamPortNumber: 1,
            ports: [protocolPort(portNumber: 5, adapterType: .usb3Up, hopTable: [hopEntry(pathUUID: Self.uuidUSB)])],
            parentSwitchUID: 100
        )
        let dockB = sw(
            id: 300, depth: 1, upstreamPortNumber: 1,
            ports: [protocolPort(portNumber: 7, adapterType: .usb3Up, hopTable: [hopEntry(pathUUID: Self.uuidUSB)])],
            parentSwitchUID: 100
        )

        let tunnelsABOrder = ThunderboltTopology.tunnels(from: root, in: [root, dockA, dockB])
        let tunnelsBAOrder = ThunderboltTopology.tunnels(from: root, in: [root, dockB, dockA])

        try #require(tunnelsABOrder.count == 1 && tunnelsBAOrder.count == 1)
        #expect(tunnelsABOrder[0].terminalSwitchUID == tunnelsBAOrder[0].terminalSwitchUID,
            "Terminal switch pick must not depend on the switches array feed order")
        #expect(tunnelsABOrder[0].terminalSwitchUID == 300, "Sorted by switch UID, the lower UID (dockB, 300) wins over dockA (500)")
    }
}
