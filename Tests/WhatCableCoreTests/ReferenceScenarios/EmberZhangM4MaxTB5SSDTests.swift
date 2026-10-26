import Testing
@testable import WhatCableCore

/// Reference-scenario test anchored on the ember-zhang Mac Studio M4 Max
/// multi-port dump at
/// [research/dumps/cio/135-ember-zhang-m4max-three-ports.md](../../../research/dumps/cio/135-ember-zhang-m4max-three-ports.md).
///
/// The source dump captures **three CIO blocks simultaneously** on a
/// single M4 Max host:
/// - Port @1: WERO Thunderbolt 5 SSD (JHL9480 Barlow Ridge, TB5)
/// - Port @2: CalDigit TS3 Plus (JHL6540 Alpine Ridge, TB3)
/// - Port @3: ACASIS TBU405Pro (JHL7440 Titan Ridge, TB3 silicon despite TB4 marketing)
///
/// **This PR covers Port @1 (TB5 SSD) only.** Ports @2 and @3 represent
/// TB3-silicon downstream devices on a TB5-class host (the "device is
/// the cap" case). Asserting the right verdict on those needs a
/// partner-switch fixture with the JHL6540 / JHL7440 capability mask,
/// which the CIO-only dump does not provide. Adding those scenarios is
/// a flagged follow-up that should fetch the missing tb-fabric data
/// from the same M4 Max so the partner switch is sourced rather than
/// synthesised.
///
/// **Synthesised vs from-dump for Port @1**:
/// - **From the dump**: CIO codes for the WERO SSD (lines 56-98 of the
///   source), Device Vendor Name "WERO" (line 93), `CableSpeed = 4`
///   (TB5 80 Gbps) at line 97, `Generation = 3` (M4 Max host-tagged) at
///   line 69, `CableGeneration = 2` at line 89.
/// - **Synthesised**: cable e-marker (the CIO dump alone does not
///   include the SOP' VDOs; a TB5 cable encoding speed code 4 is
///   inferred from the fact that the link came up at TB5 — only a TB5
///   cable can negotiate `CableSpeed = 4`), host max (80 Gbps, M4 Max
///   `IOThunderboltSwitchType7` silicon supports TB5), active link
///   (80 Gbps, the symmetric headline; asymmetric mode is deliberately
///   not modelled in `LinkGeneration.totalGbps`).
@Suite("Reference scenario: ember-zhang M4 Max + WERO TB5 SSD (Port @1)")
struct EmberZhangM4MaxTB5SSDTests {

    private static func hostPort() -> AppleHPMInterface {
        AppleHPMInterface(
            id: 1,
            serviceName: "Port-USB-C@1",
            className: "AppleHPMInterfaceType10",
            portDescription: "Port-USB-C@1",
            portTypeDescription: "USB-C",
            portNumber: 1,
            connectionActive: true,
            activeCable: nil,
            opticalCable: nil,
            usbActive: true,
            superSpeedActive: true,
            usbModeType: nil,
            usbConnectString: nil,
            transportsSupported: ["CC", "USB2", "USB3", "CIO", "DisplayPort"],
            transportsActive: ["CC", "USB3", "CIO"],
            transportsProvisioned: ["CC"],
            plugOrientation: nil,
            plugEventCount: nil,
            connectionCount: nil,
            overcurrentCount: nil,
            pinConfiguration: [:],
            powerCurrentLimits: [],
            firmwareVersion: nil,
            bootFlagsHex: nil,
            rawProperties: [:]
        )
    }

    /// CIO block for the WERO Thunderbolt 5 SSD at Port @1.
    /// Field origins (all from the source dump):
    /// - `CableSpeed = 4` (TB5, 80 Gbps headline) at line 97
    /// - `CableGeneration = 2` at line 89
    /// - `Generation = 3` at line 69
    /// - `LinkTrainingMode = 2` at line 59
    /// - `AsymmetricModeSupported = Yes` at line 62
    /// - `LegacyAdapter = No` at line 76
    private static func weroSSDCIO() -> CIOCableCapability {
        CIOCableCapability(
            id: 300,
            portKey: "2/1",
            cableGeneration: 2,
            negotiatedLinkSpeed: 4,
            generation: 3,
            asymmetricModeSupported: true,
            legacyAdapter: false,
            linkTrainingMode: 2
        )
    }

    private static func cableEmarker(speedCode: UInt32) -> USBPDSOP {
        let validLatency: UInt32 = 1 << 13
        let cableVDO = speedCode | (1 << 5) | validLatency
        let idHeader: UInt32 = 0x1800_0000
        return USBPDSOP(
            id: 2, endpoint: .sopPrime,
            parentPortType: 2, parentPortNumber: 1,
            vendorID: 0, productID: 0, bcdDevice: 0,
            vdos: [idHeader, 0, 0, cableVDO],
            specRevision: 0
        )
    }

    @Test("TB5 SSD on M4 Max: full 80 Gbps, no conflict")
    func weroTB5SSD_FullSpeed() {
        // TB5 cable (speed code 4 = 80 Gbps) feeding a TB5 SSD on a TB5
        // host. All three parties at 80 Gbps. Expect .fine(80) with
        // cableSignalConflict = false.
        let diag = DataLinkDiagnostic(
            port: Self.hostPort(),
            identities: [Self.cableEmarker(speedCode: 4)],
            devices: [],
            usb3Transports: [],
            cio: Self.weroSSDCIO(),
            tbActiveGbps: 80,
            hostMaxGbps: 80
        )

        guard case .fine(let active) = diag?.bottleneck else {
            Issue.record("expected .fine(80), got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(active == 80)
        #expect(diag!.cableSignalConflict == false)
        #expect(diag!.facts.cableEmarkerGbps == 80)
        #expect(diag!.facts.cableControllerGbps == 80)
        #expect(diag!.facts.cableGbps == 80)
        #expect(diag!.facts.hostGbps == 80)
    }
}
