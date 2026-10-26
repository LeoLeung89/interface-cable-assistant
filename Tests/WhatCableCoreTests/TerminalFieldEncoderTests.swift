import Testing
@testable import WhatCableCore

@Suite("Terminal field encoder")
struct TerminalFieldEncoderTests {
    @Test("C0, DEL, and C1 controls become visible text")
    func controlRangesBecomeVisibleText() {
        var controls = ""
        for value in Array(0x00...0x1F) + Array(0x7F...0x9F) {
            controls.unicodeScalars.append(UnicodeScalar(value)!)
        }

        let encoded = TerminalFieldEncoder.encode(controls)
        let remainingControls = encoded.unicodeScalars.filter {
            (0x00...0x1F).contains($0.value) || (0x7F...0x9F).contains($0.value)
        }

        #expect(remainingControls.isEmpty)
        #expect(encoded.contains(#"\u{0}\u{1}"#))
        #expect(encoded.contains(#"\u{1B}"#))
        #expect(encoded.contains(#"\u{7F}\u{80}"#))
        #expect(encoded.hasSuffix(#"\u{9F}"#))
    }

    @Test("Ordinary Unicode is preserved verbatim")
    func ordinaryUnicodeIsPreserved() {
        // Includes RTL letters and a ZWJ emoji sequence: bidi CONTROLS are
        // escaped, but RTL text and emoji joiners must pass through.
        let value = "Café 显示器 🚀 e\u{301} עברית عربى 👨\u{200D}💻"
        #expect(TerminalFieldEncoder.encode(value) == value)
    }

    @Test("Every control and bidi scalar encodes to its exact escape")
    func controlsEncodeExactly() {
        // Exact per-scalar expectations, so an implementation that silently
        // DELETES a control (instead of encoding it visibly) fails here even
        // though the output would contain no control characters. The expected
        // string is built with String(format:), a different formatting path
        // from the encoder's String(radix:), so the two can't share a bug.
        let scalars = Array(0x00...0x1F) + [0x7F] + Array(0x80...0x9F)
            + [0x061C, 0x200E, 0x200F] + Array(0x202A...0x202E) + Array(0x2066...0x2069)
        for value in scalars {
            let input = String(UnicodeScalar(value)!)
            let expected = String(format: "\\u{%X}", value)
            #expect(TerminalFieldEncoder.encode(input) == expected, "U+\(String(format: "%04X", value))")
        }
    }

    @Test("An RTL override cannot reorder a formatter suffix")
    func rtlOverrideIsNeutralised() {
        let name = "Cable\u{202E}s/bG 04 - "
        let encoded = TerminalFieldEncoder.encode(name)
        #expect(!encoded.unicodeScalars.contains { $0.value == 0x202E })
        #expect(encoded.contains(#"\u{202E}"#))
    }
}
