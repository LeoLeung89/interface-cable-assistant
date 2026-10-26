import Foundation
import Testing
@testable import WhatCableCore

/// Unit tests for `USBPortMapEntry.parse(_:)` (TB5 tunnel-hub attribution, phase 1).
@Suite("USBPortMapEntry")
struct USBPortMapEntryTests {

    /// The reference JHL9580 capture:
    /// the private notes (tree-attribution, dock-switch5-raw.txt).
    private static let jhl9580Hex = "018194028295038396048497050000"

    private static func data(_ hex: String) -> Data {
        var bytes: [UInt8] = []
        var chars = Array(hex)
        while chars.count >= 2 {
            let pair = String(chars[0..<2])
            bytes.append(UInt8(pair, radix: 16)!)
            chars.removeFirst(2)
        }
        return Data(bytes)
    }

    // MARK: - Floor: the parser must find what we know is there

    @Test("Full JHL9580 map: 4 mapped entries, adapters 20-23, in order")
    func fullJHL9580Map() {
        let entries = USBPortMapEntry.parse(Self.data(Self.jhl9580Hex))
        #expect(entries.count == 4, "expected 4 mapped entries (the 5th triplet is all-zero, unmapped)")
        #expect(entries.map(\.usb4Port) == [1, 2, 3, 4])
        #expect(entries.map(\.usb3Adapter) == [20, 21, 22, 23])
        #expect(entries.map(\.unknownByte) == [0x81, 0x82, 0x83, 0x84])
    }

    // MARK: - JHL8440 (TB4, adapters 17-19)

    @Test("JHL8440-shaped map: 3 mapped entries, adapters 17-19")
    func jhl8440ShapedMap() {
        // Same triplet shape as the JHL9580 reference, adapters shifted down
        // to the JHL8440 range (spec section 2 point 4: "JHL8440 maps
        // adapters 17-19").
        let hex = "018091028192038293"
        let entries = USBPortMapEntry.parse(Self.data(hex))
        #expect(entries.count == 3)
        #expect(entries.map(\.usb4Port) == [1, 2, 3])
        #expect(entries.map(\.usb3Adapter) == [17, 18, 19])
    }

    // MARK: - Truncated maps (zero-downstream boxes)

    @Test("Truncated map (Envoy Ultra shape): single entry")
    func truncatedSingleEntry() {
        let entries = USBPortMapEntry.parse(Self.data("018194"))
        #expect(entries.count == 1)
        #expect(entries[0].usb4Port == 1)
        #expect(entries[0].usb3Adapter == 20)
    }

    @Test("All-zero map (generic USB4 Device shape): no mapped entries")
    func allZeroMap() {
        let entries = USBPortMapEntry.parse(Self.data("010000020000030000040000"))
        #expect(entries.isEmpty)
    }

    // MARK: - Edge cases

    @Test("nil Data parses to empty list")
    func nilDataIsEmpty() {
        #expect(USBPortMapEntry.parse(nil).isEmpty)
    }

    @Test("Empty Data parses to empty list")
    func emptyDataIsEmpty() {
        #expect(USBPortMapEntry.parse(Data()).isEmpty)
    }

    @Test("Garbage length: incomplete trailing triplet is dropped, not misparsed")
    func garbageLengthDropsIncompleteTail() {
        // One full triplet (018194 -> mapped) plus one dangling byte.
        let entries = USBPortMapEntry.parse(Self.data("01819401"))
        #expect(entries.count == 1)
        #expect(entries[0].usb4Port == 1)
        #expect(entries[0].usb3Adapter == 20)
    }

    @Test("Garbage length: two dangling bytes are also dropped")
    func garbageLengthTwoDanglingBytes() {
        let entries = USBPortMapEntry.parse(Self.data("0181"))
        #expect(entries.isEmpty)
    }

    @Test("Third byte without the 0x80 marker bit is skipped, not decoded as adapter 0")
    func thirdByteWithoutMarkerBitIsSkipped() {
        // 0x03 has no 0x80 bit set, so this triplet must not be read as
        // "adapter 3".
        let entries = USBPortMapEntry.parse(Self.data("010203"))
        #expect(entries.isEmpty)
    }

    @Test("Mixed: an unmarked triplet is skipped while marked ones around it still parse")
    func mixedMarkedAndUnmarked() {
        let entries = USBPortMapEntry.parse(Self.data("018194020203038396"))
        #expect(entries.count == 2)
        #expect(entries.map(\.usb4Port) == [1, 3])
        #expect(entries.map(\.usb3Adapter) == [20, 22])
    }
}
