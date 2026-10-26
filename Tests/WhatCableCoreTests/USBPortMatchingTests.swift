import Testing
@testable import WhatCableCore

@Suite("USB port matching")
struct USBPortMatchingTests {
    @Test("matches devices by usbIOPort physical port name")
    func matchesDevicesByUsbIOPortPhysicalPortName() {
        let port = makePort(serviceName: "Port-USB-C@1", busIndex: 2)
        let matching = makeDevice(id: 1, controllerPortName: "Port-USB-C@1", busIndex: 9)
        let other = makeDevice(id: 2, controllerPortName: "Port-USB-C@2", busIndex: 2)

        #expect(port.matchingDevices(from: [other, matching]) == [matching])
    }

    @Test("matches device base port name variation")
    func matchesDeviceBasePortNameVariation() {
        let port = makePort(serviceName: "Port-USB-C@1", busIndex: 2)
        let matching = makeDevice(id: 1, controllerPortName: "Port-USB-C", busIndex: 2)

        #expect(port.matchingDevices(from: [matching]) == [matching])
    }

    @Test("matches port base name variation")
    func matchesPortBaseNameVariation() {
        let port = makePort(serviceName: "Port-USB-C", busIndex: 2)
        let matching = makeDevice(id: 1, controllerPortName: "Port-USB-C@1", busIndex: 2)

        #expect(port.matchingDevices(from: [matching]) == [matching])
    }

    @Test("decorated port name variations do not cross match")
    func decoratedPortNameVariationsDoNotCrossMatch() {
        let port = makePort(serviceName: "Port-USB-C@1", busIndex: 1)
        let other = makeDevice(id: 1, controllerPortName: "Port-USB-C@2", busIndex: 2)

        #expect(port.matchingDevices(from: [other]) == [])
    }

    @Test("direct usbIOPort presence prevents bus fallback")
    func directUsbIOPortPresencePreventsBusFallback() {
        let port = makePort(serviceName: "Port-USB-C@1", busIndex: 1)
        let deviceOnOtherPort = makeDevice(id: 1, controllerPortName: "Port-USB-C@2", busIndex: 1)

        #expect(port.matchingDevices(from: [deviceOnOtherPort]) == [])
    }

    @Test("falls back to busIndex only for nameless devices")
    func fallsBackToBusIndexOnlyForNamelessDevices() {
        let port = makePort(serviceName: "Port-USB-C@1", busIndex: 3)
        let namedElsewhere = makeDevice(id: 1, controllerPortName: "Port-USB-C@2", busIndex: 3)
        let namelessMatch = makeDevice(id: 2, busIndex: 3)

        #expect(port.matchingDevices(from: [namedElsewhere, namelessMatch]) == [namelessMatch])
    }

    @Test("no match key returns no devices instead of all devices")
    func noMatchKeyReturnsNoDevicesInsteadOfAllDevices() {
        let port = makePort(serviceName: "Port-USB-C@1")
        let devices = [
            makeDevice(id: 1, busIndex: 1),
            makeDevice(id: 2, busIndex: 2)
        ]

        #expect(port.matchingDevices(from: devices) == [])
    }

    @Test("bus fallback requires USB transport")
    func busFallbackRequiresUSBTransport() {
        let port = makePort(
            serviceName: "Port-MagSafe 3@1",
            busIndex: 1,
            usbActive: false,
            transportsActive: []
        )
        let device = makeDevice(id: 1, busIndex: 1)

        #expect(port.matchingDevices(from: [device]) == [])
    }

    @Test("bus fallback treats CIO as USB capable")
    func busFallbackTreatsCIOAsUSBCapable() {
        let port = makePort(
            serviceName: "Port-USB-C@1",
            busIndex: 1,
            usbActive: false,
            transportsActive: ["CIO"]
        )
        let device = makeDevice(id: 1, busIndex: 1)

        #expect(port.matchingDevices(from: [device]) == [device])
    }

    @Test("bus fallback ignores the always-on USB flags")
    func busFallbackIgnoresAlwaysOnUSBFlags() {
        // IOAccessoryUSBActive is true on every port, empty ones included,
        // and IOAccessoryUSBSuperSpeedActive tracks USB3 in
        // TransportsProvisioned (set up, not running). Neither may open the
        // bus-index fallback on a port whose only live transport is CC.
        let port = makePort(
            serviceName: "Port-USB-C@1",
            busIndex: 1,
            usbActive: true,
            superSpeedActive: true,
            transportsActive: ["CC"]
        )
        let device = makeDevice(id: 1, busIndex: 1)

        #expect(port.matchingDevices(from: [device]) == [])
    }

    // MARK: - Built-in USB-only front ports (issue #456)

