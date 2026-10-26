import Foundation
import Testing
@testable import WhatCableCore

/// Tests for `ConnectedDeviceTree.HubDisplay.endpointsOnly`, the collapsed view
/// the app shows by default.
///
/// Why it exists: hubs are the plumbing between the Mac and the things a user
/// has a decision to make about, and they dominate. 576 of 1222 devices across
/// the probe-38 corpus are hubs, and on a UGreen TB5 dock the real tree ran to
/// twelve rows five levels deep, of which nine were hubs, with the Studio
/// Display and the Ethernet adapter buried among them. Collapsing shows
/// strictly LESS, which is also why it was safe to make the default.
///
/// `.all` remains the default of `rows(...)` so the CLI is untouched; the app
/// opts in. The 33 tests in `ConnectedDeviceTreeTests` cover that path and must
/// keep passing unchanged.
@Suite("ConnectedDeviceTree: hub collapsing")
struct ConnectedDeviceTreeHubCollapseTests {

    // MARK: - Fixtures

    private func port() -> AppleHPMInterface {
        AppleHPMInterface(
            id: 1,
            serviceName: "Port-USB-C@4",
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
            transportsSupported: ["CC", "USB2", "USB3"],
            transportsActive: ["CC", "USB3"],
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

    /// `deviceClass: 0x09` is what makes a device a hub, and it is the only
    /// field this feature keys on.
    private func device(
        id: UInt64,
        locationID: UInt32,
        name: String,
        isHub: Bool,
        speedRaw: UInt8 = 4
    ) -> USBDevice {
        USBDevice(
            id: id,
            locationID: locationID,
            vendorID: 0x1234,
            productID: 0x5678,
            vendorName: nil,
            productName: name,
            serialNumber: nil,
            usbVersion: nil,
            speedRaw: speedRaw,
            busPowerMA: nil,
            currentMA: nil,
            deviceClass: isHub ? 0x09 : 0x08,
            rawProperties: [:]
        )
    }

    /// Hub -> hub -> hub -> LAN adapter. Mirrors the shape that prompted this:
    /// one thing worth seeing at the end of a chain of plumbing.
    private var chainOfHubsEndingInAnEndpoint: [USBDevice] {
        [
            device(id: 1, locationID: 0x0110_0000, name: "USB3 HUB", isHub: true),
            device(id: 2, locationID: 0x0111_0000, name: "USB3.1 Hub", isHub: true),
            device(id: 3, locationID: 0x0111_1000, name: "USB3.0 Hub", isHub: true),
            device(id: 4, locationID: 0x0111_1100, name: "Gigabit LAN", isHub: false, speedRaw: 3),
        ]
    }

    private func rows(_ devices: [USBDevice], hubs: ConnectedDeviceTree.HubDisplay) -> [ConnectedDeviceTree.Row] {
        ConnectedDeviceTree.rows(
            devices: devices,
            port: port(),
            thunderboltSwitches: [],
            displayPorts: [],
            hubs: hubs
        )
    }

    // MARK: - Tests

    @Test("Collapsed, a chain of hubs shows only the thing at the end of it")
    func collapsesHubChainToItsEndpoint() {
        let collapsed = rows(chainOfHubsEndingInAnEndpoint, hubs: .endpointsOnly)
        #expect(collapsed.count == 1, "Expected one row for one endpoint, got \(collapsed.count): \(collapsed.map(\.label))")
        #expect(collapsed[0].label.contains("Gigabit LAN"))
        for label in collapsed.map(\.label) {
            #expect(!label.contains("HUB"), "A hub survived the collapse: \(label)")
            #expect(!label.contains("Hub"), "A hub survived the collapse: \(label)")
        }
    }

    @Test("The endpoint says how many hubs it is behind")
    func endpointNamesItsHopCount() throws {
        let collapsed = rows(chainOfHubsEndingInAnEndpoint, hubs: .endpointsOnly)
        let label = try #require(collapsed.first?.label)
        #expect(label.contains("via 3 hubs"), "Expected 'via 3 hubs' in: \(label)")
    }

    @Test("One hub reads 'via 1 hub', not 'via 1 hubs'")
    func singularHopReadsCorrectly() throws {
        let devices = [
            device(id: 1, locationID: 0x0110_0000, name: "USB3 HUB", isHub: true),
            device(id: 2, locationID: 0x0111_0000, name: "Gigabit LAN", isHub: false),
        ]
        let label = try #require(rows(devices, hubs: .endpointsOnly).first?.label)
        #expect(label.contains("via 1 hub"))
        #expect(!label.contains("via 1 hubs"), "Naive pluralisation is back: \(label)")
    }

    @Test("A device plugged straight in gets no hop suffix")
    func directDeviceHasNoSuffix() throws {
        let devices = [device(id: 1, locationID: 0x0110_0000, name: "Gigabit LAN", isHub: false)]
        let label = try #require(rows(devices, hubs: .endpointsOnly).first?.label)
        #expect(!label.contains("via"), "A directly-attached device should not claim to be behind a hub: \(label)")
    }

    @Test("A lone leaf hub is hidden like any other plumbing")
    func leafHubIsHiddenWhenThereIsSomethingElseToShow() {
        // An earlier version showed a hub with nothing behind it, to avoid a
        // device vanishing. On a real dock that leaked two lone hubs into a
        // list captioned "Show 9 hubs", which reads as a bug. They are counted
        // in the toggle and one click brings them back.
        let devices = [
            device(id: 1, locationID: 0x0110_0000, name: "USB3 HUB", isHub: true),
            device(id: 2, locationID: 0x0111_0000, name: "Gigabit LAN", isHub: false),
            device(id: 3, locationID: 0x0120_0000, name: "Lone Leaf Hub", isHub: true),
        ]
        let labels = rows(devices, hubs: .endpointsOnly).map(\.label)
        #expect(labels.contains { $0.contains("Gigabit LAN") })
        #expect(!labels.contains { $0.contains("Lone Leaf Hub") },
            "A leaf hub leaked into the collapsed view: \(labels)")
    }

    @Test("But an all-hub port falls back to the full tree rather than showing nothing")
    func allHubPortFallsBack() {
        // A bare dock with nothing plugged in is all hubs. Collapsing would
        // leave an empty "Connected devices" section, which is worse than
        // showing the plumbing.
        let devices = [
            device(id: 1, locationID: 0x0110_0000, name: "USB3 HUB", isHub: true),
            device(id: 2, locationID: 0x0111_0000, name: "USB2.0 Hub", isHub: true),
        ]
        let collapsed = rows(devices, hubs: .endpointsOnly)
        #expect(collapsed.count == 2, "An all-hub port should fall back to the full tree, got \(collapsed.map(\.label))")
    }

    @Test("Several endpoints behind one hub all survive, each with its own count")
    func siblingEndpointsAllSurvive() {
        let devices = [
            device(id: 1, locationID: 0x0110_0000, name: "USB3 HUB", isHub: true),
            device(id: 2, locationID: 0x0111_0000, name: "Keyboard", isHub: false),
            device(id: 3, locationID: 0x0112_0000, name: "Gigabit LAN", isHub: false),
        ]
        let labels = rows(devices, hubs: .endpointsOnly).map(\.label)
        #expect(labels.contains { $0.contains("Keyboard") })
        #expect(labels.contains { $0.contains("Gigabit LAN") })
        #expect(labels.allSatisfy { !$0.contains("HUB") })
    }

    @Test("`.all` is untouched: every device still renders, nested")
    func allModeIsUnchanged() {
        // The CLI keeps this path, so the collapse must not have leaked into it.
        let full = rows(chainOfHubsEndingInAnEndpoint, hubs: .all)
        #expect(full.count == 4, "Expected all 4 devices in .all mode, got \(full.count)")
        #expect(full.contains { $0.label.contains("USB3 HUB") })
        #expect(full.map(\.depth).max() ?? 0 > 0, "The full tree should still nest")
        #expect(full.allSatisfy { !$0.label.contains("via") }, "The hop suffix leaked into .all mode")
    }

    @Test("`.all` is the default, so existing callers are unaffected")
    func defaultIsAll() {
        let defaulted = ConnectedDeviceTree.rows(
            devices: chainOfHubsEndingInAnEndpoint,
            port: port(),
            thunderboltSwitches: [],
            displayPorts: []
        )
        #expect(defaulted.count == 4, "The default changed; the CLI's output would change with it")
    }
}
