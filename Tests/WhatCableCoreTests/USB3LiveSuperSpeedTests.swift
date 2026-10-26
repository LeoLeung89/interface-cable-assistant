import Testing
@testable import WhatCableCore

/// `USB3SpeedCorroboration.hasLiveSuperSpeed` must say "USB 3 is running",
/// not "USB 3 was set up". Apple's `IOAccessoryUSBSuperSpeedActive` flag
/// means the latter, so every fixture here sets it true.
@Suite("USB3SpeedCorroboration.hasLiveSuperSpeed")
struct USB3LiveSuperSpeedTests {

    private let uuid = "12345678-1234-1234-1234-123456789ABC"

    private func port(active: [String]) -> AppleHPMInterface {
        AppleHPMInterface(
            id: 1,
            serviceName: "Port-USB-C@1",
            className: "AppleHPMInterfaceType10",
            portDescription: nil,
            portTypeDescription: "USB-C",
            portNumber: 1,
            connectionActive: true,
            activeCable: nil,
            opticalCable: nil,
            usbActive: nil,
            superSpeedActive: true,
            usbModeType: nil,
            usbConnectString: nil,
            transportsSupported: ["CC", "USB2", "USB3"],
            transportsActive: active,
            transportsProvisioned: ["CC", "USB3", "USB2"],
            plugOrientation: nil,
            plugEventCount: nil,
            connectionCount: nil,
            overcurrentCount: nil,
            pinConfiguration: [:],
            powerCurrentLimits: [],
            firmwareVersion: nil,
            bootFlagsHex: nil,
            hpmControllerUUID: uuid,
            rawProperties: [:]
        )
    }

    /// A direct (not tunnelled) USB3 transport that canonically matches
    /// `port(...)` through the shared controller UUID.
    private func matchingTransport() -> USB3Transport {
        USB3Transport(
            id: 10, portKey: "2/1", signaling: 1,
            signalingDescription: "Gen 1", dataRole: "host",
            hpmControllerUUID: uuid, tunnelled: false
        )
    }

    /// A device carrying a port name, as `matchingDevices` would return it
    /// for this port. SuperSpeed or not follows `speedRaw` (>= 3).
    private func portDevice(speedRaw: UInt8) -> USBDevice {
        USBDevice(
            id: 100,
            locationID: 0x01100000,
            vendorID: 0,
            productID: 0,
            vendorName: nil,
            productName: "Device",
            serialNumber: nil,
            usbVersion: nil,
            speedRaw: speedRaw,
            busPowerMA: nil,
            currentMA: nil,
            busIndex: nil,
            controllerPortName: "Port-USB-C@1",
            isBehindInternalHub: false,
            rawProperties: [:]
        )
    }

    @Test("mouse on a USB-A adapter: flag says SuperSpeed, link is USB 2")
    func mouseOnUSBAAdapter() {
        // Measured live on a MacBook: low-speed USB 2 mouse via USB-A to USB-C adapter.
        let live = USB3SpeedCorroboration.hasLiveSuperSpeed(
            port: port(active: ["CC", "USB2"]),
            usb3Transports: [],
            devices: [portDevice(speedRaw: 0)]
        )
        #expect(live == false)
    }

    @Test("USB 3 drive on a USB 2-only cable")
    func driveOnUSB2OnlyCable() {
        // Measured live on a MacBook: USB 3 drive linked at 480 Mbps (speedRaw 2).
        let live = USB3SpeedCorroboration.hasLiveSuperSpeed(
            port: port(active: ["CC", "USB2"]),
            usb3Transports: [],
            devices: [portDevice(speedRaw: 2)]
        )
        #expect(live == false)
    }

    @Test("iPad on a Thunderbolt cable: live, corroborated USB 3")
    func iPadOnThunderboltCable() {
        // Measured live on a MacBook: iPad over a Thunderbolt cable, USB3 active.
        let live = USB3SpeedCorroboration.hasLiveSuperSpeed(
            port: port(active: ["CC", "USB3"]),
            usb3Transports: [matchingTransport()],
            devices: [portDevice(speedRaw: 4)]
        )
        #expect(live == true)
    }

    @Test("SuperSpeed device on a port where only USB 2 is live stays false")
    func superSpeedDeviceWithoutLiveUSB3() {
        // Issue #187 shape: a SuperSpeed device reading on a port whose live
        // transport is USB 2. Only the USB3-in-TransportsActive guard decides it.
        let live = USB3SpeedCorroboration.hasLiveSuperSpeed(
            port: port(active: ["CC", "USB2"]),
            usb3Transports: [matchingTransport()],
            devices: [portDevice(speedRaw: 4)]
        )
        #expect(live == false)
    }

    @Test("USB 3 handshake flash with no SuperSpeed device stays false")
    func handshakeFlashWithNoDevice() {
        // Issue #181: USB3 briefly in TransportsActive on a charge-only cable, nothing enumerated.
        let live = USB3SpeedCorroboration.hasLiveSuperSpeed(
            port: port(active: ["CC", "USB3"]),
            usb3Transports: [matchingTransport()],
            devices: []
        )
        #expect(live == false)
    }
}
