import Foundation
import Testing
@testable import WhatCableCore

/// Tests for Stage B v2 (PCI Path prefix join), the follow-up to the Stage A
/// single-switch shortcut in `PCIeTunnelAttributionTests.swift`. Plan:
/// the private design note "PCIe-tunnelled USB attribution", "Stage B v2: PCI Path prefix
/// join" and "Stage B v2 tests" (items 1-17; corpus replay, item 15, lives in
/// `ThunderboltProbeSweepTests.swift` alongside the rest of the probe-29
/// sweep; mutation demos, item 17, are demonstrated live and logged in
/// `MUTATION-LOG.md` rather than committed as permanently-broken code).
///
/// Fixture construction is duplicated per house rule rather than shared with
/// `PCIeTunnelAttributionTests.swift`, matching that file's own stated
/// convention.
struct PCIeTunnelStageBv2Tests {

    // MARK: - Fixtures

    private func hostRootSwitch(id: Int64, socketID: String, acioRootName: String?) -> IOThunderboltSwitch {
        let lane = IOThunderboltPort(
            portNumber: 1, socketID: socketID, adapterType: .lane,
            currentSpeed: .usb4Tb4, currentWidth: LinkWidth(rawValue: 0x2),
            targetWidth: nil, rawTargetSpeed: nil, linkBandwidthRaw: nil, hopTable: []
        )
        return IOThunderboltSwitch(
            id: id, className: "IOThunderboltSwitchType5", vendorID: 0x5AC,
            vendorName: "Apple Inc.", modelName: "Mac", routerID: 0, depth: 0,
            routeString: 0, upstreamPortNumber: 7, maxPortNumber: 7,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE),
            ports: [lane], parentSwitchUID: nil, acioRootName: acioRootName
        )
    }

    /// A downstream PCIe-only switch (dock/display) carrying a PCIe up-adapter
    /// with the given `PCI Path` / `PCI Entry ID`. `upPath`/`upEntryID` nil
    /// means the switch publishes no usable up-adapter candidate at all
    /// (the completeness gate's missing-input case).
    private func pcieSwitch(
        id: Int64, parent: Int64, depth: Int, model: String = "Dock",
        upPath: String? = nil, upEntryID: UInt64? = nil
    ) -> IOThunderboltSwitch {
        var ports: [IOThunderboltPort] = []
        if upPath != nil || upEntryID != nil {
            ports.append(IOThunderboltPort(
                portNumber: 2, socketID: nil, adapterType: .pcieUp,
                currentSpeed: nil, currentWidth: nil, targetWidth: nil,
                rawTargetSpeed: nil, linkBandwidthRaw: nil,
                pciPath: upPath, pciEntryID: upEntryID
            ))
        }
        return IOThunderboltSwitch(
            id: id, className: "IOThunderboltSwitchType3", vendorID: 0x043E,
            vendorName: "LG Electronics", modelName: model, routerID: depth,
            depth: depth, routeString: Int64(depth), upstreamPortNumber: 1,
            maxPortNumber: 13, supportedSpeed: SupportedSpeedMask(rawValue: 0xE),
            ports: ports, parentSwitchUID: parent
        )
    }

    /// A PCIe-carried USB device, optionally carrying Stage B v2's controller
    /// registry path + ancestor entry ID list. Defaults (nil / []) reproduce
    /// exactly the Stage A-only shape.
    private func pcieDevice(
        id: UInt64, locationID: UInt32, rootName: String?,
        controllerPath: String? = nil, ancestorEntryIDs: [UInt64] = [],
        product: String, vid: UInt16 = 0x043E, isHub: Bool = false
    ) -> USBDevice {
        USBDevice(
            id: id, locationID: locationID, vendorID: vid, productID: 0x9A00,
            vendorName: nil, productName: product, serialNumber: nil,
            usbVersion: nil, speedRaw: 3, busPowerMA: nil, currentMA: nil,
            isThunderboltTunnelled: true,
            tunnelBridgeDepth: nil,
            tunnelRootName: rootName,
            tunnelCarrier: .pcieTunnel,
            tunnelControllerRegistryPath: controllerPath,
            tunnelAncestorEntryIDs: ancestorEntryIDs,
            deviceClass: isHub ? 0x09 : 0x00,
            rawProperties: [:]
        )
    }

    private func usbTunnelDevice(
        id: UInt64, locationID: UInt32, bridgeDepth: Int, rootName: String?,
        product: String, vid: UInt16 = 0x1234
    ) -> USBDevice {
        USBDevice(
            id: id, locationID: locationID, vendorID: vid, productID: 0x1,
            vendorName: nil, productName: product, serialNumber: nil,
            usbVersion: nil, speedRaw: 3, busPowerMA: nil, currentMA: nil,
            isThunderboltTunnelled: true,
            tunnelBridgeDepth: bridgeDepth, tunnelRootName: rootName,
            tunnelCarrier: .usbTunnel,
            deviceClass: 0x09, rawProperties: [:]
        )
    }

    private func makePort(serviceName: String, portNumber: Int) -> AppleHPMInterface {
        AppleHPMInterface(
            id: UInt64(portNumber), serviceName: serviceName,
            className: "AppleHPMInterfaceType10", portDescription: nil,
            portTypeDescription: "USB-C", portNumber: portNumber,
            connectionActive: true, activeCable: nil, opticalCable: nil,
            usbActive: nil, superSpeedActive: nil, usbModeType: nil, usbConnectString: nil,
            transportsSupported: ["CC", "USB2", "USB3", "CIO", "DisplayPort"],
            transportsActive: ["CC", "CIO"], transportsProvisioned: [],
            plugOrientation: nil, plugEventCount: nil, connectionCount: nil, overcurrentCount: nil,
            pinConfiguration: [:], powerCurrentLimits: [], firmwareVersion: nil, bootFlagsHex: nil,
            rawProperties: [:]
        )
    }

    // MARK: - Test 5: end-to-end via TextFormatter.render / JSONFormatter.render

    @Test("Test 5: end-to-end - the LG's real PCI Path strings attribute its devices through TextFormatter.render and JSONFormatter.render")
    func endToEndRealPathStrings() throws {
        let host = hostRootSwitch(id: 1, socketID: "2", acioRootName: "acio1")
        let switchPath = "IOService:/AppleARMPE/arm-io/AppleT602xIO/apciec1@30000000/AppleT6000PCIeC/pcic1-bridge@0/IOPP/pci-bridge@0"
        let lg = pcieSwitch(id: 5, parent: 1, depth: 1, model: "UltraFine 5K", upPath: switchPath, upEntryID: 0x100001442)
        let switches = [host, lg]
        let port = makePort(serviceName: "Port-USB-C@2", portNumber: 2)

        let camera = pcieDevice(
            id: 60, locationID: 0x20543000, rootName: "apciec1",
            controllerPath: switchPath + "/xhci@0", ancestorEntryIDs: [111, 0x100001442],
            product: "LG UltraFine Display Camera"
        )
        let drive = pcieDevice(
            id: 61, locationID: 0x20530000, rootName: "apciec1",
            controllerPath: switchPath + "/xhci@0", ancestorEntryIDs: [111, 0x100001442],
            product: "VLI Product String", vid: 0x1234
        )
        let devices = [camera, drive]

        let textOut = TextFormatter.render(
            ports: [port], sources: [], identities: [], showRaw: false,
            thunderboltSwitches: switches, usbDevices: devices
        )
        for name in ["LG UltraFine Display Camera", "VLI Product String"] {
            let occurrences = textOut.components(separatedBy: name).count - 1
            #expect(occurrences == 1, "\(name) must render exactly once, saw \(occurrences)")
        }
        #expect(!textOut.contains("Other USB devices"), "no flat section when everything is port-scoped")

        let jsonOut = try JSONFormatter.render(
            ports: [port], sources: [], identities: [], showRaw: false,
            thunderboltSwitches: switches, usbDevices: devices
        )
        let root = try #require(try JSONSerialization.jsonObject(with: Data(jsonOut.utf8)) as? [String: Any])
        #expect(root["otherUSBDevices"] == nil)
        let portsJSON = try #require(root["ports"] as? [[String: Any]])
        let lgPort = try #require(portsJSON.first { ($0["name"] as? String) == "Port-USB-C@2" })
        func flatNames(_ nodes: [[String: Any]]) -> [String] {
            nodes.flatMap { node -> [String] in
                [(node["name"] as? String) ?? ""] + flatNames(node["children"] as? [[String: Any]] ?? [])
            }
        }
        let names = flatNames(lgPort["devices"] as? [[String: Any]] ?? [])
        #expect(names.contains("LG UltraFine Display Camera"))
        #expect(names.contains("VLI Product String"))
    }

    // MARK: - Test 1: port parse unit

    @Test("Test 1: IOThunderboltPort.from reads PCI Path/PCI Entry ID on a PCIe adapter, nil on lane/DP/USB adapters")
    func portParsePCIPath() {
        func port(adapterType: UInt32, pciPath: Any?, pciEntryID: Any?) -> IOThunderboltPort? {
            var dict: [String: Any] = ["Port Number": NSNumber(value: 1), "Adapter Type": NSNumber(value: adapterType)]
            if let pciPath { dict["PCI Path"] = pciPath }
            if let pciEntryID { dict["PCI Entry ID"] = pciEntryID }
            return IOThunderboltPort.from(read: { dict[$0] })
        }
        let pcieUp = port(adapterType: 0x100102, pciPath: "IOService:/foo/bar", pciEntryID: NSNumber(value: 123))
        #expect(pcieUp?.pciPath == "IOService:/foo/bar")
        #expect(pcieUp?.pciEntryID == 123)

        let lane = port(adapterType: 0x000001, pciPath: nil, pciEntryID: nil)
        #expect(lane?.pciPath == nil)
        #expect(lane?.pciEntryID == nil)

        let dpOut = port(adapterType: 0x0e0102, pciPath: nil, pciEntryID: nil)
        #expect(dpOut?.pciPath == nil)

        let usb3Up = port(adapterType: 0x200102, pciPath: nil, pciEntryID: nil)
        #expect(usb3Up?.pciPath == nil)
    }

    // MARK: - Test 2: prefix join positive (reporter's real paths)

    @Test("Test 2: prefix join positive - the LG's real PCI Path attributes its controller")
    func prefixJoinPositive() {
        let switchPath = "IOService:/AppleARMPE/arm-io/AppleT602xIO/apciec1@30000000/AppleT6000PCIeC/pcic1-bridge@0/IOPP/pci-bridge@0"
        let controllerPath = switchPath + "/xhci@0"
        let lg = pcieSwitch(id: 5, parent: 1, depth: 1, upPath: switchPath, upEntryID: 0x100001442)
        let chainNodes = [IOThunderboltSwitchNode(sw: lg, depth: 0, children: [])]

        let device = pcieDevice(
            id: 20, locationID: 0x20543000, rootName: "apciec1",
            controllerPath: controllerPath, ancestorEntryIDs: [111, 0x100001442],
            product: "LG UltraFine Display Camera"
        )
        let outcome = ChainDeviceAttribution.resolvePCIeTunnelCandidate(device: device, chainNodes: chainNodes)
        #expect(outcome == .matched(5))
    }

    // MARK: - Test 3: daisy chain

    @Test("Test 3: daisy chain - controller under the deeper switch attributes deeper, under only the shallower attributes shallower")
    func daisyChain() {
        let shallowPath = "IOService:/AppleARMPE/arm-io/apciec2@30000000/pcic2-bridge@0"
        let deepPath = shallowPath + "/IOPP/pci-bridge@1"
        let shallow = pcieSwitch(id: 5, parent: 1, depth: 1, model: "LaCie 1big", upPath: shallowPath, upEntryID: 100)
        let deep = pcieSwitch(id: 6, parent: 5, depth: 2, model: "Studio Display", upPath: deepPath, upEntryID: 200)
        let chainNodes = [
            IOThunderboltSwitchNode(sw: shallow, depth: 0, children: []),
            IOThunderboltSwitchNode(sw: deep, depth: 1, children: [])
        ]

        // Controller under the DEEPER switch's path: matches both (deep's
        // path is a component-wise extension of shallow's), deepest wins.
        let deviceUnderDeep = pcieDevice(
            id: 20, locationID: 0x20543000, rootName: "apciec2",
            controllerPath: deepPath + "/xhci@0", ancestorEntryIDs: [1, 100, 200],
            product: "Studio Display Camera"
        )
        let outcomeDeep = ChainDeviceAttribution.resolvePCIeTunnelCandidate(device: deviceUnderDeep, chainNodes: chainNodes)
        #expect(outcomeDeep == .matched(6), "controller physically under the deeper switch's path must attribute to the deeper switch")

        // Controller under only the SHALLOW switch's path (not the deep
        // extension): only the shallow candidate's entryID/path match.
        let deviceUnderShallow = pcieDevice(
            id: 21, locationID: 0x20544000, rootName: "apciec2",
            controllerPath: shallowPath + "/other-xhci@0", ancestorEntryIDs: [1, 100],
            product: "LaCie Card Reader"
        )
        let outcomeShallow = ChainDeviceAttribution.resolvePCIeTunnelCandidate(device: deviceUnderShallow, chainNodes: chainNodes)
        #expect(outcomeShallow == .matched(5), "controller physically under only the shallow switch's path must attribute to the shallow switch")
    }

    // MARK: - Test 4: host-root-only match

    @Test("Test 4: controller path under the host bridge, not any downstream switch prefix -> port level")
    func hostRootOnlyMatchIsPortLevel() {
        let switchPath = "IOService:/AppleARMPE/arm-io/apciec1@30000000/pcic1-bridge@0/IOPP/pci-bridge@0"
        let lg = pcieSwitch(id: 5, parent: 1, depth: 1, upPath: switchPath, upEntryID: 999)
        let chainNodes = [IOThunderboltSwitchNode(sw: lg, depth: 0, children: [])]

        // Controller sits directly under the host bridge, an entirely
        // different branch from the switch's own PCIe path.
        let device = pcieDevice(
            id: 20, locationID: 0x20543000, rootName: "apciec1",
            controllerPath: "IOService:/AppleARMPE/arm-io/apciec1@30000000/pcic1-bridge@0/IOPP/pci-bridge@9/xhci@0",
            ancestorEntryIDs: [999],
            product: "Unrelated Controller"
        )
        let outcome = ChainDeviceAttribution.resolvePCIeTunnelCandidate(device: device, chainNodes: chainNodes)
        #expect(outcome == .portLevel)
    }

    // MARK: - Test 6: component boundary

    @Test("Test 6: pci-bridge@1 must not prefix-match a controller under pci-bridge@10")
    func componentBoundary() {
        let switchPath = "IOService:/AppleARMPE/arm-io/apciec1@30000000/pcic1-bridge@0/IOPP/pci-bridge@1"
        let lg = pcieSwitch(id: 5, parent: 1, depth: 1, upPath: switchPath, upEntryID: 42)
        let chainNodes = [IOThunderboltSwitchNode(sw: lg, depth: 0, children: [])]

        let device = pcieDevice(
            id: 20, locationID: 0x20543000, rootName: "apciec1",
            controllerPath: "IOService:/AppleARMPE/arm-io/apciec1@30000000/pcic1-bridge@0/IOPP/pci-bridge@10/xhci@0",
            ancestorEntryIDs: [42],
            product: "Sibling Bridge Controller"
        )
        let outcome = ChainDeviceAttribution.resolvePCIeTunnelCandidate(device: device, chainNodes: chainNodes)
        #expect(outcome == .portLevel, "a string-prefix collision across a component boundary must not match")
    }

    // MARK: - Test 7: cross-port

    @Test("Test 7: a controller under apciec1 never matches a switch path under apciec2, even with the rootName gate blinded")
    func crossPortNeverMatchesEvenBlinded() {
        let switchPath = "IOService:/AppleARMPE/arm-io/apciec2@30000000/pcic2-bridge@0"
        let host = hostRootSwitch(id: 1, socketID: "2", acioRootName: "acio2")
        let sw = pcieSwitch(id: 5, parent: 1, depth: 1, upPath: switchPath, upEntryID: 7)
        let switches = [host, sw]
        let chain = ThunderboltTopology.tree(from: host, in: switches)

        // The device's own tunnelRootName names a DIFFERENT port (apciec1),
        // even though its controller path/entryID would otherwise match
        // this port's switch. Explicit expectedTunnelRootName refuses it.
        let device = pcieDevice(
            id: 20, locationID: 0x20543000, rootName: "apciec1",
            controllerPath: switchPath + "/xhci@0", ancestorEntryIDs: [7],
            product: "Cross Port Device"
        )
        let explicit = ChainDeviceAttribution.resolve(
            chain: chain, forest: USBDeviceNode.buildTree(from: [device]),
            usbTunnelSwitchUIDs: [], expectedTunnelRootName: "apciec2"
        )
        #expect(explicit.regionOwner[20] == nil, "explicit expectedTunnelRootName must refuse the cross-port match")

        // "Blinded" variant: expectedTunnelRootName is nil (caller could not
        // derive it), so resolve() falls back to the internal-consistency
        // check. A second device on the SAME resolve() call reporting a
        // DIFFERENT root makes every candidate untrusted, refusing this one
        // too, even without an explicit port check.
        let otherPortDevice = pcieDevice(
            id: 21, locationID: 0x20544000, rootName: "apciec2",
            product: "Same Port Device"
        )
        let blinded = ChainDeviceAttribution.resolve(
            chain: chain, forest: USBDeviceNode.buildTree(from: [device, otherPortDevice]),
            usbTunnelSwitchUIDs: [], expectedTunnelRootName: nil
        )
        #expect(blinded.regionOwner[20] == nil, "blinded internal-consistency fallback must still refuse a disagreeing root")
    }

    // MARK: - Test 8: tie

    @Test("Test 8: two switches with an identical path -> port level")
    func tieBetweenDifferentSwitches() {
        let sharedPath = "IOService:/AppleARMPE/arm-io/apciec1@30000000/pcic1-bridge@0"
        let a = pcieSwitch(id: 5, parent: 1, depth: 1, model: "Dock A", upPath: sharedPath, upEntryID: 1)
        let b = pcieSwitch(id: 6, parent: 1, depth: 1, model: "Dock B", upPath: sharedPath, upEntryID: 2)
        let chainNodes = [
            IOThunderboltSwitchNode(sw: a, depth: 0, children: []),
            IOThunderboltSwitchNode(sw: b, depth: 0, children: [])
        ]
        let device = pcieDevice(
            id: 20, locationID: 0x20543000, rootName: "apciec1",
            controllerPath: sharedPath + "/xhci@0", ancestorEntryIDs: [1, 2],
            product: "Ambiguous Controller"
        )
        let outcome = ChainDeviceAttribution.resolvePCIeTunnelCandidate(device: device, chainNodes: chainNodes)
        #expect(outcome == .portLevel, "two DIFFERENT switches tied at the same depth must refuse, a registry anomaly")
        // Same-switch duplicate-candidate dedup is structurally guaranteed,
        // not a separate scenario to construct: `resolvePCIeTunnelCandidate`
        // takes exactly ONE up-adapter candidate per chain switch (`ports
        // .first(where: { $0.adapterType == .pcieUp })`), and the winner
        // selection collapses via `Set(...matches...map(\.switchID))`, so
        // two matching rows for the SAME switch id can never register as a
        // tie no matter how the candidate was produced.
    }

    // MARK: - Test 9: missing inputs -> exact Stage A behaviour

    @Test("Test 9: nil pciPath everywhere or nil controller path -> exact Stage A behaviour")
    func missingInputsMatchStageA() {
        let host = hostRootSwitch(id: 1, socketID: "2", acioRootName: "acio1")
        let lgNoPath = pcieSwitch(id: 5, parent: 1, depth: 1)
        let lgWithPath = pcieSwitch(
            id: 5, parent: 1, depth: 1,
            upPath: "IOService:/AppleARMPE/arm-io/apciec1@30000000/pcic1-bridge@0", upEntryID: 1
        )
        let device = pcieDevice(id: 20, locationID: 0x20543000, rootName: "apciec1", product: "LG Camera")

        let switchesNoPath = [host, lgNoPath]
        let chainNoPath = ThunderboltTopology.tree(from: host, in: switchesNoPath)
        let resultNoPath = ChainDeviceAttribution.resolve(
            chain: chainNoPath, forest: USBDeviceNode.buildTree(from: [device]),
            usbTunnelSwitchUIDs: [], expectedTunnelRootName: "apciec1"
        )

        // Switch-side data alone (no controller-side data) must make NO
        // difference: the device carries no controller path/entry IDs
        // either way, so step 3's gate fails before the switch's path is
        // ever consulted.
        let switchesWithPath = [host, lgWithPath]
        let chainWithPath = ThunderboltTopology.tree(from: host, in: switchesWithPath)
        let resultWithPath = ChainDeviceAttribution.resolve(
            chain: chainWithPath, forest: USBDeviceNode.buildTree(from: [device]),
            usbTunnelSwitchUIDs: [], expectedTunnelRootName: "apciec1"
        )
        #expect(resultNoPath.regionOwner == resultWithPath.regionOwner)
        #expect(resultNoPath.regionRoots == resultWithPath.regionRoots)
        // Both equal the Stage A single-switch shortcut result (one
        // downstream switch, valid rootName): attributed to switch 5.
        #expect(resultNoPath.regionOwner[20] == 5)
    }

    @Test("Test 9b (review fix, HIGH): a device with no tunnelRootName at all is never Stage-B matched or forced, even with otherwise-perfect Stage B inputs")
    func noRootNameNeverEntersStageB() {
        let host = hostRootSwitch(id: 1, socketID: "2", acioRootName: "acio1")
        let switchPath = "IOService:/AppleARMPE/arm-io/apciec1@30000000/pcic1-bridge@0"
        let lg = pcieSwitch(id: 5, parent: 1, depth: 1, upPath: switchPath, upEntryID: 1)
        let switches = [host, lg]
        let chain = ThunderboltTopology.tree(from: host, in: switches)
        #expect(ThunderboltTopology.flatten(chain).count == 1, "fixture: single downstream switch, where a matched or shortcut outcome would otherwise be reachable")

        // Otherwise-perfect Stage B inputs (valid switch candidate, valid
        // controller path/entry IDs that WOULD match) but rootName is nil:
        // the walk never reached an apciecN root at all (the Stage A
        // failure invariant). Directly at the resolvePCIeTunnelCandidate
        // level: must be fallbackToStageA, not matched, regardless of how
        // good the rest of the evidence looks.
        let device = pcieDevice(
            id: 20, locationID: 0x20543000, rootName: nil,
            controllerPath: switchPath + "/xhci@0", ancestorEntryIDs: [1],
            product: "No Root Controller"
        )
        let chainNodes = ThunderboltTopology.flatten(chain)
        #expect(ChainDeviceAttribution.resolvePCIeTunnelCandidate(device: device, chainNodes: chainNodes) == .fallbackToStageA,
            "a nil tunnelRootName must skip Stage B entirely, never reaching matched or portLevel")

        // Through resolve(), with expectedTunnelRootName also nil (the
        // caller could not derive it either): the device must follow Stage A
        // behaviour and stay fully unattributed. The Stage A shortcut itself
        // requires tunnelRootName != nil (`resolve()`'s pcieTunnel branch),
        // so a nil-root device is refused there too, not just by Stage B.
        let result = ChainDeviceAttribution.resolve(
            chain: chain, forest: USBDeviceNode.buildTree(from: [device]),
            usbTunnelSwitchUIDs: [], expectedTunnelRootName: nil
        )
        #expect(result.regionOwner[20] == nil, "never matched")
        #expect(!result.portLevelBoundaries.contains(20), "never forced to a boundary either -- Stage A behaviour is plain unattributed, not a structural finding")
    }

    // MARK: - Test 10: completeness gate

    @Test("Test 10: chain A -> B, A's path present, B's missing, controller under B -> Stage A behaviour, never A")
    func completenessGateNeverLetsAWinByDefault() {
        let host = hostRootSwitch(id: 1, socketID: "2", acioRootName: "acio1")
        let aPath = "IOService:/AppleARMPE/arm-io/apciec1@30000000/pcic1-bridge@0"
        let a = pcieSwitch(id: 5, parent: 1, depth: 1, model: "Dock A", upPath: aPath, upEntryID: 1)
        let b = pcieSwitch(id: 6, parent: 5, depth: 2, model: "Dock B")  // no up adapter at all
        let switches = [host, a, b]
        let chain = ThunderboltTopology.tree(from: host, in: switches)
        #expect(ThunderboltTopology.flatten(chain).count == 2, "fixture: a 2-switch daisy chain")

        // Controller physically under B (deeper than A's own path).
        let device = pcieDevice(
            id: 20, locationID: 0x20543000, rootName: "apciec1",
            controllerPath: aPath + "/IOPP/pci-bridge@1/xhci@0", ancestorEntryIDs: [1, 2],
            product: "Generic PCIe Controller"
        )
        let result = ChainDeviceAttribution.resolve(
            chain: chain, forest: USBDeviceNode.buildTree(from: [device]),
            usbTunnelSwitchUIDs: [], expectedTunnelRootName: "apciec1"
        )
        // Stage A behaviour on a 2-switch chain is "stays unattributed"
        // (the single-switch shortcut requires exactly one downstream
        // switch). The assertion is "not A", not merely "something
        // reasonable": B's missing candidate must not let A win by default.
        #expect(result.regionOwner[20] != 5, "A must never win by default when B's candidate is missing")
        #expect(result.regionOwner[20] == nil, "a missing input falls back to Stage A behaviour, which is unattributed on a 2-switch chain")
    }

    // MARK: - Test 11: instance identity

    @Test("Test 11: identical path string but a stale (non-member) entry ID -> port level; a matching entry ID attributes")
    func instanceIdentityStaleEntryID() {
        let path = "IOService:/AppleARMPE/arm-io/apciec1@30000000/pcic1-bridge@0"
        let lg = pcieSwitch(id: 5, parent: 1, depth: 1, upPath: path, upEntryID: 555)
        let chainNodes = [IOThunderboltSwitchNode(sw: lg, depth: 0, children: [])]

        // Stale: identical path string, but the controller's ancestor entry
        // IDs never contain 555 (the landing node the adapter names died and
        // was replaced; a new node happens to publish the same path).
        let stale = pcieDevice(
            id: 20, locationID: 0x20543000, rootName: "apciec1",
            controllerPath: path + "/xhci@0", ancestorEntryIDs: [999],
            product: "Stale Controller"
        )
        #expect(ChainDeviceAttribution.resolvePCIeTunnelCandidate(device: stale, chainNodes: chainNodes) == .portLevel)

        // A matching entry ID with a matching path attributes.
        let fresh = pcieDevice(
            id: 21, locationID: 0x20544000, rootName: "apciec1",
            controllerPath: path + "/xhci@0", ancestorEntryIDs: [555],
            product: "Fresh Controller"
        )
        #expect(ChainDeviceAttribution.resolvePCIeTunnelCandidate(device: fresh, chainNodes: chainNodes) == .matched(5))
    }

    // MARK: - Test 12: valid-but-no-match

    @Test("Test 12: all candidates present, controller path valid, zero matches -> port level, NOT the single-switch shortcut")
    func validButNoMatchNeverShortcuts() {
        let host = hostRootSwitch(id: 1, socketID: "2", acioRootName: "acio1")
        let path = "IOService:/AppleARMPE/arm-io/apciec1@30000000/pcic1-bridge@0"
        let lg = pcieSwitch(id: 5, parent: 1, depth: 1, upPath: path, upEntryID: 1)
        let switches = [host, lg]
        let chain = ThunderboltTopology.tree(from: host, in: switches)
        #expect(ThunderboltTopology.flatten(chain).count == 1, "fixture: a single downstream switch, where the shortcut WOULD fire if fallback were taken")

        let device = pcieDevice(
            id: 20, locationID: 0x20543000, rootName: "apciec1",
            controllerPath: "IOService:/AppleARMPE/arm-io/apciec1@30000000/pcic1-bridge@9/xhci@0",
            ancestorEntryIDs: [9999],
            product: "Unrelated Controller"
        )
        let result = ChainDeviceAttribution.resolve(
            chain: chain, forest: USBDeviceNode.buildTree(from: [device]),
            usbTunnelSwitchUIDs: [], expectedTunnelRootName: "apciec1"
        )
        #expect(result.regionOwner[20] == nil, "valid-but-no-match must stay unattributed, never fall through to the single-switch shortcut")
        #expect(result.portLevelBoundaries.contains(20), "valid-but-no-match is a terminal port-level finding, not silence")
    }

    // MARK: - Test 13: path hygiene

    @Test("Test 13: empty/whitespace/non-IOService candidates are unusable and trip the completeness gate, never a \"\" prefix")
    func pathHygieneTripsCompletenessGate() {
        let chainNodesEmptyPath = [IOThunderboltSwitchNode(sw: pcieSwitch(id: 5, parent: 1, depth: 1, upPath: "", upEntryID: 1), depth: 0, children: [])]
        let chainNodesWhitespacePath = [IOThunderboltSwitchNode(sw: pcieSwitch(id: 5, parent: 1, depth: 1, upPath: "   ", upEntryID: 1), depth: 0, children: [])]
        let chainNodesBadPrefix = [IOThunderboltSwitchNode(sw: pcieSwitch(id: 5, parent: 1, depth: 1, upPath: "not-a-registry-path", upEntryID: 1), depth: 0, children: [])]

        // If an empty path were treated as a "" prefix, it would match
        // EVERYTHING; asserting fallbackToStageA rather than .matched proves
        // it does not.
        let device = pcieDevice(
            id: 20, locationID: 0x20543000, rootName: "apciec1",
            controllerPath: "IOService:/anything/at/all", ancestorEntryIDs: [1],
            product: "Any Controller"
        )
        for chainNodes in [chainNodesEmptyPath, chainNodesWhitespacePath, chainNodesBadPrefix] {
            let outcome = ChainDeviceAttribution.resolvePCIeTunnelCandidate(device: device, chainNodes: chainNodes)
            #expect(outcome == .fallbackToStageA, "an unusable candidate path must trip the completeness gate, not act as a wildcard prefix")
        }

        // The controller's OWN path being unusable also gates (step 3).
        let validSwitchChain = [IOThunderboltSwitchNode(sw: pcieSwitch(id: 5, parent: 1, depth: 1, upPath: "IOService:/AppleARMPE/arm-io/apciec1@30000000", upEntryID: 1), depth: 0, children: [])]
        let deviceWithEmptyControllerPath = pcieDevice(
            id: 21, locationID: 0x20544000, rootName: "apciec1",
            controllerPath: "", ancestorEntryIDs: [1],
            product: "Empty Path Controller"
        )
        #expect(ChainDeviceAttribution.resolvePCIeTunnelCandidate(device: deviceWithEmptyControllerPath, chainNodes: validSwitchChain) == .fallbackToStageA)
    }

    @Test("Test 13b (review fix, MEDIUM): leading/trailing whitespace is unusable, not silently trimmed - one-sided whitespace never lands in forcedPortLevel, matching whitespace both sides never attributes")
    func pathHygieneRejectsRatherThanNormalisesWhitespace() {
        let cleanSwitchPath = "IOService:/AppleARMPE/arm-io/apciec1@30000000/pcic1-bridge@0"

        // A candidate path carrying leading or trailing whitespace must trip
        // the completeness gate exactly like empty/malformed did above (the
        // OLD code validated the TRIMMED string but returned/compared the
        // UNTRIMMED one, so these previously passed hygiene).
        let leadingSpaceChain = [IOThunderboltSwitchNode(sw: pcieSwitch(id: 5, parent: 1, depth: 1, upPath: " " + cleanSwitchPath, upEntryID: 1), depth: 0, children: [])]
        let trailingNewlineChain = [IOThunderboltSwitchNode(sw: pcieSwitch(id: 5, parent: 1, depth: 1, upPath: cleanSwitchPath + "\n", upEntryID: 1), depth: 0, children: [])]
        let device = pcieDevice(
            id: 20, locationID: 0x20543000, rootName: "apciec1",
            controllerPath: cleanSwitchPath + "/xhci@0", ancestorEntryIDs: [1],
            product: "Any Controller"
        )
        for chainNodes in [leadingSpaceChain, trailingNewlineChain] {
            #expect(ChainDeviceAttribution.resolvePCIeTunnelCandidate(device: device, chainNodes: chainNodes) == .fallbackToStageA,
                "whitespace-carrying candidate path must be unusable, tripping the completeness gate")
        }

        // One-sided whitespace: the SWITCH path is clean, but the
        // CONTROLLER's path carries a leading space. The OLD code would
        // compare the untrimmed controller path against the clean candidate
        // path, find no match (the leading space breaks equality/prefix),
        // and land in `.portLevel` (a STRUCTURAL "valid-but-no-match"
        // finding) instead of the correct `.fallbackToStageA` (the input
        // itself is unusable, not evidence of anything).
        let cleanSwitchChain = [IOThunderboltSwitchNode(sw: pcieSwitch(id: 5, parent: 1, depth: 1, upPath: cleanSwitchPath, upEntryID: 1), depth: 0, children: [])]
        let oneSidedWhitespaceDevice = pcieDevice(
            id: 21, locationID: 0x20544000, rootName: "apciec1",
            controllerPath: " " + cleanSwitchPath + "/xhci@0", ancestorEntryIDs: [1],
            product: "Leading Space Controller"
        )
        #expect(ChainDeviceAttribution.resolvePCIeTunnelCandidate(device: oneSidedWhitespaceDevice, chainNodes: cleanSwitchChain) == .fallbackToStageA,
            "one-sided whitespace on the controller path must fall back, never land in forcedPortLevel")

        // Matching whitespace on BOTH sides: switch path and controller path
        // carry the IDENTICAL leading space. The OLD code's raw-string
        // comparison would actually still line up (both carry the same
        // corruption consistently) and could attribute a device based on
        // data that never should have passed hygiene at all. The fix
        // refuses both inputs outright, regardless of whether they'd
        // "agree".
        let matchingWhitespaceChain = [IOThunderboltSwitchNode(sw: pcieSwitch(id: 5, parent: 1, depth: 1, upPath: " " + cleanSwitchPath, upEntryID: 1), depth: 0, children: [])]
        let matchingWhitespaceDevice = pcieDevice(
            id: 22, locationID: 0x20545000, rootName: "apciec1",
            controllerPath: " " + cleanSwitchPath + "/xhci@0", ancestorEntryIDs: [1],
            product: "Matching Whitespace Controller"
        )
        #expect(ChainDeviceAttribution.resolvePCIeTunnelCandidate(device: matchingWhitespaceDevice, chainNodes: matchingWhitespaceChain) == .fallbackToStageA,
            "identical whitespace corruption on both sides must still refuse, never attribute")
    }

    // MARK: - Test 16: terminal port level (representative subset)

    @Test("Test 16a: a Stage B match contradicted by an exact name match on a DIFFERENT switch -> forcedPortLevel, never let the later pass decide")
    func contradictionForcesPortLevel() {
        let host = hostRootSwitch(id: 1, socketID: "2", acioRootName: "acio1")
        // BOTH switches carry a valid, DISTINCT up-adapter, so the
        // completeness gate passes and the Stage B join runs for real
        // (rather than accidentally falling back to the Stage A shortcut
        // because one switch was missing path data).
        let aPath = "IOService:/AppleARMPE/arm-io/apciec1@30000000/pcic1-bridge@1"
        let bPath = "IOService:/AppleARMPE/arm-io/apciec1@30000000/pcic1-bridge@0"
        let a = pcieSwitch(id: 5, parent: 1, depth: 1, model: "Dock A", upPath: aPath, upEntryID: 2)
        let b = pcieSwitch(id: 6, parent: 1, depth: 1, model: "Dock B", upPath: bPath, upEntryID: 1)
        let switches = [host, a, b]
        let chain = ThunderboltTopology.tree(from: host, in: switches)

        // Stage B structurally matches B, but the device's own product name
        // is an EXACT match for A's model name: the two signals disagree.
        let device = pcieDevice(
            id: 20, locationID: 0x20543000, rootName: "apciec1",
            controllerPath: bPath + "/xhci@0", ancestorEntryIDs: [1],
            product: "Dock A"
        )
        let result = ChainDeviceAttribution.resolve(
            chain: chain, forest: USBDeviceNode.buildTree(from: [device]),
            usbTunnelSwitchUIDs: [], expectedTunnelRootName: "apciec1"
        )
        #expect(result.regionOwner[20] == nil, "a Stage B/name contradiction must not resolve to either candidate")
        #expect(result.portLevelBoundaries.contains(20), "the contradiction is a TERMINAL forcedPortLevel outcome")
        #expect(!result.absorbed.contains(20), "a forced device is never absorbed, even though its name exactly matched a switch")
    }

    @Test("Test 16b: valid-but-no-match still lands at port level even with an otherwise-winning exact name match")
    func validNoMatchStaysPortLevelDespiteLegacyEvidence() {
        let host = hostRootSwitch(id: 1, socketID: "2", acioRootName: "acio1")
        let a = pcieSwitch(id: 5, parent: 1, depth: 1, model: "Dock A", upPath: "IOService:/AppleARMPE/arm-io/apciec1@30000000/pcic1-bridge@0", upEntryID: 1)
        let switches = [host, a]
        let chain = ThunderboltTopology.tree(from: host, in: switches)

        // Zero Stage B matches (controller path is unrelated), but the
        // product name exactly matches the sole chain device's model name:
        // legacy evidence that would otherwise win outright.
        let device = pcieDevice(
            id: 20, locationID: 0x20543000, rootName: "apciec1",
            controllerPath: "IOService:/AppleARMPE/arm-io/apciec1@30000000/pcic1-bridge@9/xhci@0",
            ancestorEntryIDs: [9999],
            product: "Dock A"
        )
        let result = ChainDeviceAttribution.resolve(
            chain: chain, forest: USBDeviceNode.buildTree(from: [device]),
            usbTunnelSwitchUIDs: [], expectedTunnelRootName: "apciec1"
        )
        #expect(result.regionOwner[20] == nil)
        #expect(result.portLevelBoundaries.contains(20))
        #expect(!result.absorbed.contains(20), "structural evidence saying 'outside every switch' must not be outvoted by a name match")
    }

    @Test("Test 16c: a forced hub is never a claim TARGET - a non-forced child's redirected claim downgrades to itself")
    func forcedHubRefusesRedirectedClaim() {
        let host = hostRootSwitch(id: 1, socketID: "2", acioRootName: "acio1")
        // Valid up-adapter so a genuine `.portLevel` finding is possible
        // (a switch with no candidate at all would instead fall back to the
        // Stage A single-switch shortcut, which is a different scenario).
        let a = pcieSwitch(
            id: 5, parent: 1, depth: 1, model: "TS5",
            upPath: "IOService:/AppleARMPE/arm-io/apciec1@30000000/pcic1-bridge@0",
            upEntryID: 1
        )
        let switches = [host, a]
        let chain = ThunderboltTopology.tree(from: host, in: switches)

        // Forced hub H: PCIe-carried, controller data present but pointing
        // at an unrelated branch (a genuine `.portLevel` finding), no name
        // evidence, itself a hub (isHub: true) so it is eligible to be a
        // claim target.
        let hub = pcieDevice(
            id: 30, locationID: 0x20540000, rootName: "apciec1",
            controllerPath: "IOService:/AppleARMPE/arm-io/apciec1@30000000/pcic1-bridge@9/xhci@0",
            ancestorEntryIDs: [9999],
            product: "Some Hub Chip", isHub: true
        )
        // Non-forced child of the hub, whose product name is an EXACT match
        // for chain device A ("TS5"), so it is A's identity device and
        // claims A for itself. It sits on the dock's own PCIe xHCI, so it
        // carries the PCIe tunnel carrier (A publishes no USB3 adapter, and
        // only a PCIe-carried SuperSpeed device can be its identity device).
        // No root name, so the Stage A shortcut does not place it instead.
        let child = USBDevice(
            id: 31, locationID: 0x20540010, vendorID: 0x1234, productID: 0x1,
            vendorName: nil, productName: "TS5", serialNumber: nil,
            usbVersion: nil, speedRaw: 3, busPowerMA: nil, currentMA: nil,
            isThunderboltTunnelled: true, tunnelCarrier: .pcieTunnel,
            rawProperties: [:]
        )
        let forest = USBDeviceNode.buildTree(from: [hub, child])
        let result = ChainDeviceAttribution.resolve(
            chain: chain, forest: forest,
            usbTunnelSwitchUIDs: [], expectedTunnelRootName: "apciec1"
        )
        #expect(result.portLevelBoundaries.contains(30), "fixture: the hub itself must be the forced boundary")
        #expect(result.regionOwner[30] == nil, "a forced hub must never become owned/regionRoot")
        #expect(result.regionRoots[30] == nil, "a forced hub must never become a regionRoot (claim target)")
        // The child's own claim downgrades to itself rather than promoting
        // onto the forced hub (conservative, per the plan).
        #expect(result.regionOwner[31] == 5, "the child keeps its own identity evidence, never promoted onto the forced hub")
    }

    @Test("Test 16f: a forced node below an attributed ancestor renders in BOTH collapsed and expanded views (the vanishing-node case)")
    func forcedNodeBelowAttributedAncestorNeverVanishes() {
        let host = hostRootSwitch(id: 1, socketID: "2", acioRootName: "acio1")
        // Review fix (MEDIUM, round 2026-08-13): the original fixture gave
        // `a` no up-adapter at all, so `forced` below tripped the
        // COMPLETENESS gate and took the Stage A single-switch shortcut
        // (chainNodes.count == 1, tunnelRootName != nil): it was actually
        // ATTRIBUTED to switch A, never forced, and the test only passed
        // because it happened to still render (attributed devices render
        // too). A valid up-adapter here is what makes a genuine `.portLevel`
        // finding reachable.
        let a = pcieSwitch(
            id: 5, parent: 1, depth: 1, model: "Dock A",
            upPath: "IOService:/AppleARMPE/arm-io/apciec1@30000000/pcic1-bridge@0",
            upEntryID: 1
        )
        let switches = [host, a]

        // Attributed hub: its product name exactly matches chain device A,
        // so it is absorbed/owns a region.
        let ownedHub = USBDevice(
            id: 40, locationID: 0x20540000, vendorID: 0x1234, productID: 0x1,
            vendorName: nil, productName: "Dock A", serialNumber: nil,
            usbVersion: nil, speedRaw: 3, busPowerMA: nil, currentMA: nil,
            deviceClass: 0x09, rawProperties: [:]
        )
        // Forced boundary node, nested BELOW the attributed hub in the USB
        // tree (child locationID clears one nibble of the parent's).
        // Complete but NON-MATCHING controller evidence: a genuine
        // `.portLevel` structural finding, not a missing-data fallback.
        let forced = pcieDevice(
            id: 41, locationID: 0x20540010, rootName: "apciec1",
            controllerPath: "IOService:/AppleARMPE/arm-io/apciec1@30000000/pcic1-bridge@9/xhci@0",
            ancestorEntryIDs: [9999],
            product: "PCIe-carried controller under Dock A"
        )
        let forest = USBDeviceNode.buildTree(from: [ownedHub, forced])
        #expect(forest.first?.children.contains { $0.device.id == 41 } == true, "fixture: forced must be a genuine child of the owned hub")

        // Review fix (MEDIUM, round 2026-08-13): the original inline port
        // fixture here used serviceName "Port-USB-C@1" (socketID "1")
        // against a host switch whose OWN socketID is "2" (mismatched), AND
        // `transportsSupported: ["CC"]` alone, which fails `carriesData`
        // (requires one of USB2/USB3/USB4/CIO/DisplayPort). BOTH gaps
        // independently make `thunderboltHostRoot(port:switches:)` return
        // nil, so `ConnectedDeviceTree.rows` silently took the "no
        // Thunderbolt device downstream" flat-device-list fallback instead
        // of the chain-attribution-aware render path this test exists to
        // exercise: every assertion below was passing VACUOUSLY (a flat
        // list also renders each device once). `makePort` (the same helper
        // Test 5's genuine end-to-end test uses) with a matching socketID
        // fixes both gaps at once.
        let port = makePort(serviceName: "Port-USB-C@2", portNumber: 2)
        // Review fix (MEDIUM): confirm the fixture actually produces the
        // boundary it claims to, at the attribution level, not just "some
        // row renders somewhere".
        let chain = ThunderboltTopology.tree(from: host, in: switches)
        let result = ChainDeviceAttribution.resolve(
            chain: chain, forest: forest,
            usbTunnelSwitchUIDs: [], expectedTunnelRootName: "apciec1"
        )
        #expect(result.portLevelBoundaries.contains(41), "fixture: 41 must be a genuine forcedPortLevel boundary")
        #expect(result.regionOwner[41] == nil, "fixture: 41 must not be owned by Dock A")

        let expandedRows = ConnectedDeviceTree.rows(
            devices: [ownedHub, forced], port: port, thunderboltSwitches: switches,
            displayPorts: [], hubs: .all
        )
        let collapsedRows = ConnectedDeviceTree.rows(
            devices: [ownedHub, forced], port: port, thunderboltSwitches: switches,
            displayPorts: [], hubs: .endpointsOnly
        )
        // Exactly once in each view: not zero (the vanishing-node bug this
        // test exists to catch), and not twice (rendered once inside Dock
        // A's owned group AND once in the port-level leftovers, which
        // `result.regionOwner[41] == nil` above already rules out as the
        // owned placement, so a count of 1 here confirms it renders from
        // the port-level group specifically, not both).
        #expect(expandedRows.filter { $0.device?.device.id == 41 }.count == 1, "expanded view must render the forced node exactly once, from the port-level group")
        #expect(collapsedRows.filter { $0.device?.device.id == 41 }.count == 1, "collapsed view must render the forced node exactly once, from the port-level group")
    }

    @Test("Test 16g: a mixed forest - an independent .usbTunnel subtree below a boundary root still cuts out into its own region")
    func independentSubtreeBelowBoundaryStillCutsOut() {
        let host = hostRootSwitch(id: 1, socketID: "2", acioRootName: "acio1")
        // Valid up-adapter on the forced switch so the join genuinely runs
        // (rather than tripping the completeness gate, which would just
        // leave the device unattributed instead of `forcedPortLevel`).
        let forcedSwitch = pcieSwitch(
            id: 5, parent: 1, depth: 1, model: "Forced Dock",
            upPath: "IOService:/AppleARMPE/arm-io/apciec1@30000000/pcic1-bridge@0",
            upEntryID: 1
        )
        // Also needs a valid up-adapter: the completeness gate (step 2) is
        // PORT-WIDE, so if this sibling switch lacked one, the whole port
        // would fall back to Stage A regardless of `forcedSwitch`'s own
        // data, which is a different scenario from the one this test wants
        // (a genuine `.portLevel` finding coexisting with an unrelated,
        // independently-anchored usbTunnel subtree).
        let otherSwitchUpPort = IOThunderboltPort(
            portNumber: 2, socketID: nil, adapterType: .pcieUp,
            currentSpeed: nil, currentWidth: nil, targetWidth: nil,
            rawTargetSpeed: nil, linkBandwidthRaw: nil,
            pciPath: "IOService:/AppleARMPE/arm-io/apciec1@30000000/pcic1-bridge@2",
            pciEntryID: 3
        )
        let otherSwitch = IOThunderboltSwitch(
            id: 6, className: "IOThunderboltSwitchIntelJHL8440", vendorID: 0x8087,
            vendorName: "CalDigit, Inc.", modelName: "Other Dock", routerID: 1,
            depth: 1, routeString: 1, upstreamPortNumber: 1, maxPortNumber: 13,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE), ports: [otherSwitchUpPort],
            parentSwitchUID: 1
        )
        let switches = [host, forcedSwitch, otherSwitch]
        let chain = ThunderboltTopology.tree(from: host, in: switches)

        // Controller path points at an unrelated branch: a genuine
        // `.portLevel` finding, not a missing-data fallback.
        let forced = pcieDevice(
            id: 50, locationID: 0x20540000, rootName: "apciec1",
            controllerPath: "IOService:/AppleARMPE/arm-io/apciec1@30000000/pcic1-bridge@9/xhci@0",
            ancestorEntryIDs: [9999],
            product: "Forced Boundary Controller"
        )
        // Independently anchored USB-tunnel device, structurally matched by
        // bridge depth to `otherSwitch` (id 6), nested as a CHILD of the
        // forced node in the USB tree.
        let anchored = usbTunnelDevice(
            id: 51, locationID: 0x20540010, bridgeDepth: 2, rootName: "apciec1",
            product: "Independently Anchored Device"
        )
        let forest = USBDeviceNode.buildTree(from: [forced, anchored])
        #expect(forest.first?.children.contains { $0.device.id == 51 } == true, "fixture: anchored must be a genuine child of forced")

        let result = ChainDeviceAttribution.resolve(
            chain: chain, forest: forest,
            usbTunnelSwitchUIDs: [6], expectedTunnelRootName: "apciec1"
        )
        #expect(result.portLevelBoundaries.contains(50))
        #expect(result.regionOwner[50] == nil)
        #expect(result.regionOwner[51] == 6, "an independently anchored subtree below a boundary must still cut out into its own chain region")
    }

    @Test("Test 16i: redundant-root removal must not let a mark ABOVE the boundary erase a self-anchored root BELOW it")
    func selfAnchoredRootBelowBoundarySurvivesRedundantRemoval() throws {
        let host = hostRootSwitch(id: 1, socketID: "2", acioRootName: "acio1")
        // Valid up-adapter so `forced` below gets a genuine `.portLevel`
        // finding rather than the Stage A shortcut (which would fire on a
        // single-downstream-switch chain with no controller data at all).
        let a = pcieSwitch(
            id: 5, parent: 1, depth: 1, model: "Dock A",
            upPath: "IOService:/AppleARMPE/arm-io/apciec1@30000000/pcic1-bridge@0",
            upEntryID: 1
        )
        let switches = [host, a]
        let chain = ThunderboltTopology.tree(from: host, in: switches)

        // Attributed ancestor: Stage B places this hub in A by position
        // (its controller path sits under A's PCI Path and A's entry ID is
        // an ancestor), so the mark ABOVE the boundary is a position mark.
        // An identity hub alone is not marked, so position is what gives
        // the redundant-root walk a mark above to stop short of. Its name
        // also matches A, which agrees with its position and changes
        // nothing. The self-anchored identity device below sits on Dock A's
        // own PCIe xHCI too, so it carries the PCIe tunnel carrier: Dock A
        // publishes no USB3 adapter, and only a PCIe-carried SuperSpeed
        // device can be its identity device. It has no root name, so the
        // Stage A shortcut does not place it.
        let ownedHub = pcieDevice(
            id: 60, locationID: 0x20540000, rootName: "apciec1",
            controllerPath: "IOService:/AppleARMPE/arm-io/apciec1@30000000/pcic1-bridge@0/xhci@0",
            ancestorEntryIDs: [1],
            product: "Dock A", vid: 0x1234, isHub: true
        )
        // Forced boundary, child of the owned hub: controller path points
        // at an unrelated branch (a genuine `.portLevel` finding).
        // Review fix (LOW, round 2026-08-13): relocated from 0x20540010 to
        // 0x20541000 (nibble n3 instead of n1) to leave n2/n1/n0 free for a
        // deeper descendant below -- `USBDevice.parentLocationID` clears the
        // LOWEST nonzero nibble, so a device whose lowest nibble is already
        // at shift 0 (as the old 0x20540011 was) is structurally a leaf and
        // can never have a child under this scheme, which silently made the
        // original fixture's "below the boundary" subtree exactly one node
        // deep with no way to prove anything propagates further.
        let forced = pcieDevice(
            id: 61, locationID: 0x20541000, rootName: "apciec1",
            controllerPath: "IOService:/AppleARMPE/arm-io/apciec1@30000000/pcic1-bridge@9/xhci@0",
            ancestorEntryIDs: [9999],
            product: "Forced Boundary Controller"
        )
        // Self-anchored root below the boundary: ITS OWN product name is
        // ALSO an exact match for "Dock A" (a second identity endpoint), a
        // genuine self-anchoring claim, nested as a child of `forced`.
        let selfAnchored = USBDevice(
            id: 62, locationID: 0x20541100, vendorID: 0x1234, productID: 0x2,
            vendorName: nil, productName: "Dock A", serialNumber: nil,
            usbVersion: nil, speedRaw: 3, busPowerMA: nil, currentMA: nil,
            isThunderboltTunnelled: true, tunnelCarrier: .pcieTunnel,
            rawProperties: [:]
        )
        // A plain child of the self-anchored device, carrying no evidence
        // of its own. `selfAnchored` is itself an EXACT name match (like
        // `ownedHub`), so it is `absorbed` (its own row is suppressed in
        // favour of its children, exactly like `ownedHub`'s identity
        // endpoint is): this device is what makes the "62's mark survives
        // and its subtree renders nested under A" claim checkable at the
        // Row level, since an absorbed leaf with no children of its own
        // renders nothing to look at.
        let belowSelfAnchored = USBDevice(
            id: 63, locationID: 0x20541110, vendorID: 0x9999, productID: 0x1,
            vendorName: nil, productName: "Generic Component", serialNumber: nil,
            usbVersion: nil, speedRaw: 3, busPowerMA: nil, currentMA: nil,
            rawProperties: [:]
        )
        let forest = USBDeviceNode.buildTree(from: [ownedHub, forced, selfAnchored, belowSelfAnchored])
        let forcedNode = forest.first?.children.first { $0.device.id == 61 }
        let selfAnchoredNode = forcedNode?.children.first { $0.device.id == 62 }
        #expect(forcedNode?.children.contains { $0.device.id == 62 } == true, "fixture: selfAnchored must be a genuine child of forced")
        #expect(selfAnchoredNode?.children.contains { $0.device.id == 63 } == true, "fixture: belowSelfAnchored must be a genuine child of selfAnchored")

        let result = ChainDeviceAttribution.resolve(
            chain: chain, forest: forest,
            usbTunnelSwitchUIDs: [], expectedTunnelRootName: "apciec1"
        )
        #expect(result.portLevelBoundaries.contains(61))
        #expect(result.regionOwner[61] == nil)
        // The self-anchored device below the boundary must be absorbed as
        // its own identity endpoint (exact name match to A), NOT erased by
        // redundant-root removal treating the OWNED HUB's mark above the
        // boundary as already covering it.
        #expect(result.regionRoots[60] == 5, "fixture: Stage B gives the owned hub above the boundary its own position mark, so there is a mark above to cover 62")
        #expect(result.absorbed.contains(62), "self-anchoring claim below a boundary must survive, not be silently covered by a mark above the boundary")
        // Review fix (LOW, round 2026-08-13): `absorbed` alone never
        // consults `regionRoots`, so this test previously gave zero real
        // coverage of the actual redundant-root-removal rule (step 5's
        // ancestor walk stopping at the boundary rather than crossing it):
        // a version with the boundary check DELETED still passed, because
        // `absorbed` is populated straight from `exact` + `claimTarget`,
        // upstream of the redundant-root-removal pass entirely. Assert the
        // region-root mark directly, and confirm the render actually nests
        // 62 under switch A's chain row rather than in the port-level
        // leftovers.
        #expect(result.regionRoots[62] == 5, "62's own regionRoots mark (from redundant-root removal correctly NOT erasing it) must point at switch A, id 5")
        // 63 has no evidence of its own; it must INHERIT ownership from 62
        // (plain `descend` inheritance). If 62's mark had been wrongly
        // erased by redundant-root removal treating the owned hub's mark
        // above the boundary as covering it, 63 would inherit nothing
        // (nil) instead.
        #expect(result.regionOwner[63] == 5, "63 must inherit switch A's ownership through 62's surviving mark")

        // Review fix (MEDIUM/LOW, round 2026-08-13): same socketID/
        // carriesData gap as test 16f above (see its comment) -- the
        // original inline fixture here silently fell back to the flat
        // device list, so THIS render check (added for finding 5) would
        // itself have been vacuous without the fix. `makePort` with a
        // matching socketID exercises the real chain-attribution render.
        let port = makePort(serviceName: "Port-USB-C@2", portNumber: 2)
        let rows = ConnectedDeviceTree.rows(
            devices: [ownedHub, forced, selfAnchored, belowSelfAnchored], port: port, thunderboltSwitches: switches,
            displayPorts: [], hubs: .all
        )
        // 62 itself is `absorbed` (an exact identity-endpoint match, same as
        // `ownedHub`), so its OWN row is correctly suppressed in favour of
        // its children -- rendering it directly would duplicate switch A's
        // chain row. 63 (62's child, no evidence of its own) is what proves
        // the subtree actually rendered nested under A rather than
        // vanishing or landing in the port-level leftovers: it must appear
        // exactly once, strictly BEFORE the boundary's own row (61, which
        // renders from the port-level leftover group).
        let index63 = rows.firstIndex { $0.device?.device.id == 63 }
        let index61 = rows.firstIndex { $0.device?.device.id == 61 }
        let occurrences63 = rows.filter { $0.device?.device.id == 63 }.count
        #expect(occurrences63 == 1, "63 must render exactly once")
        #expect(!rows.contains { $0.device?.device.id == 62 }, "62 itself is absorbed (an identity endpoint), so it renders no row of its own")
        let i63 = try #require(index63, "63 must render somewhere")
        let i61 = try #require(index61, "61 (the boundary) must render somewhere")
        #expect(i63 < i61, "63 must render nested under switch A's chain row, BEFORE the port-level leftover group where the boundary (61) renders")
    }

    @Test("Test 16d: a Stage B match contradicted by numeric identity (not just a name) -> forcedPortLevel")
    func numericIdentityContradictionForcesPortLevel() {
        let host = hostRootSwitch(id: 1, socketID: "2", acioRootName: "acio1")
        let aPath = "IOService:/AppleARMPE/arm-io/apciec1@30000000/pcic1-bridge@1"
        let bPath = "IOService:/AppleARMPE/arm-io/apciec1@30000000/pcic1-bridge@0"
        // A's DROM carries a numeric vendor/model pair the device's own
        // idVendor/idProduct will exactly match, an independent (non-name)
        // identity signal.
        let a = IOThunderboltSwitch(
            id: 5, className: "IOThunderboltSwitchType3", vendorID: 0x043E,
            vendorName: "LG Electronics", modelName: "Dock A", routerID: 1,
            depth: 1, routeString: 1, upstreamPortNumber: 1, maxPortNumber: 13,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE),
            ports: [IOThunderboltPort(
                portNumber: 2, socketID: nil, adapterType: .pcieUp,
                currentSpeed: nil, currentWidth: nil, targetWidth: nil,
                rawTargetSpeed: nil, linkBandwidthRaw: nil,
                pciPath: aPath, pciEntryID: 2
            )],
            parentSwitchUID: 1, dromVendorID: 0x1234, dromModelID: 0x5678
        )
        let b = pcieSwitch(id: 6, parent: 1, depth: 1, model: "Dock B", upPath: bPath, upEntryID: 1)
        let switches = [host, a, b]
        let chain = ThunderboltTopology.tree(from: host, in: switches)

        // Stage B structurally matches B (controller path/entryID point at
        // B), but the device's own idVendor/idProduct exactly identify it
        // as A: a numeric contradiction, not a name-string one.
        let device = pcieDevice(
            id: 20, locationID: 0x20543000, rootName: "apciec1",
            controllerPath: bPath + "/xhci@0", ancestorEntryIDs: [1],
            product: "Unnamed Controller", vid: 0x1234
        )
        // productID isn't settable via the `pcieDevice` fixture helper
        // (fixed at 0x9A00), so build the device directly here to set
        // productID == 0x5678, matching A's dromModelID exactly.
        let numericDevice = USBDevice(
            id: 20, locationID: 0x20543000, vendorID: 0x1234, productID: 0x5678,
            vendorName: nil, productName: "Unnamed Controller", serialNumber: nil,
            usbVersion: nil, speedRaw: 3, busPowerMA: nil, currentMA: nil,
            isThunderboltTunnelled: true, tunnelBridgeDepth: nil,
            tunnelRootName: "apciec1", tunnelCarrier: .pcieTunnel,
            tunnelControllerRegistryPath: device.tunnelControllerRegistryPath,
            tunnelAncestorEntryIDs: device.tunnelAncestorEntryIDs,
            rawProperties: [:]
        )
        let result = ChainDeviceAttribution.resolve(
            chain: chain, forest: USBDeviceNode.buildTree(from: [numericDevice]),
            usbTunnelSwitchUIDs: [], expectedTunnelRootName: "apciec1"
        )
        #expect(result.regionOwner[20] == nil, "a Stage B/numeric-identity contradiction must not resolve to either candidate")
        #expect(result.portLevelBoundaries.contains(20), "the numeric contradiction is a TERMINAL forcedPortLevel outcome, same as a name contradiction")
    }

    @Test("Test 16j: a numeric claim promoted onto a hub Stage B places in another box yields to Stage B, and every row still renders once in both views")
    func promotionOntoStageBHubYieldsAndConservesRows() {
        let host = hostRootSwitch(id: 1, socketID: "2", acioRootName: "acio1")
        let aPath = "IOService:/AppleARMPE/arm-io/apciec1@30000000/pcic1-bridge@1"
        let bPath = aPath + "/IOPP/pci-bridge@1"
        // A's DROM carries a numeric vendor/model pair. B is chained behind
        // A (a linear chain, which is what the chain layout renders; two
        // first hops on one port are refused by design).
        let a = IOThunderboltSwitch(
            id: 5, className: "IOThunderboltSwitchType3", vendorID: 0x043E,
            vendorName: "LG Electronics", modelName: "Dock A", routerID: 1,
            depth: 1, routeString: 1, upstreamPortNumber: 1, maxPortNumber: 13,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE),
            ports: [IOThunderboltPort(
                portNumber: 2, socketID: nil, adapterType: .pcieUp,
                currentSpeed: nil, currentWidth: nil, targetWidth: nil,
                rawTargetSpeed: nil, linkBandwidthRaw: nil,
                pciPath: aPath, pciEntryID: 2
            )],
            parentSwitchUID: 1, dromVendorID: 0x1234, dromModelID: 0x5678
        )
        let b = pcieSwitch(id: 6, parent: 5, depth: 2, model: "Dock B", upPath: bPath, upEntryID: 1)
        let switches = [host, a, b]
        let chain = ThunderboltTopology.tree(from: host, in: switches)

        // Hub H: Stage B places it in B (its controller path sits under
        // B's PCI Path, the deeper of the two prefixes, and both entry IDs
        // are ancestors). Its VID is A's DROM vendor only, so a numeric
        // claim from a device below it would promote onto it for A (tier
        // c). PID stays the helper's 0x9A00, no exact numeric match.
        let hub = pcieDevice(
            id: 30, locationID: 0x20540000, rootName: "apciec1",
            controllerPath: bPath + "/xhci@0", ancestorEntryIDs: [2, 1],
            product: "Hub Chip", vid: 0x1234, isHub: true
        )
        // Endpoint E under H: A's DROM pair exactly, so it is A's own
        // identity device. High Speed and not tunnelled, so neither Stage B
        // nor the USB3 check has anything to say about it on its own.
        let endpoint = USBDevice(
            id: 31, locationID: 0x20541000, vendorID: 0x1234, productID: 0x5678,
            vendorName: nil, productName: "Billboard", serialNumber: nil,
            usbVersion: nil, speedRaw: 2, busPowerMA: nil, currentMA: nil,
            rawProperties: [:]
        )
        // Sibling S under H, carrying no evidence of its own.
        let sibling = USBDevice(
            id: 32, locationID: 0x20542000, vendorID: 0x2222, productID: 0x0001,
            vendorName: nil, productName: "Keyboard", serialNumber: nil,
            usbVersion: nil, speedRaw: 2, busPowerMA: nil, currentMA: nil,
            rawProperties: [:]
        )
        let devices = [hub, endpoint, sibling]
        let result = ChainDeviceAttribution.resolve(
            chain: chain, forest: USBDeviceNode.buildTree(from: devices),
            usbTunnelSwitchUIDs: [], expectedTunnelRootName: "apciec1"
        )
        #expect(result.regionOwner[30] == 6, "Stage B places the hub in B; a promotion onto it cannot move it")
        #expect(result.regionOwner[32] == 6, "the sibling follows the hub")
        #expect(result.regionOwner[31] == 5, "A's identity device stays A's, on its own")
        #expect(result.absorbed == [31], "only the identity device is absorbed, into its own box")

        // Rows: every device that is not absorbed renders exactly once in
        // each view (hubs render only when shown), and the hub and sibling
        // render under B, never under A.
        let port = makePort(serviceName: "Port-USB-C@2", portNumber: 2)
        for hubs in [ConnectedDeviceTree.HubDisplay.all, .endpointsOnly] {
            let rows = ConnectedDeviceTree.rows(
                devices: devices, port: port, thunderboltSwitches: switches, displayPorts: [], hubs: hubs
            )
            var section = ""
            var sectionOf: [UInt64: String] = [:]
            var counts: [UInt64: Int] = [:]
            for row in rows {
                if let device = row.device {
                    counts[device.device.id, default: 0] += 1
                    sectionOf[device.device.id] = section
                } else if !row.label.hasPrefix("Display:"), !row.label.hasPrefix("USB bus") {
                    section = row.label
                }
            }
            #expect(counts[30, default: 0] == (hubs == .all ? 1 : 0), "\(hubs): the hub renders once when shown, never otherwise")
            #expect(counts[31, default: 0] == 0, "\(hubs): the absorbed identity device is A's own row")
            #expect(counts[32, default: 0] == 1, "\(hubs): the sibling renders exactly once")
            #expect(sectionOf[32]?.contains("Dock B") == true, "\(hubs): the sibling sits under B, got \(sectionOf[32] ?? "nil")")
            if hubs == .all {
                #expect(sectionOf[30]?.contains("Dock B") == true, "\(hubs): the hub sits under B, got \(sectionOf[30] ?? "nil")")
            }
            #expect(rows.contains { $0.device == nil && $0.label.contains("Dock A") }, "\(hubs): A's own row is present")
        }
    }

    @Test("Test 16h: attributed A -> forced F -> vendor-only descendant whose vendor is unique to A stays port-level")
    func vendorContinuityBlockedBelowBoundary() {
        let host = hostRootSwitch(id: 1, socketID: "2", acioRootName: "acio1")
        let a = pcieSwitch(
            id: 5, parent: 1, depth: 1, model: "Dock A",
            upPath: "IOService:/AppleARMPE/arm-io/apciec1@30000000/pcic1-bridge@0",
            upEntryID: 1
        )
        let switches = [host, a]
        let chain = ThunderboltTopology.tree(from: host, in: switches)

        // Attributed ancestor: exact name match to A, and its vendor
        // (0xAAAA) is what seeds A's vendor set for continuity.
        let ownedHub = USBDevice(
            id: 70, locationID: 0x20540000, vendorID: 0xAAAA, productID: 0x1,
            vendorName: nil, productName: "Dock A", serialNumber: nil,
            usbVersion: nil, speedRaw: 3, busPowerMA: nil, currentMA: nil,
            deviceClass: 0x09, rawProperties: [:]
        )
        // Forced boundary, child of the owned hub: genuine `.portLevel`.
        let forced = pcieDevice(
            id: 71, locationID: 0x20540010, rootName: "apciec1",
            controllerPath: "IOService:/AppleARMPE/arm-io/apciec1@30000000/pcic1-bridge@9/xhci@0",
            ancestorEntryIDs: [9999],
            product: "Forced Boundary Controller"
        )
        // Vendor-only descendant of the forced boundary: shares A's vendor
        // (0xAAAA) but carries NO name or structural evidence of its own.
        let vendorOnly = USBDevice(
            id: 72, locationID: 0x20540011, vendorID: 0xAAAA, productID: 0x99,
            vendorName: nil, productName: "Generic Component", serialNumber: nil,
            usbVersion: nil, speedRaw: 3, busPowerMA: nil, currentMA: nil,
            rawProperties: [:]
        )
        let forest = USBDeviceNode.buildTree(from: [ownedHub, forced, vendorOnly])
        let forcedNode = forest.first?.children.first { $0.device.id == 71 }
        #expect(forcedNode?.children.contains { $0.device.id == 72 } == true, "fixture: vendorOnly must be a genuine child of forced")

        // Sanity: WITHOUT the boundary in the way, this exact vendor-only
        // shape is exactly what vendor continuity is designed to place
        // (documented behaviour elsewhere in the suite). The boundary is
        // what must change the outcome here.
        let result = ChainDeviceAttribution.resolve(
            chain: chain, forest: forest,
            usbTunnelSwitchUIDs: [], expectedTunnelRootName: "apciec1"
        )
        #expect(result.portLevelBoundaries.contains(71))
        #expect(result.regionOwner[72] == nil, "vendor continuity must not traverse the boundary or create a mark inside the blocked subtree")
    }
}
