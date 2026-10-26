import Testing
@testable import WhatCableCore

@Suite("USBDevice.displayName")
struct USBDeviceDisplayNameTests {

    @Test("Appends the maker in parentheses when it adds information")
    func appendsMaker() {
        #expect(device(product: "USB2.0 Hub", vendor: "Fresco Logic, Inc.").displayName
            == "USB2.0 Hub (Fresco Logic, Inc.)")
        #expect(device(product: "USB 10_100_1000 LAN", vendor: "Realtek").displayName
            == "USB 10_100_1000 LAN (Realtek)")
    }

    @Test("Skips the maker when the product name already names the brand")
    func skipsRedundantMaker() {
        #expect(device(product: "UGREEN Dock", vendor: "UGREEN").displayName == "UGREEN Dock")
    }

    @Test("Redundancy check is case-insensitive")
    func skipsRedundantMakerCaseInsensitive() {
        #expect(device(product: "ugreen dock", vendor: "UGREEN").displayName == "ugreen dock")
    }

    @Test("Redundancy uses the maker's brand word, so a multi-word maker still matches")
    func skipsWhenBrandWordPresent() {
        // Brand token "Apple" is already a whole word in the product name.
        #expect(device(product: "Apple Keyboard", vendor: "Apple Inc.").displayName == "Apple Keyboard")
    }

    @Test("Whole-word match: a short maker inside an unrelated word is NOT treated as redundant")
    func makerInsideWordStillAppended() {
        // "LG" sits inside "Elgato" but is not a word there, so the real maker
        // must still be shown. A raw substring check would wrongly hide it.
        #expect(device(product: "Elgato Dock", vendor: "LG").displayName == "Elgato Dock (LG)")
    }

    @Test("Whole-word match: a real short vendor inside a common word is still appended")
    func shortVendorInsideCommonWordStillAppended() {
        // "GE" is a registered USB-IF vendor and sits inside "Storage"; a raw
        // substring check would silently drop the maker on a real device.
        #expect(device(product: "USB Storage Device", vendor: "GE").displayName
            == "USB Storage Device (GE)")
    }

    @Test("Product name only when the maker is nil")
    func nilVendor() {
        #expect(device(product: "Game Drive", vendor: nil).displayName == "Game Drive")
    }

    @Test("Product name only when the maker is blank")
    func blankVendor() {
        #expect(device(product: "Game Drive", vendor: "   ").displayName == "Game Drive")
    }

    @Test("Falls back to Unknown when there is no product name")
    func nilProduct() {
        #expect(device(product: nil, vendor: "Realtek").displayName == "Unknown")
    }

    @Test("Falls back to Unknown when the product name is blank")
    func blankProduct() {
        #expect(device(product: "   ", vendor: "Realtek").displayName == "Unknown")
    }

    @Test("Trims surrounding whitespace on both parts")
    func trimsWhitespace() {
        #expect(device(product: "  Hub  ", vendor: "  Apple  ").displayName == "Hub (Apple)")
    }

    @Test("The maker flows through deviceRows to the rendered name")
    func makerReachesDeviceRows() {
        let d = device(product: "USB2.0 Hub", vendor: "VIA Labs, Inc.", locationID: 0x14100000)
        let rows = USBDeviceNode.deviceRows(from: [d])
        #expect(rows.count == 1)
        #expect(rows[0].name == "USB2.0 Hub (VIA Labs, Inc.)")
    }

    // MARK: - helper

    private func device(
        product: String?,
        vendor: String?,
        locationID: UInt32 = 0x14100000
    ) -> USBDevice {
        USBDevice(
            id: 1,
            locationID: locationID,
            vendorID: 0,
            productID: 0,
            vendorName: vendor,
            productName: product,
            serialNumber: nil,
            usbVersion: nil,
            speedRaw: 2,
            busPowerMA: nil,
            currentMA: nil,
            rawProperties: [:]
        )
    }
}
