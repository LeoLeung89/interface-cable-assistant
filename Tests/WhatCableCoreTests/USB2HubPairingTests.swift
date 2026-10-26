import Foundation
import Testing
@testable import WhatCableCore

/// A hub's USB2 half and USB3 half are two separate USB devices, and only the
/// USB3 half sits where the structural pass can place it. Both halves publish
/// one Container ID, which is what pairs them. IDs below are made up: the real
/// captured ones stay in the private chain-step tests.
@Suite("USB2 hub pairing by Container ID")
struct USB2HubPairingTests {

    private static let displayID = "11111111-2222-4333-8444-555555555555"
    private static let dockID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

    private func device(
        _ id: UInt64,
        _ locationID: UInt32,
        speed: UInt8,
        hub: Bool = true,
        cid: String?
    ) -> USBDevice {
        USBDevice(
            id: id,
            locationID: locationID,
            vendorID: 0x05AC,
            productID: 0x0001,
            vendorName: nil,
            productName: nil,
            serialNumber: nil,
            usbVersion: nil,
            speedRaw: speed,
            busPowerMA: nil,
            currentMA: nil,
            deviceClass: hub ? 0x09 : 0x00,
            containerID: cid,
            rawProperties: [:]
        )
    }

    @Test("A USB device carries the Container ID it was built with, and none by default")
    func containerIDField() {
        #expect(device(1, 0x0310_0000, speed: 2, cid: Self.displayID).containerID == Self.displayID)
        let bare = USBDevice(
            id: 2, locationID: 0x0320_0000, vendorID: 0x8087, productID: 0x5787,
            vendorName: nil, productName: nil, serialNumber: nil, usbVersion: nil,
            speedRaw: 4, busPowerMA: nil, currentMA: nil, rawProperties: [:]
        )
        #expect(bare.containerID == nil)
    }

    /// One ID two boxes both carry, as two docks built from the same silicon do.
    private static let templateID = "99999999-8888-4777-8666-555555555555"

    /// Host root 100, box 200 first in the chain, box 300 behind box 200.
    private func twoBoxChain() -> [IOThunderboltSwitchNode] {
        func sw(_ id: Int64, parent: Int64?, depth: Int) -> IOThunderboltSwitch {
            IOThunderboltSwitch(
                id: id, className: "IOThunderboltSwitchIntelJHL9580", vendorID: 0x8087,
                vendorName: "Box \(id)", modelName: "Box \(id)", routerID: depth, depth: depth,
                routeString: Int64(depth), upstreamPortNumber: 1, maxPortNumber: 23,
                supportedSpeed: SupportedSpeedMask(rawValue: 0xE), ports: [], parentSwitchUID: parent
            )
        }
        let root = sw(100, parent: nil, depth: 0)
        let switches = [root, sw(200, parent: 100, depth: 1), sw(300, parent: 200, depth: 2)]
        return ThunderboltTopology.flatten(ThunderboltTopology.tree(from: root, in: switches))
    }

    private func pairing(
        _ devices: [USBDevice],
        owners: [UInt64: Int64],
        accepts: (UInt64, Int64) -> Bool = { _, _ in true }
    ) -> [UInt64: Int64] {
        ChainDeviceAttribution.resolveUSB2HubPairing(
            chainNodes: twoBoxChain(),
            forest: USBDeviceNode.buildTree(from: devices),
            usb3Owner: owners,
            accepts: accepts
        )
    }

    /// Box 200's USB2 hub at the root, box 300's directly under it, each with
    /// a USB3 half the structural pass gave its box.
    private func chainedHubs(_ first: String, _ second: String) -> [USBDevice] {
        [
            device(1, 0x0310_0000, speed: 2, cid: first),
            device(2, 0x0312_0000, speed: 2, cid: second),
            device(3, 0x0320_0000, speed: 4, cid: first),
            device(4, 0x0321_0000, speed: 4, cid: second),
        ]
    }

    @Test("Each box's top USB2 hub is found box by box down the chain")
    func topHubsBoxByBox() {
        #expect(pairing(chainedHubs(Self.dockID, Self.displayID), owners: [3: 200, 4: 300]) == [1: 200, 2: 300])
    }

    // Amended rule: an ID that another box's USB3 side also carries
    // identifies neither box. Position no longer separates boxes that share
    // one (the earlier version of this test expected [1: 200, 2: 300]).
    @Test("An ID both boxes carry identifies neither, so nothing pairs on the chain")
    func sharedIDPairsNothing() {
        #expect(pairing(chainedHubs(Self.templateID, Self.templateID), owners: [3: 200, 4: 300]).isEmpty)
    }

    // Amended rule: all or nothing. The earlier version expected [1: 200], which
    // left the second box's USB2 devices inside the first box.
    @Test("An extra hub between two boxes' USB2 hubs pairs nothing on the whole chain")
    func extraHubBetweenPlacesNothing() {
        let devices = [
            device(1, 0x0310_0000, speed: 2, cid: Self.dockID),
            device(5, 0x0312_0000, speed: 2, cid: nil),
            device(2, 0x0312_1000, speed: 2, cid: Self.displayID),
            device(3, 0x0320_0000, speed: 4, cid: Self.dockID),
            device(4, 0x0321_0000, speed: 4, cid: Self.displayID),
        ]
        #expect(pairing(devices, owners: [3: 200, 4: 300]).isEmpty)
    }

    @Test("A box with no top USB2 hub pairs nothing for the boxes behind it either")
    func missingTopHubStopsTheBoxesBehind() {
        let devices = [
            device(1, 0x0310_0000, speed: 2, cid: nil),
            device(2, 0x0312_0000, speed: 2, cid: Self.displayID),
            device(4, 0x0321_0000, speed: 4, cid: Self.displayID),
        ]
        #expect(pairing(devices, owners: [4: 300]).isEmpty)
    }

