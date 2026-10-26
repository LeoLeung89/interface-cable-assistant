import Foundation
import Testing
@testable import WhatCableCore

/// The Mac-to-Mac signature: CIO active, an empty peer `Metadata`, nothing
/// provisioned through the tunnel, no partner switch, and an Apple USB 2.0
/// root device whose product name says it is a Mac. Every case below
/// flips one input and expects the predicate to fail closed.
@Suite("HostToHostLink")
struct HostToHostLinkTests {

    // MARK: - Fixtures

    private static let appleVID: UInt16 = 0x05AC

    private func makePort(
        serviceName: String = "Port-USB-C@1",
        transportsActive: [String] = ["CC", "USB2", "CIO"]
    ) -> AppleHPMInterface {
        AppleHPMInterface(
            id: 1,
            serviceName: serviceName,
            className: "AppleHPMInterfaceType10",
            portDescription: nil,
            portTypeDescription: "USB-C",
            portNumber: 1,
            connectionActive: true,
            activeCable: nil,
            opticalCable: nil,
            usbActive: nil,
            superSpeedActive: nil,
            usbModeType: nil,
            usbConnectString: nil,
            transportsSupported: ["CC", "USB2", "USB3", "CIO", "DisplayPort"],
            transportsActive: transportsActive,
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

    private func makeCIO(
        hasPeerMetadata: Bool? = false,
        tunneledTransportsProvisioned: [String]? = []
    ) -> CIOCableCapability {
        CIOCableCapability(
            id: 10,
            portKey: "2/1",
            cableGeneration: 2,
            negotiatedLinkSpeed: 4,
            generation: 3,
            asymmetricModeSupported: true,
            legacyAdapter: false,
            linkTrainingMode: 2,
            hpmControllerUUID: nil,
            hasPeerMetadata: hasPeerMetadata,
            tunneledTransportsProvisioned: tunneledTransportsProvisioned
        )
    }

    private func makeDevice(
        vendorID: UInt16 = HostToHostLinkTests.appleVID,
        productID: UInt16 = 0x7307,
        productName: String? = "Macbook Air",
        speedRaw: UInt8? = 2,
        locationID: UInt32 = 0x0110_0000,
        isThunderboltTunnelled: Bool = false
    ) -> USBDevice {
        USBDevice(
            id: 20,
            locationID: locationID,
            vendorID: vendorID,
            productID: productID,
            vendorName: "Apple Inc.",
            productName: productName,
            serialNumber: nil,
            usbVersion: "2.00",
            speedRaw: speedRaw,
            busPowerMA: nil,
            currentMA: nil,
            controllerPortName: "Port-USB-C@1",
            isThunderboltTunnelled: isThunderboltTunnelled,
            rawProperties: [:]
        )
    }

    private func makeHostSwitch(id: Int64 = 100, socketID: String = "1") -> IOThunderboltSwitch {
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
            className: "IOThunderboltSwitchType5",
            vendorID: 1452,
            vendorName: "Apple Inc.",
            modelName: "Mac",
            routerID: 0,
            depth: 0,
            routeString: 0,
            upstreamPortNumber: 0,
            maxPortNumber: 8,
            supportedSpeed: SupportedSpeedMask(rawValue: 0),
            ports: [lane],
            parentSwitchUID: nil
        )
    }

    /// A depth-1 partner hanging off the root's lane port 1. `childSwitch`
    /// joins on `parentSwitchUID == root.id` and the route string's byte at
    /// hop (depth - 1) equalling the root's port number.
    private func makePartnerSwitch(rootID: Int64 = 100) -> IOThunderboltSwitch {
        let upstream = IOThunderboltPort(
            portNumber: 3,
            socketID: nil,
            adapterType: .lane,
            currentSpeed: .usb4Tb4,
            currentWidth: LinkWidth(rawValue: 0x2),
            targetWidth: nil,
            rawTargetSpeed: nil,
            linkBandwidthRaw: nil
        )
        return IOThunderboltSwitch(
            id: 200,
            className: "IOThunderboltSwitchType5",
            vendorID: 0x8087,
            vendorName: "Intel",
            modelName: "Dock",
            routerID: 1,
            depth: 1,
            routeString: 1,
            upstreamPortNumber: 3,
            maxPortNumber: 8,
            supportedSpeed: SupportedSpeedMask(rawValue: 0),
            ports: [upstream],
            parentSwitchUID: rootID
        )
    }

    private func isHostToHost(
        port: AppleHPMInterface? = nil,
        devices: [USBDevice]? = nil,
        cio: CIOCableCapability?? = nil,
        switches: [IOThunderboltSwitch]? = nil
    ) -> Bool {
        HostToHostLink.isHostToHost(
            port: port ?? makePort(),
            devices: devices ?? [makeDevice()],
            cio: cio ?? makeCIO(),
            thunderboltSwitches: switches ?? [makeHostSwitch()]
        )
    }

    // MARK: - (a) The live sample

    @Test("MacBook Air over a TB cable: true")
    func liveSampleIsHostToHost() {
        #expect(isHostToHost() == true)
        #expect(HostToHostLink.peerMac(in: [makeDevice()])?.productID == 0x7307)
    }

    // MARK: - (b) Vision Pro shares the CIO signature, excluded by name

    @Test("Vision Pro with the same CIO signature: false")
    func visionProIsNotAMac() {
        let device = makeDevice(productID: 0x12B1, productName: "Vision Pro")
        #expect(HostToHostLink.peerMac(in: [device]) == nil)
        #expect(isHostToHost(devices: [device]) == false)
    }

    // MARK: - (c) Corpus product names

    @Test("Corpus names: \"Mac\" 0x1905 and \"MacBook Pro\" 0x1902: true")
    func corpusMacNamesMatch() {
        let mac = makeDevice(productID: 0x1905, productName: "Mac")
        let mbp = makeDevice(productID: 0x1902, productName: "MacBook Pro")
        #expect(isHostToHost(devices: [mac]) == true)
        #expect(isHostToHost(devices: [mbp]) == true)
    }

    // MARK: - (d) A partner switch means a dock or device, not a Mac

    @Test("Partner switch below the root lane: false")
    func partnerSwitchFailsClosed() {
        let root = makeHostSwitch()
        let partner = makePartnerSwitch(rootID: root.id)
        // Sanity: the fixture joins the way DataLinkDiagnostic reads it.
        #expect(DataLinkDiagnostic.partnerSwitch(port: makePort(), switches: [root, partner]) != nil)
        #expect(isHostToHost(switches: [root, partner]) == false)
    }

    // MARK: - (e) CIO row fields

    @Test("hasPeerMetadata true: false")
    func peerMetadataPresentFailsClosed() {
        #expect(isHostToHost(cio: makeCIO(hasPeerMetadata: true)) == false)
    }

    @Test("tunneledTransportsProvisioned [\"USB3\"]: false")
    func provisionedTunnelFailsClosed() {
        #expect(isHostToHost(cio: makeCIO(tunneledTransportsProvisioned: ["USB3"])) == false)
    }

    @Test("hasPeerMetadata nil (not read): false")
    func peerMetadataNilFailsClosed() {
        #expect(isHostToHost(cio: makeCIO(hasPeerMetadata: nil)) == false)
    }

    @Test("tunneledTransportsProvisioned nil (not read): false")
    func provisionedNilFailsClosed() {
        #expect(isHostToHost(cio: makeCIO(tunneledTransportsProvisioned: nil)) == false)
    }

    @Test("cio nil: false")
    func cioNilFailsClosed() {
        #expect(isHostToHost(cio: .some(nil)) == false)
    }

    // MARK: - (f) Port transport

    @Test("CIO not in transportsActive: false")
    func cioNotActiveFailsClosed() {
        #expect(isHostToHost(port: makePort(transportsActive: ["CC", "USB2"])) == false)
    }

    // MARK: - (g) Device shape

    @Test("Device at speedRaw 3: false")
    func superSpeedDeviceFailsClosed() {
        #expect(isHostToHost(devices: [makeDevice(speedRaw: 3)]) == false)
    }

    @Test("Non-root device: false")
    func hubbedDeviceFailsClosed() {
        #expect(isHostToHost(devices: [makeDevice(locationID: 0x0113_0000)]) == false)
    }

    @Test("Thunderbolt-tunnelled device: false")
    func tunnelledDeviceFailsClosed() {
        #expect(isHostToHost(devices: [makeDevice(isThunderboltTunnelled: true)]) == false)
    }

    @Test("Non-Apple vendor: false")
    func nonAppleVendorFailsClosed() {
        #expect(isHostToHost(devices: [makeDevice(vendorID: 0x8087)]) == false)
    }

    @Test("No devices: false")
    func noDevicesFailsClosed() {
        #expect(HostToHostLink.peerMac(in: []) == nil)
        #expect(isHostToHost(devices: []) == false)
    }

    // MARK: - (h) No fabric at all

    @Test("No Thunderbolt switches: false")
    func noSwitchesFailsClosed() {
        #expect(isHostToHost(switches: []) == false)
    }
}
