import Foundation
import Testing
@testable import WhatCableCore

/// `VDMIdentity.certStatXID` is a second decode path for the Cert Stat VDO,
/// added so the Pro diagnostics screen can show the raw certification ID
/// without depending on `USBPDSOP`. Two decode paths for one field is exactly
/// where an off-by-one on the VDO index hides: the number would still look
/// plausible, it would just be the wrong one, on a screen paying users trust.
///
/// So every test here cross-checks against `USBPDSOP.certStatVDO`, the
/// established path, rather than against a hand-written expectation alone.
@Suite("VDMIdentity: Cert Stat VDO decode")
struct VDMIdentityCertStatTests {

    /// IOKit stores VDOs as 4-byte little-endian blobs, which is what both
    /// decode paths have to unpack.
    private func vdoData(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ])
    }

    private func identity(vdos: [UInt32]) -> VDMIdentity {
        VDMIdentity(
            vendorId: 0x05AC, productId: 0, bcdDevice: 0, specRevision: 3,
            vdos: vdos.map(vdoData), productType: 3, productTypeDescription: nil
        )
    }

    private func sop(vdos: [UInt32]) -> USBPDSOP {
        USBPDSOP(
            id: 1, endpoint: .sopPrime, parentPortType: 2, parentPortNumber: 1,
            vendorID: 0x05AC, productID: 0, bcdDevice: 0,
            vdos: vdos, specRevision: 3
        )
    }

    // The four VDOs of a Discover Identity response, each a distinct value so
    // reading the wrong index cannot accidentally produce the right answer.
    // Index 1 is the Cert Stat VDO; 0x2600 is Apple's real XID.
    private static let idHeader: UInt32 = (3 << 27) | 0x05AC
    private static let certStat: UInt32 = 0x0000_2600
    private static let product: UInt32 = 0xDEAD_BEEF
    private static let cable: UInt32 = 0b011 | (2 << 5) | (1 << 13)

    @Test("Reads VDO index 1, not the ID header, product or cable VDO")
    func readsTheCertStatIndex() {
        let all = [Self.idHeader, Self.certStat, Self.product, Self.cable]
        let xid = identity(vdos: all).certStatXID
        #expect(xid == 0x2600)
        // Prove it is not silently reading a neighbour.
        #expect(xid != Self.idHeader)
        #expect(xid != Self.product)
        #expect(xid != Self.cable)
        // And that the sibling property still reads index 3, so the two
        // haven't drifted onto the same VDO.
        #expect(identity(vdos: all).cableVDO3Value == Self.cable)
    }

    @Test("Agrees with USBPDSOP.certStatVDO, the established decode path")
    func agreesWithTheEstablishedPath() {
        // A spread of real-shaped values: Apple's XID, a small one from the
        // corpus range, zero (never certified), and a value with a byte set in
        // every position so a byte-order slip cannot pass.
        for value: UInt32 in [0x2600, 0x05F5, 0, 0x1234_5678] {
            let all = [Self.idHeader, value, Self.product, Self.cable]
            let viaVDM = identity(vdos: all).certStatXID
            let viaSOP = sop(vdos: all).certStatVDO?.xid
            #expect(viaVDM == viaSOP, "decode paths disagree on 0x\(String(value, radix: 16))")
            #expect(viaVDM == value)
        }
    }

    @Test("Nil when the Cert Stat VDO is absent or malformed")
    func nilWhenAbsent() {
        // An ID header alone: no VDO[1] to read.
        #expect(identity(vdos: [Self.idHeader]).certStatXID == nil)
        // A truncated blob is not a 32-bit value; better nil than a number
        // assembled from whatever bytes happened to be there.
        let short = VDMIdentity(
            vendorId: 0x05AC, productId: 0, bcdDevice: 0, specRevision: 3,
            vdos: [vdoData(Self.idHeader), Data([0x00, 0x26])],
            productType: 3, productTypeDescription: nil
        )
        #expect(short.certStatXID == nil)
    }

    /// Zero is the spec's "never went through certification" sentinel, which
    /// the majority of cables report. It must decode as 0 rather than nil, so
    /// the Pro row's `xid != 0` gate is what decides whether to show it, not
    /// an accidental nil.
    @Test("A zero XID decodes as zero, not nil")
    func zeroIsAValue() {
        let all = [Self.idHeader, 0, Self.product, Self.cable]
        #expect(identity(vdos: all).certStatXID == 0)
    }
}
