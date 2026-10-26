import Foundation
import Testing
@testable import WhatCableCore

// MARK: - PortIdentity
//
// This type replaced four hand-written port-key builders, so it is now a single
// point of failure for four previously independent sites. Until this file
// existed it was only exercised incidentally, through whichever corpus sweep
// happened to touch one of those sites, which meant the malformed-input paths
// and the ordering had no direct coverage at all. Raised by the adversarial
// review of the commit that introduced it.
//
// The tests below are written as "the old rule at site X, restated", so a
// future tidy-up that unifies the remaining differences fails here first and
// has to argue with a named site rather than a style preference.
@Suite("PortIdentity")
struct PortIdentityTests {

    // MARK: - The rule, per original site

    @Test("AppleHPMInterface.portKey's rule: MagSafe wins over the reported type")
    func magSafeBeatsReportedType() {
        // The description is the more reliable signal, and mislabelling a
        // charge-only connector as a data port is the worst failure available
        // here, so a MagSafe description wins even against a contradictory
        // reported code.
        let identity = PortIdentity.from(typeDescription: "MagSafe 3", reportedTypeCode: 2, number: 1)
        #expect(identity.typeCode == PortIdentity.magSafeTypeCode)
        #expect(identity.key == "17/1")
        #expect(identity.isMagSafe)
    }

    @Test("A non-MagSafe port keeps its own reported type rather than being flattened to USB-C")
    func unknownReportedTypeSurvives() {
        // The A18 Pro machines in the corpus publish a `Port-Inductive` node.
        // Forcing everything non-MagSafe to 2 would give it a USB-C port's key
        // and let its data land on a real USB-C port's card.
        let identity = PortIdentity.from(typeDescription: "Inductive", reportedTypeCode: 9, number: 1)
        #expect(identity.typeCode == 9)
        #expect(identity.key == "9/1")
    }

    @Test("With no reported type, USB-C is the fallback")
    func fallbackIsUSBC() {
        // This is `PowerMonitorWindow.resolve`'s rule: it only ever had the
        // description, never a reported code.
        #expect(PortIdentity.from(typeDescription: "USB-C", reportedTypeCode: nil, number: 3).key == "2/3")
        #expect(PortIdentity.from(typeDescription: nil, reportedTypeCode: nil, number: 3).key == "2/3")
    }