    @Test("behind-internal-hub device attaches to its port on an exact name match")
    func behindInternalHubDeviceAttachesOnExactNameMatch() {
        // A 10 Gbps hub on a Mac Studio front USB-C port: behind the Mac's
        // internal hub, but its controllerPortName names the port outright.
        let port = makePort(serviceName: "Port-USB-C@5", busIndex: 1)
        let hub = makeDevice(
            id: 1,
            controllerPortName: "Port-USB-C@5",
            speedRaw: 4,
            isBehindInternalHub: true
        )

        let matched = port.matchingDevices(from: [hub])
        #expect(matched == [hub])
        // The observed 10 Gbps link is what the reporter expected to see; the
        // generic "5 Gbps or faster" fallback is only reached when this is nil.
        #expect(USBDevice.portMatchedSuperSpeed(in: matched)?.usb3SpeedLabel
            == "USB 3.2 Gen 2 (10 Gbps)")
    }

    @Test("behind-internal-hub device does not match a different port name")
    func behindInternalHubDeviceDoesNotMatchDifferentPortName() {
        let port = makePort(serviceName: "Port-USB-C@5", busIndex: 1)
        let onSix = makeDevice(
            id: 1,
            controllerPortName: "Port-USB-C@6",
            speedRaw: 4,
            isBehindInternalHub: true
        )

        #expect(port.matchingDevices(from: [onSix]) == [])
    }

    @Test("behind-internal-hub device gets exact match only, never the fuzzy base name")
    func behindInternalHubDeviceGetsExactMatchOnly() {
        // A directly-wired device with the base name "Port-USB-C" matches
        // "Port-USB-C@5" via the fuzzy path (proven above). A behind-hub device
        // must NOT: it only lands on a port whose name it names outright.
        let port = makePort(serviceName: "Port-USB-C@5", busIndex: 2)
        let baseName = makeDevice(
            id: 1,
            controllerPortName: "Port-USB-C",
            speedRaw: 4,
            busIndex: 2,
            isBehindInternalHub: true
        )

        #expect(port.matchingDevices(from: [baseName]) == [])
    }

    @Test("behind-internal-hub device with no port name stays unmatched (older macOS)")
    func behindInternalHubDeviceWithNoNameStaysUnmatched() {
        // On macOS 15 the built-in port node has no resolvable name, so the
        // device carries no controllerPortName and falls back to today's
        // behaviour: unmatched here, surfaced under Built-in USB ports instead.
        let port = makePort(serviceName: "Port-USB-C@5", busIndex: 1)
        let nameless = makeDevice(
            id: 1,
            speedRaw: 4,
            busIndex: 1,
            isBehindInternalHub: true
        )

        #expect(port.matchingDevices(from: [nameless]) == [])
    }

    @Test("MagSafe portKey uses MagSafe port type without raw PortType")
    func magSafePortKeyUsesMagSafePortTypeWithoutRawPortType() {
        let port = makePort(
            serviceName: "Port-MagSafe 3@1",
            portTypeDescription: "MagSafe 3",
            rawProperties: [:]
        )

        #expect(port.portKey == "17/1")
    }

    private func makePort(
        serviceName: String,
        portDescription: String? = nil,
        portTypeDescription: String = "USB-C",
        busIndex: Int? = nil,
        usbActive: Bool? = true,
        superSpeedActive: Bool? = nil,
        transportsActive: [String] = ["USB2"],
        rawProperties: [String: String] = ["PortType": "2"]
    ) -> USBCPort {
        USBCPort(
            id: UInt64(abs(serviceName.hashValue)),
            serviceName: serviceName,
            className: "AppleHPMInterfaceType10",
            portDescription: portDescription,
            portTypeDescription: portTypeDescription,
            portNumber: 1,
            connectionActive: true,
            activeCable: nil,
            opticalCable: nil,
            usbActive: usbActive,
            superSpeedActive: superSpeedActive,
            usbModeType: nil,
            usbConnectString: nil,
            transportsSupported: ["USB2", "USB3"],
            transportsActive: transportsActive,
            transportsProvisioned: ["CC"],
            plugOrientation: nil,
            plugEventCount: nil,
            connectionCount: nil,
            overcurrentCount: nil,
            pinConfiguration: [:],
            powerCurrentLimits: [],
            firmwareVersion: nil,
            bootFlagsHex: nil,
            busIndex: busIndex,
            rawProperties: rawProperties
        )
    }

    private func makeDevice(
        id: UInt64,
        controllerPortName: String? = nil,
        speedRaw: UInt8? = nil,
        busIndex: Int? = nil,
        isBehindInternalHub: Bool = false
    ) -> USBDevice {
        USBDevice(
            id: id,
            locationID: 0,
            vendorID: 0,
            productID: 0,
            vendorName: nil,
            productName: "Device \(id)",
            serialNumber: nil,
            usbVersion: nil,
            speedRaw: speedRaw,
            busPowerMA: nil,
            currentMA: nil,
            busIndex: busIndex,
            controllerPortName: controllerPortName,
            isBehindInternalHub: isBehindInternalHub,
            rawProperties: [:]
        )
    }
}
