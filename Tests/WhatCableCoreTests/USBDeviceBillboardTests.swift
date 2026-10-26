import Foundation
import Testing
@testable import WhatCableCore

@Suite("USB Billboard device detection")
struct USBDeviceBillboardTests {

    private func device(
        deviceClass: UInt8? = nil,
        ioClassName: String? = nil,
        productName: String? = nil
    ) -> USBDevice {
        USBDevice(
            id: 1, locationID: 0x0100_0000, vendorID: 0, productID: 0,
            vendorName: nil, productName: productName, serialNumber: nil,
            usbVersion: nil, speedRaw: nil, busPowerMA: nil, currentMA: nil,
            deviceClass: deviceClass, ioClassName: ioClassName,
            rawProperties: [:]
        )
    }

    @Test("bDeviceClass 0x11 is the spec-defined Billboard Device Class")
    func detectsByDeviceClass() {
        #expect(device(deviceClass: 0x11).isBillboardDevice)
    }

    @Test("Apple's Billboard IOKit class is recognised")
    func detectsByClassName() {
        #expect(device(ioClassName: "AppleUSBHostBillboardDevice").isBillboardDevice)
    }

    @Test("The product name macOS assigns is recognised")
    func detectsByProductName() {
        // The one signal observed in the wild so far: a real device showed up
        // named "Generic Billboard Device".
        #expect(device(productName: "Generic Billboard Device").isBillboardDevice)
    }

    @Test("An ordinary device is not a Billboard device")
    func ordinaryDeviceIsNot() {
        // bDeviceClass 9 is a USB hub, the common case next to a dock.
        #expect(!device(deviceClass: 9, ioClassName: "IOUSBHostDevice", productName: "USB3.0 Hub").isBillboardDevice)
        #expect(!device().isBillboardDevice)
    }

    @Test("An informative product name is surfaced")
    func informativeNameReturned() {
        // A Billboard device (class 0x11) whose name names the real product.
        let d = device(deviceClass: 0x11, productName: "Anker USB-C Hub Device")
        #expect(d.billboardInformativeName == "Anker USB-C Hub Device")
    }

    @Test("A generic billboard name is suppressed")
    func genericNameSuppressed() {
        // Names that are themselves just a "billboard" variant add nothing,
        // so callers fall back to the plain phrase.
        #expect(device(deviceClass: 0x11, productName: "Generic Billboard Device").billboardInformativeName == nil)
        #expect(device(deviceClass: 0x11, productName: "USB 2.0 BILLBOARD").billboardInformativeName == nil)
        #expect(device(deviceClass: 0x11, productName: nil).billboardInformativeName == nil)
        // Whitespace-padded real names (seen in the corpus) are trimmed.
        #expect(device(deviceClass: 0x11, productName: "  TS5 Plus Composite Device  ").billboardInformativeName == "TS5 Plus Composite Device")
    }

    @Test("The older IOKit class name is recognised too")
    func detectsByOlderClassName() {
        // The substring match covers both "AppleUSBHostBillboardDevice" and the
        // older "IOUSBHostBillboardDevice" the C probe also looks for.
        #expect(device(ioClassName: "IOUSBHostBillboardDevice").isBillboardDevice)
    }
}
