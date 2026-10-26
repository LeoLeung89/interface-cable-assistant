import XCTest
import WhatCableCore
@testable import WhatCable

/// Cover for `PowerSourceList.showsPDProfiles`, the pure decision behind
/// issue #592: "Brick ID" is Apple's analog charger identity node, not a set
/// of PD profiles. Its options are junk placeholder values (5V @ 0.5A) and
/// never carry a winning contract, so the port card must not render them as
/// PD profile rows.
final class PowerSourceListTests: XCTestCase {
    private func source(name: String, options: [PowerOption] = []) -> PowerSource {
        PowerSource(
            id: 1,
            name: name,
            parentPortType: 0x11,
            parentPortNumber: 1,
            options: options,
            winning: nil
        )
    }

    func testBrickIDDoesNotShowProfiles() {
        XCTAssertFalse(PowerSourceList.showsPDProfiles(for: source(name: "Brick ID")))
    }

    func testUSBPDShowsProfiles() {
        XCTAssertTrue(PowerSourceList.showsPDProfiles(for: source(name: "USB-PD")))
    }

    func testTypeCShowsProfiles() {
        XCTAssertTrue(PowerSourceList.showsPDProfiles(for: source(name: "TypeC")))
    }
}
