import Testing
@testable import WhatCableCore

/// Tests `BuiltInPortGrouping` (issue #490): splitting the desktop built-in
/// USB section into one group per physical port node, with the unattributed
/// fallback for machines that don't publish `UsbIOPort` (macOS 15).
struct BuiltInPortGroupingTests {
    private func device(id: UInt64, name: String, portNode: String? = nil, deviceClass: UInt8? = nil) -> USBDevice {
        USBDevice(
            id: id,
            locationID: UInt32(truncatingIfNeeded: id),
            vendorID: 0x05AC,
            productID: 0x1234,
            vendorName: "Apple",
            productName: name,
            serialNumber: nil,
            usbVersion: nil,
            speedRaw: 2,
            busPowerMA: nil,
            currentMA: nil,
            controllerPortName: portNode,
            isThunderboltTunnelled: false,
            isBehindInternalHub: true,
            deviceClass: deviceClass,
            rawProperties: [:]
        )
    }

    // MARK: Parsing

    @Test func parsesUSBAAndUSBCNodes() {
        let a = BuiltInPortGrouping.parse(portNodeName: "Port-USB-A@1")
        #expect(a?.connector == "USB-A")
        #expect(a?.portNumber == 1)
        let c = BuiltInPortGrouping.parse(portNodeName: "Port-USB-C@6")
        #expect(c?.connector == "USB-C")
        #expect(c?.portNumber == 6)
    }

    @Test func rejectsMalformedNodes() {
        #expect(BuiltInPortGrouping.parse(portNodeName: "Port-USB-A") == nil)
        #expect(BuiltInPortGrouping.parse(portNodeName: "Port-@1") == nil)
        #expect(BuiltInPortGrouping.parse(portNodeName: "USB-A@1") == nil)
        #expect(BuiltInPortGrouping.parse(portNodeName: "Port-USB-A@x") == nil)
    }

    // MARK: Grouping

    @Test func groupsByPortSortedByConnectorThenNumber() {
        let devices = [
            device(id: 1, name: "Drive on A2", portNode: "Port-USB-A@2"),
            device(id: 2, name: "Webcam on C6", portNode: "Port-USB-C@6"),
            device(id: 3, name: "Keyboard on A1", portNode: "Port-USB-A@1"),
            device(id: 4, name: "Hub on A1", portNode: "Port-USB-A@1", deviceClass: 0x09),
        ]
        let groups = BuiltInPortGrouping.groups(from: devices)
        #expect(groups.map(\.portNodeName) == ["Port-USB-A@1", "Port-USB-A@2", "Port-USB-C@6"])
        #expect(groups[0].devices.map(\.id) == [3, 4])
        #expect(groups[1].devices.map(\.id) == [1])
        #expect(groups[2].devices.map(\.id) == [2])
    }

    @Test func noPortNamesFallsBackToSingleGroup() {
        // macOS 15 shape: no UsbIOPort anywhere, so the section must render
        // exactly as before the change (one combined, unattributed group).
        let devices = [
            device(id: 1, name: "Drive"),
            device(id: 2, name: "Keyboard"),
        ]
        let groups = BuiltInPortGrouping.groups(from: devices)
        #expect(groups.count == 1)
        #expect(groups[0].portNodeName == nil)
        #expect(groups[0].connector == nil)
        #expect(groups[0].devices.map(\.id) == [1, 2])
    }

    @Test func mixedNamedAndUnattributedKeepsFallbackLast() {
        let devices = [
            device(id: 1, name: "Unattributed"),
            device(id: 2, name: "Drive on A1", portNode: "Port-USB-A@1"),
        ]
        let groups = BuiltInPortGrouping.groups(from: devices)
        #expect(groups.count == 2)
        #expect(groups[0].portNodeName == "Port-USB-A@1")
        #expect(groups[1].portNodeName == nil)
        #expect(groups[1].devices.map(\.id) == [1])
    }

    @Test func emptyInputYieldsSingleEmptyFallback() {
        let groups = BuiltInPortGrouping.groups(from: [])
        #expect(groups.count == 1)
        #expect(groups[0].portNodeName == nil)
        #expect(groups[0].devices.isEmpty)
    }

    // MARK: Title decision

    @Test func allOnUSBAOnlyWhenEveryGroupIsUSBA() {
        let allA = BuiltInPortGrouping.groups(from: [
            device(id: 1, name: "Drive", portNode: "Port-USB-A@1"),
            device(id: 2, name: "Keyboard", portNode: "Port-USB-A@2"),
        ])
        #expect(BuiltInPortGrouping.allOnUSBA(allA))

        let mixed = BuiltInPortGrouping.groups(from: [
            device(id: 1, name: "Drive", portNode: "Port-USB-A@1"),
            device(id: 2, name: "Webcam", portNode: "Port-USB-C@6"),
        ])
        #expect(!BuiltInPortGrouping.allOnUSBA(mixed))

        let withUnattributed = BuiltInPortGrouping.groups(from: [
            device(id: 1, name: "Drive", portNode: "Port-USB-A@1"),
            device(id: 2, name: "Mystery"),
        ])
        #expect(!BuiltInPortGrouping.allOnUSBA(withUnattributed))

        #expect(!BuiltInPortGrouping.allOnUSBA(BuiltInPortGrouping.groups(from: [])))
    }
}
