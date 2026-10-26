import Foundation
import Testing
@testable import WhatCableCore

/// issue #181 test matrix item 2 ("Transient repro (the bug)"): a synthetic
/// snapshot with `TransportsActive` carrying USB3, a matching
/// `USB3Transport` present, zero enumerated devices, and TRM clear. This is
/// exactly the mid-handshake state the HPM port controller briefly
/// publishes for a charger-only cable (no SuperSpeed peer) before PD
/// negotiation withdraws it (issue #181, The Verge review).
///
/// Per the spec's process, this test MUST fail on unmodified `main` --
/// written first, watched fail, then the gate implemented. See the commit
/// introducing the gate for the captured failing output.
@Suite("USB3 transient repro (issue #181)")
struct USB3TransientReproTests {

    private func port() -> AppleHPMInterface {
        AppleHPMInterface(
            id: 1,
            serviceName: "Port-USB-C@1",
            className: "AppleHPMInterfaceType10",
            portDescription: nil,
            portTypeDescription: "USB-C",
            portNumber: 1,
            connectionActive: true,
            activeCable: nil,
            opticalCable: nil,
            usbActive: nil,
            superSpeedActive: nil,
            usbModeType: nil,
            usbConnectString: nil,
            transportsSupported: ["CC", "USB2", "USB3"],
            transportsActive: ["USB3"],
            transportsProvisioned: [],
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

    /// The transient transport: signaling present, TRM clear, not
    /// restricted -- exactly what the handshake publishes before PD
    /// negotiation discovers there is no data peer.
    private func transientTransport() -> USB3Transport {
        USB3Transport(
            id: 500, portKey: "2/1", signaling: 2,
            signalingDescription: "Gen 2", dataRole: "host",
            transportRestricted: false
        )
    }

    @Test("PortSummary bullet is absent for the transient-only handshake")
    func portSummaryBulletAbsent() {
        let summary = PortSummary(port: port(), devices: [], usb3Transports: [transientTransport()])
        #expect(
            summary.bullets.contains { $0.contains("USB 3.2") || $0.contains("SuperSpeed") } == false,
            "transient-only handshake must not show a USB3 speed line, got: \(summary.bullets)")
    }

    @Test("PortSummary headline falls back to charger-only copy for the transient handshake")
    func portSummaryHeadlineFallsBack() {
        let summary = PortSummary(port: port(), devices: [], usb3Transports: [transientTransport()])
        #expect(
            summary.headline.contains("USB device") == false,
            "headline must not claim an active USB device for an uncorroborated transient handshake, got: \(summary.headline)")
    }