    @Test("A registry node name is matched with contains, not hasPrefix")
    func serviceNameRule() {
        // `HPMPortUUIDMap` walks the registry and sees "Port-MagSafe 3@1", so a
        // hasPrefix test against the same string would call every MagSafe port
        // USB-C. This is why the two `from` entry points are not one function.
        #expect(PortIdentity.from(serviceName: "Port-MagSafe 3@1", number: 1).key == "17/1")
        #expect(PortIdentity.from(serviceName: "Port-USB-C@2", number: 2).key == "2/2")
        // And the reason `hasPrefix` is still correct for the description path:
        // a description really does start with the type.
        #expect(PortIdentity.from(typeDescription: "Port-MagSafe 3@1", reportedTypeCode: nil, number: 1).key == "2/1",
            "a node NAME passed to the description entry point is not MagSafe by that rule; the two inputs are not interchangeable")
    }

    // MARK: - Parsing back

    @Test("The strict parser round-trips a real key and rejects everything else")
    func strictParser() {
        #expect(PortIdentity(key: "17/1")?.typeCode == PortIdentity.magSafeTypeCode)
        #expect(PortIdentity(key: "17/1")?.number == 1)
        #expect(PortIdentity(key: "2/4")?.key == "2/4")

        // Rejected, deliberately. A join key that half-parses would attribute
        // one port's data to another, which is the exact bug class this whole
        // slice exists to close.
        #expect(PortIdentity(key: "") == nil)
        #expect(PortIdentity(key: "2") == nil)
        #expect(PortIdentity(key: "2/1/3") == nil)
        #expect(PortIdentity(key: "2/x") == nil)
        #expect(PortIdentity(key: "USB-C/1") == nil)
    }

    /// The original inline parser at the display site, transcribed from the
    /// pre-refactor source. Every lenient case below is asserted against THIS,
    /// not against a description of it.
    ///
    /// The first version of these tests asserted the helper's own return value
    /// and called that "restates the old display behaviour". It did not: it
    /// checked the wrong layer, which is precisely why it did not notice that
    /// `lenient` threw away a valid port number whenever the type component
    /// failed to parse. Reviewer's finding, and a fair one.
    private static func originalDisplayParse(key: String, fallbackIndex: Int) -> (type: String, num: Int) {
        let parts = key.split(separator: "/")
        let typeCode = parts.first.flatMap { Int($0) }
        let type = typeCode == 0x11 ? "MagSafe 3" : "USB-C"
        let num = (parts.count > 1 ? Int(parts[1]) : nil) ?? fallbackIndex
        return (type, num)
    }

    /// What the shipping call site computes, transcribed from
    /// `PowerMonitorWindow`'s no-HPM fallback branch.
    private static func currentDisplayParse(key: String, fallbackIndex: Int) -> (type: String, num: Int) {
        let identity = PortIdentity.lenient(key: key, fallbackNumber: fallbackIndex)
        return (identity.typeDescription, identity.number)
    }

    @Test("The lenient path matches the original display parser on every key shape")
    func lenientMatchesOriginalDisplayParser() {
        // A distinctive fallback index so a fallback is visible rather than
        // coincidentally equal to a parsed value.
        let fallback = 99
        let keys = [
            "2/1", "17/1", "17/2", "9/3",           // well formed
            "17/2/extra",                            // extra components
            "17/x", "2/x",                           // unparseable number
            "17", "2",                               // no number at all
            "",                                      // empty
            "USB-C/1", "USB-C",                      // unparseable type
            "/1", "//",                              // degenerate
            // An explicit zero. The original returned it verbatim, because
            // `Optional(0) ?? fallback` is 0. A version of this that used 0 as
            // its "no number" sentinel substituted the fallback instead, which
            // is why the fallback is now a parameter. Nothing emits port 0
            // today; the point is that the two are different answers.
            "2/0", "17/0",
        ]
        for key in keys {
            let original = Self.originalDisplayParse(key: key, fallbackIndex: fallback)
            let current = Self.currentDisplayParse(key: key, fallbackIndex: fallback)
            #expect(current.type == original.type,
                "key \"\(key)\": type \(current.type) but the original gave \(original.type)")
            #expect(current.num == original.num,
                "key \"\(key)\": number \(current.num) but the original gave \(original.num)")
        }
    }

    @Test("Strict and lenient agree on every well-formed key")
    func parsersAgreeOnGoodInput() {
        for typeCode in [PortIdentity.usbCTypeCode, PortIdentity.magSafeTypeCode, 9] {
            for number in 1...6 {
                let key = PortIdentity(typeCode: typeCode, number: number).key
                #expect(PortIdentity(key: key) == PortIdentity.lenient(key: key, fallbackNumber: 99),
                    "the two parsers must only differ on malformed input, but they differ on \(key)")
            }
        }
    }

    // MARK: - Labels and ordering

    @Test("Only MagSafe reads as MagSafe")
    func typeDescription() {
        #expect(PortIdentity(typeCode: PortIdentity.magSafeTypeCode, number: 1).typeDescription == "MagSafe 3")
        #expect(PortIdentity(typeCode: PortIdentity.usbCTypeCode, number: 1).typeDescription == "USB-C")
        // A connector nobody has seen reads as USB-C. That is the documented
        // simplification, asserted so a future change to it is deliberate.
        #expect(PortIdentity(typeCode: 9, number: 1).typeDescription == "USB-C")
    }

    @Test("Ordering groups by connector, then by port number")
    func ordering() {
        let sorted = [
            PortIdentity(typeCode: 17, number: 1),
            PortIdentity(typeCode: 2, number: 4),
            PortIdentity(typeCode: 2, number: 1),
            PortIdentity(typeCode: 17, number: 2),
        ].sorted()
        #expect(sorted.map(\.key) == ["2/1", "2/4", "17/1", "17/2"])
    }

    @Test("Two ports with the same number but different connectors are different ports")
    func magSafeAndUSBCOneDoNotCollide() {
        // A MacBook publishes MagSafe@1 and USB-C@1 at the same time. If these
        // ever compared equal, one would overwrite the other in every
        // key-addressed dictionary in the power path.
        let magSafe = PortIdentity(typeCode: PortIdentity.magSafeTypeCode, number: 1)
        let usbC = PortIdentity(typeCode: PortIdentity.usbCTypeCode, number: 1)
        #expect(magSafe != usbC)
        #expect(magSafe.key != usbC.key)
        #expect(Set([magSafe, usbC]).count == 2)
    }

    @Test("Codable round-trip keeps both fields")
    func codableRoundTrip() throws {
        // The type is Codable because port keys travel in snapshots.
        let original = PortIdentity(typeCode: 17, number: 2)
        let decoded = try JSONDecoder().decode(PortIdentity.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }
}
