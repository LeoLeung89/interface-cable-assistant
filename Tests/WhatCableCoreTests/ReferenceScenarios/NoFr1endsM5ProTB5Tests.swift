import Testing
@testable import WhatCableCore

/// Reference-scenario test anchored on the NoFr1ends M5 Pro + UGreen
/// TBT5 Maxidok dump at
/// [research/dumps/tb-fabric/052-nofr1ends-m5pro-ugreen-tb5-dock.md](../../../research/dumps/tb-fabric/052-nofr1ends-m5pro-ugreen-tb5-dock.md).
///
/// The first TB5 active-link sample in the research set. The active
/// link is on Switch #3 (the actual host root, `Router ID = 0`,
/// UID `408828093217315792`, lines 443-507), Port @1:
/// - `Adapter Type = 1` (lane)
/// - `Current Link Speed = 2` (TB5 generation, 40 Gbps per lane)
/// - `Current Link Width = 4` (asymmetric TX: 3 TX / 1 RX → 120 Gbps TX, 40 Gbps RX)
/// - `Supported Link Speed = 14` (`0xE` = TB3 + TB4 + TB5)
/// - `Socket ID = "1"` (maps to Port-USB-C@1)
///
/// **Asymmetric mode is deliberately not modelled** in
/// `LinkGeneration.totalGbps`: TB5 reports 80 Gbps as the symmetric
/// headline. The 120 Gbps TX figure that `system_profiler` shows is
/// the asymmetric uplink; the diagnostic's verdict speaks in symmetric
/// terms. This test pins that contract: TB5 active produces 80 Gbps,
/// not 120 Gbps and not 40 Gbps.
///
/// **Synthesised vs from-dump**:
/// - **From the dump**: active link generation (`Current Link Speed = 2`
///   = TB5, line 473), host capability (`Supported Link Speed = 14`,
///   line 495), the asymmetric width context (`Current Link Width = 4`,
///   line 474; informational only).
/// - **Synthesised**: cable e-marker (TB fabric dumps don't include
///   SOP' VDOs; a TB5 cable encoding speed code 4 is required for the
///   link to come up at TB5), CIO block (not in this fabric-only dump;
///   a stubbed CIO with `CableSpeed = 4` is added to round-trip the
///   conflict-resolution path), port shape (standard M5 Pro USB-C).
@Suite("Reference scenario: NoFr1ends M5 Pro + UGreen TBT5 Maxidok (TB5 active)")
struct NoFr1endsM5ProTB5Tests {

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

    /// Stubbed CIO that mirrors what a TB5 link's controller should
    /// publish. `CableSpeed = 4` is the only field the diagnostic
    /// consumes from CIO; the rest are present for completeness and
    /// future-proofing against new conflict-resolution rules.
    private static func tb5CIO() -> CIOCableCapability {
        CIOCableCapability(
            id: 400,
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

    @Test("TB5 active link reports 80 Gbps headline, not 40 or 120")
    func tb5ActiveLinkReportsSymmetricHeadline() {
        // The dump shows Current Link Speed = 2 (TB5 generation) with
        // asymmetric width 4 (120 Gbps TX / 40 Gbps RX). The diagnostic
        // must speak in symmetric terms (80 Gbps headline). Anything
        // else is a regression: 40 Gbps would mean the speed code was
        // mis-decoded as a per-lane figure; 120 Gbps would mean
        // asymmetric mode leaked into the headline.
        let diag = DataLinkDiagnostic(
            port: Self.hostPort(),
            identities: [Self.cableEmarker(speedCode: 4)],
            devices: [],
            usb3Transports: [],
            cio: Self.tb5CIO(),
            tbActiveGbps: 80,
            hostMaxGbps: 80
        )

        guard case .fine(let active) = diag?.bottleneck else {
            Issue.record("expected .fine(80), got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(active == 80,
            "TB5 symmetric headline. 40 means per-lane leak, 120 means asymmetric leak.")
        #expect(diag!.cableSignalConflict == false)
        #expect(diag!.facts.cableGbps == 80)
        #expect(diag!.facts.hostGbps == 80)
    }

    @Test("LinkGeneration.tb5 has 80 Gbps symmetric headline")
    func linkGenerationTB5SymmetricHeadline() {
        // Pinning the contract directly on LinkGeneration so that
        // changes to its totalGbps mapping show up here as well as
        // wherever the diagnostic consumes it.
        #expect(LinkGeneration.tb5.totalGbps == 80)
        #expect(LinkGeneration.tb5.perLaneGbps == 40)
    }
}
