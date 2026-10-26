import Testing
@testable import WhatCableCore

@Suite("VendorDB")
struct VendorDBTests {

    // MARK: - Names come from the bundled USB-IF list

    @Test("known vendors return USB-IF names")
    func knownVendorsReturnUSBIFNames() {
        // No curated overrides. USB-IF's published name is what we show,
        // verbatim. The legal-suffix forms are accurate and not misleading.
        #expect(VendorDB.name(for: 0x05AC) == "Apple")
        #expect(VendorDB.name(for: 0x0BDA) == "Realtek Semiconductor Corp.")
        #expect(VendorDB.name(for: 0x046D) == "Logitech Inc.")
        #expect(VendorDB.name(for: 0x291A) == "Anker Innovations Limited")
        #expect(VendorDB.name(for: 0x18D1) == "Google Inc.")
    }

    @Test("cable e-marker chip vendors resolve")
    func cableEmarkerChipVendorsResolve() {
        // E-marker silicon vendors observed in real cable reports
        // (#44, #45, #48, #49, #60, #62). USB-IF carries each of them
        // with its full legal name; we surface that as-is.
        #expect(
            VendorDB.name(for: 0x20C2) ==
            "Sumitomo Electric Ind., Ltd., Optical Comm. R&D Lab"
        )
        #expect(
            VendorDB.name(for: 0x315C) ==
            "Chengdu Convenientpower Semiconductor Co., LTD"
        )
        #expect(VendorDB.name(for: 0x2095) == "CE LINK LIMITED")
        #expect(VendorDB.name(for: 0x2E99) == "Hynetek Semiconductor Co., Ltd")
        #expect(
            VendorDB.name(for: 0x201C) ==
            "Hongkong Freeport Electronics Co., Limited"
        )
        #expect(VendorDB.name(for: 0x2B1D) == "Lintes Technology Co., Ltd.")
    }

    // MARK: - Formerly-wrong curated entries now resolve correctly

    @Test("formerly wrong curated entries now reflect USB-IF")
    func formerlyWrongCuratedEntriesNowReflectUSBIF() {
        // Before this audit several curated entries attributed VIDs to
        // the wrong companies. With the curated layer dropped, each
        // resolves via the bundled USB-IF list to the correct vendor.
        // Pin them so a future "let's add an override" can't silently
        // restore the bad data without going through review.
        #expect(VendorDB.name(for: 0x2BCF) == "Magtrol, Inc.")
        #expect(VendorDB.name(for: 0x32AC) == "Framework Computer Inc")
        #expect(VendorDB.name(for: 0x103C) == "AMX Corp.")
        #expect(VendorDB.name(for: 0x0FFE) == "ASKA Corporation")
        #expect(VendorDB.name(for: 0x152E) == "HLDS (Hitachi-LG Data Storage, Inc.)")
        #expect(VendorDB.name(for: 0x0AF8) == "Taiwan Regular Electronics Co., Ltd.")
    }

    // MARK: - Obsolete vendors resolve with clean names

    @Test("obsolete vendors return clean names")
    func obsoleteVendorsReturnCleanNames() {
        // Obsolete USB-IF vendors should resolve to the company name
        // without the " - OBSOLETE" suffix that lives in the raw TSV.
        #expect(VendorDB.name(for: 0x041C) == "Altera Corp.")
        #expect(VendorDB.name(for: 0x0CC1) == "Given Imaging LTD")
        #expect(VendorDB.name(for: 0x0001) != nil) // Fry's Electronics
    }

    @Test("obsolete vendors are registered")
    func obsoleteVendorsAreRegistered() {
        #expect(VendorDB.isRegistered(0x041C))  // Altera Corp.
        #expect(VendorDB.isRegistered(0x0001))  // Fry's Electronics
    }

    // MARK: - Unregistered VIDs

    @Test("unregistered VID returns nil")
    func unregisteredVIDReturnsNil() {
        #expect(VendorDB.name(for: 0xDEAD) == nil)
    }

    // MARK: - label()

    @Test("label includes name and hex")
    func labelIncludesNameAndHex() {
        #expect(VendorDB.label(for: 0x05AC) == "Apple (0x05AC)")
        #expect(
            VendorDB.label(for: 0x0BDA) ==
            "Realtek Semiconductor Corp. (0x0BDA)"
        )
    }

    @Test("label falls back to hex only")
    func labelFallsBackToHexOnly() {
        #expect(VendorDB.label(for: 0xDEAD) == "0xDEAD")
        #expect(VendorDB.label(for: 0xBEEF) == "0xBEEF")
    }

    // MARK: - isRegistered

    @Test("isRegistered covers bundled list")
    func isRegisteredCoversBundledList() {
        #expect(VendorDB.isRegistered(0x05AC))
        #expect(VendorDB.isRegistered(0x291A))
        #expect(VendorDB.isRegistered(0xDEAD) == false)
    }
}