    @Test("PortSummary link-speed badge is absent for the transient handshake")
    func portSummaryBadgeAbsent() {
        let summary = PortSummary(port: port(), devices: [], usb3Transports: [transientTransport()])
        #expect(summary.linkSpeed == nil,
            "badge must not flash 5G for an uncorroborated transient handshake, got: \(String(describing: summary.linkSpeed))")
    }

    @Test("JSONFormatter has no usb3Speed for the transient handshake")
    func jsonHasNoUsb3Speed() throws {
        let json = try JSONFormatter.render(
            ports: [port()], sources: [], identities: [], showRaw: false,
            usb3Transports: [transientTransport()]
        )
        guard let data = json.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ports = obj["ports"] as? [[String: Any]],
              let transports = ports.first?["transports"] as? [String: Any]
        else {
            Issue.record("could not parse rendered JSON")
            return
        }
        #expect(transports["usb3Speed"] == nil || transports["usb3Speed"] is NSNull,
            "JSON must not emit usb3Speed for an uncorroborated transient handshake, got: \(String(describing: transports["usb3Speed"]))")
    }

    @Test("DataLinkDiagnostic gives no verdict for the transient handshake")
    func dataLinkDiagnosticNilVerdict() {
        let diag = DataLinkDiagnostic(
            port: port(), identities: [], devices: [],
            usb3Transports: [transientTransport()], cio: nil
        )
        #expect(diag == nil,
            "DataLinkDiagnostic must not produce a verdict for an uncorroborated transient handshake, got: \(String(describing: diag?.bottleneck))")
    }

    // MARK: - USB2 fallback flip (`!hasUSB3` -> `!hasCorroboratedUSB3`)
    //
    // Review finding: the tests above only prove a bare-USB3 transient
    // shows no line; none of them exercise a port running USB2 AND a
    // transient USB3 handshake at once, which is the ONLY shape that can
    // tell the difference between gating on the raw `hasUSB3` flag (the
    // pre-fix behaviour) and the corroborated one. On a raw `hasUSB3`
    // gate, the USB2 fallback branch (`hasUSB2 && !hasUSB3`) would be
    // unreachable during the transient window -- PortSummary would fall
    // through with NO measured line at all, not the correct "Slow USB
    // device or charge-only cable" copy. These three tests pin the exact
    // byte-for-byte headline/status/subtitle on both sides of that branch.

    private func portWithUSB2AndTransientUSB3() -> AppleHPMInterface {
        AppleHPMInterface(
            id: 1,
            serviceName: "Port-USB-C@1",
            className: "AppleHPMInterfaceType10",
            portDescription: nil,
            portTypeDescription: "USB-C",
            portNumber: 1,
            connectionActive: true,
            activeCable: nil,
            opticalCable: nil,
            usbActive: nil,
            superSpeedActive: nil,
            usbModeType: nil,
            usbConnectString: nil,
            transportsSupported: ["CC", "USB2", "USB3"],
            transportsActive: ["CC", "USB2", "USB3"],
            transportsProvisioned: [],
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

    @Test("Uncorroborated USB2+transient-USB3 falls through to the exact USB2 charge-only copy")
    func uncorroboratedUSB2PlusTransientUSB3FallsToUSB2Copy() {
        let summary = PortSummary(
            port: portWithUSB2AndTransientUSB3(), devices: [],
            usb3Transports: [transientTransport()]
        )
        #expect(summary.status == .dataDevice, "got: \(summary.status)")
        #expect(summary.headline == "Slow USB device or charge-only cable", "got: \(summary.headline)")
        #expect(summary.subtitle == "Only USB 2.0 is active. If you expected high speed, the cable may not support it.",
            "got: \(summary.subtitle)")
        #expect(summary.bullets.contains { $0.contains("USB 3.2") || $0.contains("SuperSpeed") } == false,
            "must not show a USB3 speed line, got: \(summary.bullets)")
    }

    @Test("Corroborated USB2+USB3 shows the USB3 copy, not the USB2 fallback")
    func corroboratedUSB2PlusUSB3ShowsUSB3Copy() {
        // Same port, same USB2 in TransportsActive, but the USB3 transport
        // is TRM-restricted -- corroborated -- so USB3 must win the branch,
        // not USB2. Data-withheld wording needs EVERY active data
        // transport withheld (PortSummary's own documented rule 2: a port
        // can run USB2 and USB3 at once with only one withheld, and that
        // port really does carry data); no TRM record is supplied for
        // USB2 here, so dataWithheld is correctly false and the headline
        // is the plain "USB device" / "SuperSpeed data link is active."
        // copy, not the blocked wording. What this test actually pins is
        // the BRANCH: USB3, not USB2 -- proven by the headline text
        // itself ("USB device", the USB3 branch's wording, never
        // "Slow USB device or charge-only cable", the USB2 branch's).
        let restricted = USB3Transport(
            id: 501, portKey: "2/1", signaling: 1,
            signalingDescription: "Gen 1", dataRole: "host",
            transportRestricted: true
        )
        let summary = PortSummary(
            port: portWithUSB2AndTransientUSB3(), devices: [],
            usb3Transports: [restricted]
        )
        #expect(summary.status == .dataDevice, "got: \(summary.status)")
        #expect(summary.headline == "USB device", "got: \(summary.headline)")
        #expect(summary.subtitle == "SuperSpeed data link is active.",
            "got: \(summary.subtitle)")
    }

    // MARK: - Quick-swap stale device: the accepted residual, pinned
    //
    // The spec's round-2 decision (see
    // the private design note "USB3 speed corroboration", "Quick-swap stale
    // device: ACCEPTED RESIDUAL") is that corroboration cannot tell WHICH
    // attachment an enumerated device belongs to: macOS publishes no
    // attachment-generation identity. So if a SuperSpeed device is
    // unplugged and a charger-only cable attached before `USBWatcher`
    // delivers the removal, the stale device corroborates the new
    // handshake's transient and the flash can still show for that window.
    //
    // The residual was accepted, not fixed: closing it needs an identity
    // the OS does not publish, and the alternative (a timer or debounce)
    // was rejected by the ticket because it would add perceived lag to
    // every genuine data cable. What is NOT accepted is the label
    // outliving the removal. These two tests pin both halves as an ordered
    // sequence -- the same port, the same transient transport, two
    // consecutive snapshots differing only in whether the stale device is
    // still enumerated:
    //
    //   step 1 (stale window): device still present  -> label MAY show
    //   step 2 (removal lands): device gone          -> label MUST be gone
    //
    // Step 2 carries the guarantee. Step 1 is characterisation: it records
    // that today the stale device does corroborate. If a future change
    // gives us real attachment identity, step 1 goes red, and that is an
    // improvement -- update it to expect nil and delete this note.

    /// The stale device: a root SuperSpeed device left over from the
    /// PREVIOUS attachment, still in the list because its removal
    /// notification has not landed yet.
    private func staleSuperSpeedDevice() -> USBDevice {
        USBDevice(
            id: 9100, locationID: 0x0020_0000,
            vendorID: 0x1234, productID: 0x5678,
            vendorName: nil, productName: "Previously attached SSD",
            serialNumber: nil,
            usbVersion: nil, speedRaw: 3,
            busPowerMA: nil, currentMA: nil,
            rawProperties: [:]
        )
    }

    @Test("Quick-swap step 1: a stale device from the previous attachment still corroborates (accepted residual)")
    func quickSwapStaleDeviceStillCorroborates() {
        let stale = staleSuperSpeedDevice()

        #expect(
            USB3SpeedCorroboration.isCorroborated(
                selected: transientTransport(), devices: [stale]
            ),
            "characterisation: with no attachment identity, a stale enumerated SuperSpeed device corroborates the new handshake")

        let summary = PortSummary(
            port: port(), devices: [stale], usb3Transports: [transientTransport()]
        )
        #expect(
            summary.linkSpeed != nil,
            "characterisation: the residual window does show a badge; if this is now nil the residual has been closed, see the note above")
    }

    @Test("Quick-swap step 2: the label clears the moment the removal lands")
    func quickSwapLabelClearsOnRemoval() {
        // Same port, same transport, same instant of port-controller state
        // as step 1. The ONLY difference is that the stale device's removal
        // has now been delivered, so the device list is empty. This is the
        // half that is guaranteed, not merely characterised.
        let settled = PortSummary(port: port(), devices: [], usb3Transports: [transientTransport()])

        #expect(settled.linkSpeed == nil,
            "the badge must not outlive the stale device's removal, got: \(String(describing: settled.linkSpeed))")
        #expect(
            settled.bullets.contains { $0.contains("USB 3.2") || $0.contains("SuperSpeed") } == false,
            "no USB3 speed line may survive the removal, got: \(settled.bullets)")
        #expect(settled.headline.contains("USB device") == false,
            "headline must not still claim an active USB device, got: \(settled.headline)")
        #expect(
            USB3SpeedCorroboration.isCorroborated(
                selected: transientTransport(), devices: []
            ) == false,
            "corroboration itself must go false once the device list empties")
    }

    @Test("Quick-swap: the two steps genuinely differ, so the sequence is not vacuous")
    func quickSwapStepsDiffer() {
        // Guards against both halves passing for the same reason (e.g. a
        // fixture change that makes the stale device stop corroborating,
        // which would leave step 2 asserting nothing about the removal).
        let withStale = PortSummary(
            port: port(), devices: [staleSuperSpeedDevice()],
            usb3Transports: [transientTransport()]
        )
        let afterRemoval = PortSummary(
            port: port(), devices: [], usb3Transports: [transientTransport()]
        )
        #expect(withStale.linkSpeed != afterRemoval.linkSpeed,
            "the stale window and the settled state must differ, or step 2 proves nothing")
    }

    // MARK: - A dock's own device must never corroborate the host port
    //
    // Found by adversarial review of this PR. `rootSuperSpeed` keys on
    // `isRootDevice`, which counts locationID hub nibbles, and a locationID
    // is relative to whichever controller enumerated the device. A drive
    // plugged straight into a Thunderbolt dock is a "root" device of the
    // DOCK's controller: one nibble, SuperSpeed, passes the test. Measured
    // on the corpus: 122 such devices across 84 machines.
    //
    // One caller (`CableDiagnosticView`, the Pro pin diagram) passes the
    // tunnel-inclusive device union, so before the fix a dock's drive could
    // corroborate the HOST port and light a phantom speed label during the
    // exact handshake window this PR exists to suppress. The filter now
    // lives inside `isCorroborated`, so it holds for every caller rather
    // than depending on each one scoping its list correctly.

    /// A SuperSpeed drive plugged into a dock: one locationID nibble, so it
    /// looks exactly like a directly-attached root device.
    private func dockAttachedSuperSpeedDevice() -> USBDevice {
        USBDevice(
            id: 9400, locationID: 0x0210_0000,
            vendorID: 0x1234, productID: 0x5678,
            vendorName: nil, productName: "Drive in a dock", serialNumber: nil,
            usbVersion: nil, speedRaw: 4,
            busPowerMA: nil, currentMA: nil,
            isThunderboltTunnelled: true,
            rawProperties: [:]
        )
    }

    @Test("A dock-attached SuperSpeed device looks like a root device but must not corroborate")
    func tunnelledRootLookingDeviceDoesNotCorroborate() {
        let dockDevice = dockAttachedSuperSpeedDevice()

        // The trap, asserted so the test cannot pass because the fixture
        // stopped being root-shaped: this device DOES satisfy the root test.
        #expect(dockDevice.isRootDevice,
            "fixture must reproduce the trap: a dock-attached device with a single locationID nibble")
        #expect(USBDevice.rootSuperSpeed(in: [dockDevice]) != nil,
            "fixture must reproduce the trap: rootSuperSpeed does not itself exclude tunnelled devices")

        #expect(
            USB3SpeedCorroboration.isCorroborated(
                selected: transientTransport(), devices: [dockDevice]
            ) == false,
            "a device behind a dock must not corroborate the host port's native USB3 reading")

        let summary = PortSummary(
            port: port(), devices: [dockDevice], usb3Transports: [transientTransport()]
        )
        #expect(summary.linkSpeed == nil,
            "no phantom badge from a dock's own device, got: \(String(describing: summary.linkSpeed))")
    }

    @Test("A NAMELESS device behind the Mac's own internal hub must not corroborate")
    func namelessInternalHubDeviceDoesNotCorroborate() {
        // No `controllerPortName`, so no port ever claimed it: it belongs
        // to no physical port and must corroborate none.
        let builtIn = USBDevice(
            id: 9401, locationID: 0x0810_0000,
            vendorID: 0x1234, productID: 0x5678,
            vendorName: nil, productName: "Front-panel drive", serialNumber: nil,
            usbVersion: nil, speedRaw: 4,
            busPowerMA: nil, currentMA: nil,
            isBehindInternalHub: true,
            rawProperties: [:]
        )
        #expect(builtIn.isRootDevice, "fixture must reproduce the trap")
        #expect(
            USB3SpeedCorroboration.isCorroborated(
                selected: transientTransport(), devices: [builtIn]
            ) == false,
            "an unclaimed board-hub device must not corroborate a USB-C port")
    }

    @Test("A NAMED desktop front-port device behind the internal hub DOES corroborate")
    func namedInternalHubDeviceCorroborates() {
        // The regression both reviewers caught. On a desktop, a front USB-C
        // port's device sits behind the Mac's own board hub AND carries an
        // exact port name, which is how `matchingDevices` attributes it
        // (issue #456). It is genuinely this port's device on a genuinely
        // SuperSpeed link, so it must corroborate. Real corpus machine:
        // m1_macos26.5.2_f Port-USB-C@3, a WD My Book behind a Satechi hub.
        // A filter that dropped every internal-hub device cost this port
        // its speed line.
        let frontPortDrive = USBDevice(
            id: 9402, locationID: 0x0810_0000,
            vendorID: 0x1234, productID: 0x5678,
            vendorName: nil, productName: "My Book", serialNumber: nil,
            usbVersion: nil, speedRaw: 3,
            busPowerMA: nil, currentMA: nil,
            controllerPortName: "Port-USB-C@1",
            isBehindInternalHub: true,
            rawProperties: [:]
        )
        // Precondition: the port really does claim this device, so the test
        // is about corroboration rather than an unreachable fixture.
        #expect(port().claimsInternalHubDevice(frontPortDrive),
            "PRECONDITION: the port must actually claim this device by exact name")

        #expect(
            USB3SpeedCorroboration.isCorroborated(
                selected: transientTransport(), devices: [frontPortDrive]
            ),
            "a named desktop front-port device must still corroborate its port")

        let summary = PortSummary(
            port: port(), devices: [frontPortDrive], usb3Transports: [transientTransport()]
        )
        #expect(summary.linkSpeed != nil,
            "the desktop front port must keep its speed badge")
    }

    @Test("USB2-only (no USB3 in TransportsActive) is byte-stable, unaffected by the flip")
    func usb2OnlyIsByteStable() {
        let port = AppleHPMInterface(
            id: 1,
            serviceName: "Port-USB-C@1",
            className: "AppleHPMInterfaceType10",
            portDescription: nil,
            portTypeDescription: "USB-C",
            portNumber: 1,
            connectionActive: true,
            activeCable: nil,
            opticalCable: nil,
            usbActive: nil,
            superSpeedActive: nil,
            usbModeType: nil,
            usbConnectString: nil,
            transportsSupported: ["CC", "USB2"],
            transportsActive: ["CC", "USB2"],
            transportsProvisioned: [],
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
        let summary = PortSummary(port: port, devices: [], usb3Transports: [])
        #expect(summary.status == .dataDevice, "got: \(summary.status)")
        #expect(summary.headline == "Slow USB device or charge-only cable", "got: \(summary.headline)")
        #expect(summary.subtitle == "Only USB 2.0 is active. If you expected high speed, the cable may not support it.",
            "got: \(summary.subtitle)")
    }
}
