import Testing
@testable import WhatCableDarwinBackend

@Suite("Thunderbolt probe terminal safety")
struct ThunderboltProbeTerminalSafetyTests {
    @Test("--tb-debug property keys and recursive string values encode controls")
    func propertyRenderingEncodesTerminalControls() {
        let rendered = ThunderboltProbe.renderProperties(
            [
                "Unsafe\u{1B}]key\u{7}": [
                    "nested\rkey": "Dock\u{9B}31m\nforged",
                ],
            ],
            indent: "  "
        )

        #expect(!rendered.contains("\u{1B}]key"))
        #expect(!rendered.contains("\u{7}"))
        #expect(!rendered.contains("\u{9B}"))
        #expect(
            rendered.contains(
                #"Unsafe\u{1B}]key\u{7} = {nested\u{D}key="Dock\u{9B}31m\u{A}forged"}"#
            )
        )
    }
}
