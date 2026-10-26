import Foundation
import Testing
import WhatCableCore
@testable import WhatCable

/// Tests for `WidgetDataWriter.deviceInputs`, the writer's per-port device
/// seam (plan `pcie-tunnelled-usb-attribution`, code-review finding: the
/// writer is an INDEPENDENT builder from `WidgetSnapshot.init(from:)`, so its
/// union wiring needs its own test; regressing it must go red here).
struct WidgetDataWriterDeviceInputsTests {

    private func makePort(serviceName: String, portNumber: Int) -> AppleHPMInterface {
        AppleHPMInterface(
            id: UInt64(portNumber), serviceName: serviceName,
            className: "AppleHPMInterfaceType10", portDescription: nil,
            portTypeDescription: "USB-C", portNumber: portNumber,
            connectionActive: true, activeCable: nil, opticalCable: nil,
            usbActive: nil, superSpeedActive: nil, usbModeType: nil,
            usbConnectString: nil,
            transportsSupported: ["CC", "USB2", "USB3", "CIO"],
            transportsActive: ["CC", "CIO"], transportsProvisioned: [],
            plugOrientation: nil, plugEventCount: nil, connectionCount: nil,
            overcurrentCount: nil, pinConfiguration: [:], powerCurrentLimits: [],
            firmwareVersion: nil, bootFlagsHex: nil, rawProperties: [:]
        )
    }

    @Test("deviceInputs: attributed carries the port-scoped PCIe-dock devices, matched stays native-only")
    func attributedCarriesScopedDevices() {
        let host = IOThunderboltSwitch(
            id: 1, className: "IOThunderboltSwitchType5", vendorID: 0x5AC,
            vendorName: "Apple Inc.", modelName: "Mac", routerID: 0, depth: 0,
            routeString: 0, upstreamPortNumber: 7, maxPortNumber: 7,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE),
            ports: [IOThunderboltPort(
                portNumber: 1, socketID: "2", adapterType: .lane,
                currentSpeed: .usb4Tb4, currentWidth: LinkWidth(rawValue: 0x2),
                targetWidth: nil, rawTargetSpeed: nil, linkBandwidthRaw: nil,
                hopTable: []
            )],
            parentSwitchUID: nil, acioRootName: "acio1"
        )
        let lg = IOThunderboltSwitch(
            id: 5, className: "IOThunderboltSwitchType3", vendorID: 0x043E,
            vendorName: "LG Electronics", modelName: "UltraFine 5K", routerID: 1,
            depth: 1, routeString: 1, upstreamPortNumber: 1, maxPortNumber: 13,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE), ports: [],
            parentSwitchUID: 1
        )
        let port = makePort(serviceName: "Port-USB-C@2", portNumber: 2)
        let scoped = USBDevice(
            id: 60, locationID: 0x20543000, vendorID: 0x043E, productID: 0x9A4D,
            vendorName: nil, productName: "LG UltraFine Display Camera",
            serialNumber: nil, usbVersion: nil, speedRaw: 3, busPowerMA: nil,
            currentMA: nil, isThunderboltTunnelled: true,
            tunnelRootName: "apciec1", tunnelCarrier: .pcieTunnel,
            rawProperties: [:]
        )
        let native = USBDevice(
            id: 61, locationID: 0x2100000, vendorID: 0x2188, productID: 0x33,
            vendorName: nil, productName: "Native Hub", serialNumber: nil,
            usbVersion: nil, speedRaw: 3, busPowerMA: nil, currentMA: nil,
            controllerPortName: "Port-USB-C@2", rawProperties: [:]
        )
        let (attributed, matched) = WidgetDataWriter.deviceInputs(
            for: port, devices: [native, scoped], thunderboltSwitches: [host, lg]
        )
        #expect(Set(attributed.map(\.id)) == [60, 61], "union carries native + scoped")
        #expect(matched.map(\.id) == [61], "matched stays native-only for the bus-local summary inputs")
    }
}