    @Test("Two hubs qualifying for one box place nothing for it or the boxes behind")
    func twoQualifyingHubsPlaceNothing() {
        let devices = [
            device(1, 0x0310_0000, speed: 2, cid: Self.dockID),
            device(6, 0x0330_0000, speed: 2, cid: Self.dockID),
            device(3, 0x0320_0000, speed: 4, cid: Self.dockID),
        ]
        #expect(pairing(devices, owners: [3: 200]).isEmpty)
    }

    @Test("A top hub the caller refuses pairs nothing on the whole chain")
    func refusalStopsTheBoxesBehind() {
        let result = pairing(chainedHubs(Self.dockID, Self.displayID), owners: [3: 200, 4: 300]) { _, switchID in
            switchID != 200
        }
        #expect(result.isEmpty)
    }

    // The earlier version kept box 200's hub, which put box 300's USB2 side in box 200.
    @Test("A refusal for the last box also takes back the boxes above it")
    func refusingTheLastBoxPairsNothing() {
        let result = pairing(chainedHubs(Self.dockID, Self.displayID), owners: [3: 200, 4: 300]) { _, switchID in
            switchID != 300
        }
        #expect(result.isEmpty)
    }

    /// Two identical boxes, each with a top USB2 hub and a sibling hub of
    /// the template silicon directly under the first box's top hub, as on a
    /// real dock. Both boxes carry every ID, so nothing may pair.
    @Test("Two identical boxes in a chain pair nothing, not the first box alone")
    func identicalBoxesPairNothing() {
        let devices = [
            device(1, 0x0310_0000, speed: 2, cid: Self.dockID),
            device(2, 0x0312_0000, speed: 2, cid: Self.dockID),
            device(5, 0x0314_0000, speed: 2, cid: Self.templateID),
            device(3, 0x0320_0000, speed: 4, cid: Self.dockID),
            device(6, 0x0322_0000, speed: 4, cid: Self.templateID),
            device(4, 0x0321_0000, speed: 4, cid: Self.dockID),
            device(7, 0x0323_0000, speed: 4, cid: Self.templateID),
        ]
        #expect(pairing(devices, owners: [3: 200, 6: 200, 4: 300, 7: 300]).isEmpty)
    }

    /// Only the template silicon is shared: each box's own top hub has a
    /// per-unit ID. The shared ID is dropped from both, which leaves exactly
    /// one qualifying hub per box, instead of two for the second box.
    @Test("A template ID both boxes carry is ignored, and the per-unit IDs pair each box")
    func sharedTemplateDroppedPerUnitIDsPair() {
        let devices = [
            device(1, 0x0310_0000, speed: 2, cid: Self.dockID),
            device(2, 0x0312_0000, speed: 2, cid: Self.displayID),
            device(5, 0x0314_0000, speed: 2, cid: Self.templateID),
            device(3, 0x0320_0000, speed: 4, cid: Self.dockID),
            device(6, 0x0322_0000, speed: 4, cid: Self.templateID),
            device(4, 0x0321_0000, speed: 4, cid: Self.displayID),
            device(7, 0x0323_0000, speed: 4, cid: Self.templateID),
        ]
        #expect(pairing(devices, owners: [3: 200, 6: 200, 4: 300, 7: 300]) == [1: 200, 2: 300])
    }

    /// The first box's own sibling hub carries the template ID, and the
    /// second box's only evidence is that same ID. It must not take the
    /// first box's hub.
    @Test("A box cannot claim the box above's own hub through a shared template ID")
    func noStealingASiblingHub() {
        let devices = [
            device(1, 0x0310_0000, speed: 2, cid: Self.dockID),
            device(5, 0x0314_0000, speed: 2, cid: Self.templateID),
            device(2, 0x0312_0000, speed: 2, cid: nil),
            device(3, 0x0320_0000, speed: 4, cid: Self.dockID),
            device(6, 0x0322_0000, speed: 4, cid: Self.templateID),
            device(7, 0x0321_0000, speed: 4, cid: Self.templateID),
        ]
        #expect(pairing(devices, owners: [3: 200, 6: 200, 7: 300]).isEmpty)
    }

    @Test("The all-zero Container ID means none was published, so it never pairs")
    func allZeroNeverPairs() {
        let zero = "00000000-0000-0000-0000-000000000000"
        #expect(pairing(chainedHubs(zero, zero), owners: [3: 200, 4: 300]).isEmpty)
    }

    @Test("A USB3 device no structural pass placed seeds nothing")
    func unownedUSB3HalfPairsNothing() {
        #expect(pairing(chainedHubs(Self.dockID, Self.displayID), owners: [:]).isEmpty)
    }

    @Test("Only USB2 hubs qualify: a USB2 endpoint and a USB3 hub do not")
    func onlyUSB2HubsQualify() {
        let devices = [
            device(1, 0x0310_0000, speed: 2, hub: false, cid: Self.dockID),
            device(3, 0x0320_0000, speed: 4, cid: Self.dockID),
        ]
        #expect(pairing(devices, owners: [3: 200]).isEmpty)
    }

    @Test("Container IDs compare without case or surrounding space; empty and all-zero are none")
    func keyNormalises() {
        #expect(ChainDeviceAttribution.containerIDKey(" AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE\n") == Self.dockID)
        #expect(ChainDeviceAttribution.containerIDKey("") == nil)
        #expect(ChainDeviceAttribution.containerIDKey(nil) == nil)
        #expect(ChainDeviceAttribution.containerIDKey("00000000-0000-0000-0000-000000000000") == nil)
    }
}
