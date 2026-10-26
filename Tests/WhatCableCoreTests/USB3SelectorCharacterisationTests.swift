import Foundation
import Testing
@testable import WhatCableCore

/// issue #181 selector migration, step two of two (step one:
/// the private design note "USB3 speed corroboration", "Characterisation tests,
/// two committed steps"). Step one committed this file recording each
/// surface's PRE-migration selection for a fixture with BOTH a tunnelled
/// and a direct USB3 transport canonically matching the same port, in both
/// array orders. This commit is step two: it deliberately updates those
/// same test bodies to the POST-migration (`USB3SpeedCorroboration`)
/// selection, so the before/after delta lives in this file's git history as
/// a checked artifact, per the spec.
///
/// Pre-migration finding (unchanged from step one, kept for context):
///
/// - `PortSummary` and `JSONFormatter` did NOT exclude tunnelled entries.
///   Their selection was ARRAY-ORDER DEPENDENT: whichever candidate was
///   first in the array won, tunnelled or not.
/// - `DataLinkDiagnostic` already filtered `tunnelled != true` before
///   selecting, so its selection was already order-independent for this
///   fixture and already preferred the direct entry.
///
/// Post-migration reality (this commit): all three now go through
/// `USB3SpeedCorroboration.selectedTransport`, which excludes tunnelled
/// entries unconditionally, so all three are now order-independent and
/// agree with each other. BUT the `device()` fixture below is not actually
/// a root SuperSpeed device (its locationID has zero non-zero hub-path
/// nibbles, not the one `USBDevice.isRootDevice` requires -- kept
/// unchanged from step one rather than quietly "fixed", since fixing it
/// would have changed the fixture step one already pinned) and neither
/// transport is TRM-restricted, so NEITHER arm of
/// `USB3SpeedCorroboration.isCorroborated` fires. The issue #181 corroboration
/// gate (landing in this same commit) therefore suppresses the speed label
/// on ALL FOUR of the original tests below, regardless of array order: the
/// selector fix and the corroboration gate compound here. The dedicated
/// "corroborated" tests further down isolate the selector fix alone, using
/// a TRM-restricted transport (which corroborates on its own, independent
/// of any device) so order-independence is visible on a label that
/// actually renders.
@Suite("USB3 selector: pre/post migration characterisation")
struct USB3SelectorCharacterisationTests {

    // MARK: - Fixtures

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
            transportsSupported: ["CC", "USB2", "USB3", "CIO"],
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

    /// Tunnelled entry (a dock's internal Port-USB-C@1/CIO/USB3@0 node)
    /// sharing this port's `portKey`, reporting Gen 2.
    private func tunnelledGen2() -> USB3Transport {
        USB3Transport(
            id: 900, portKey: "2/1", signaling: 2,
            signalingDescription: "Gen 2", dataRole: "host",
            tunnelled: true
        )
    }

    /// The port's own direct entry, reporting Gen 1.
    private func directGen1() -> USB3Transport {
        USB3Transport(
            id: 901, portKey: "2/1", signaling: 1,
            signalingDescription: "Gen 1", dataRole: "host",
            tunnelled: false
        )
    }

    /// Restricted variant of the direct entry: TRM-restricted, so it
    /// corroborates on its own (`USB3SpeedCorroboration.isCorroborated`'s
    /// second arm) without needing an enumerated device. Used by the
    /// "corroborated" tests below to isolate the selector fix from the
    /// issue #181 gate.
    private func directGen1Restricted() -> USB3Transport {
        USB3Transport(
            id: 901, portKey: "2/1", signaling: 1,
            signalingDescription: "Gen 1", dataRole: "host",
            transportRestricted: true, tunnelled: false
        )
    }

    private func device() -> USBDevice {
        // A present-but-NON-corroborating device: USB 2, so no arm of
        // `USB3SpeedCorroboration.isCorroborated` fires. The "corroborated"
        // tests below get their corroboration from
        // `directGen1Restricted()`, exactly as their doc says, so this
        // fixture's only job is to be a device that proves nothing.
        //
        // It used to be a SuperSpeed device at locationID 0x0100_0000,
        // relying on that value having ZERO non-zero hub-path nibbles so it
        // failed `isRootDevice`. That was an artifact, not a real shape: a
        // genuinely enumerated device always has at least one nibble (one
        // for a root device, more behind a hub). When corroboration learned
        // to accept hub-nested SuperSpeed devices (the macOS 15 fix), that
        // artifact started corroborating and these four tests went red.
        // Being USB 2 is a real reason not to corroborate, so the tests now
        // rest on one.
        USBDevice(
            id: 10, locationID: 0x0100_0000,
            vendorID: 0x1234, productID: 0x5678,
            vendorName: nil, productName: "Test SSD", serialNumber: nil,
            usbVersion: nil, speedRaw: 2,
            busPowerMA: nil, currentMA: nil,
            rawProperties: [:]
        )
    }

    // MARK: - PortSummary: uncorroborated post-migration, order no longer matters

    @Test("PortSummary post-migration: tunnelled-first array now shows NO USB3 label (uncorroborated)")
    func portSummaryTunnelledFirstPicksTunnelled() {
        let summary = PortSummary(
            port: port(), devices: [device()],
            usb3Transports: [tunnelledGen2(), directGen1()]
        )
        #expect(
            summary.bullets.contains { $0.contains("USB 3.2") || $0.contains("SuperSpeed") } == false,
            "got: \(summary.bullets)")
    }

    @Test("PortSummary post-migration: direct-first array now shows NO USB3 label (uncorroborated)")
    func portSummaryDirectFirstPicksDirect() {
        let summary = PortSummary(
            port: port(), devices: [device()],
            usb3Transports: [directGen1(), tunnelledGen2()]
        )
        #expect(
            summary.bullets.contains { $0.contains("USB 3.2") || $0.contains("SuperSpeed") } == false,
            "got: \(summary.bullets)")
    }

    // MARK: - JSONFormatter: same post-migration shape

    @Test("JSONFormatter post-migration: tunnelled-first array now has NO usb3Speed (uncorroborated)")
    func jsonFormatterTunnelledFirstPicksTunnelled() throws {
        let json = try JSONFormatter.render(
            ports: [port()], sources: [], identities: [], showRaw: false,
            usb3Transports: [tunnelledGen2(), directGen1()],
            usbDevices: [device()]
        )
        #expect(usb3Speed(from: json) == nil, "got: \(String(describing: usb3Speed(from: json)))")
    }

    @Test("JSONFormatter post-migration: direct-first array now has NO usb3Speed (uncorroborated)")
    func jsonFormatterDirectFirstPicksDirect() throws {
        let json = try JSONFormatter.render(
            ports: [port()], sources: [], identities: [], showRaw: false,
            usb3Transports: [directGen1(), tunnelledGen2()],
            usbDevices: [device()]
        )
        #expect(usb3Speed(from: json) == nil, "got: \(String(describing: usb3Speed(from: json)))")
    }

    // MARK: - DataLinkDiagnostic: same post-migration shape

    @Test("DataLinkDiagnostic post-migration: tunnelled-first array now gives NO verdict (uncorroborated)")
    func dataLinkDiagnosticTunnelledFirstStillPicksDirect() {
        let diag = DataLinkDiagnostic(
            port: port(), identities: [], devices: [device()],
            usb3Transports: [tunnelledGen2(), directGen1()], cio: nil
        )
        #expect(diag == nil, "got: \(String(describing: diag?.bottleneck))")
    }

    @Test("DataLinkDiagnostic post-migration: direct-first array now gives NO verdict (uncorroborated)")
    func dataLinkDiagnosticDirectFirstPicksDirect() {
        let diag = DataLinkDiagnostic(
            port: port(), identities: [], devices: [device()],
            usb3Transports: [directGen1(), tunnelledGen2()], cio: nil
        )
        #expect(diag == nil, "got: \(String(describing: diag?.bottleneck))")
    }

    // MARK: - Corroborated: the selector fix in isolation
    //
    // Same tunnelled-vs-direct fixture, but the direct entry is
    // TRM-restricted, so `isCorroborated` fires on its own arm regardless
    // of any device. This isolates the selector fix (tunnelled exclusion,
    // order-independence) from the issue #181 corroboration gate: these tests
    // show a label rendering, and prove it is always the DIRECT one.

    @Test("PortSummary corroborated: tunnelled-first array picks the DIRECT (Gen 1) entry")
    func portSummaryCorroboratedTunnelledFirstPicksDirect() {
        let summary = PortSummary(
            port: port(),
            usb3Transports: [tunnelledGen2(), directGen1Restricted()]
        )
        #expect(summary.bullets.contains { $0.contains("USB 3.2 Gen 1 (5 Gbps)") },
            "got: \(summary.bullets)")
        #expect(summary.bullets.contains { $0.contains("Gen 2") } == false,
            "must never surface the tunnelled entry's Gen 2 reading, got: \(summary.bullets)")
    }

    @Test("PortSummary corroborated: direct-first array picks the same DIRECT (Gen 1) entry")
    func portSummaryCorroboratedDirectFirstPicksDirect() {
        let summary = PortSummary(
            port: port(),
            usb3Transports: [directGen1Restricted(), tunnelledGen2()]
        )
        #expect(summary.bullets.contains { $0.contains("USB 3.2 Gen 1 (5 Gbps)") },
            "got: \(summary.bullets)")
    }

    @Test("JSONFormatter corroborated: tunnelled-first array picks the DIRECT (Gen 1) entry")
    func jsonFormatterCorroboratedTunnelledFirstPicksDirect() throws {
        let json = try JSONFormatter.render(
            ports: [port()], sources: [], identities: [], showRaw: false,
            usb3Transports: [tunnelledGen2(), directGen1Restricted()]
        )
        #expect(usb3Speed(from: json) == "USB 3.2 Gen 1 (5 Gbps)")
    }

    @Test("JSONFormatter corroborated: direct-first array picks the same DIRECT (Gen 1) entry")
    func jsonFormatterCorroboratedDirectFirstPicksDirect() throws {
        let json = try JSONFormatter.render(
            ports: [port()], sources: [], identities: [], showRaw: false,
            usb3Transports: [directGen1Restricted(), tunnelledGen2()]
        )
        #expect(usb3Speed(from: json) == "USB 3.2 Gen 1 (5 Gbps)")
    }

    @Test("DataLinkDiagnostic corroborated: tunnelled-first array picks the same direct (Gen 1) entry")
    func dataLinkDiagnosticCorroboratedTunnelledFirstPicksDirect() throws {
        let diag = try #require(DataLinkDiagnostic(
            port: port(), identities: [], devices: [],
            usb3Transports: [tunnelledGen2(), directGen1Restricted()], cio: nil
        ))
        if case .blockedBySecurity(let signaledGbps) = diag.bottleneck {
            #expect(signaledGbps == 5, "expected the direct Gen 1 (5 Gbps) entry's signaled rate, got \(signaledGbps)")
        } else {
            Issue.record("expected .blockedBySecurity (the direct entry is TRM-restricted), got \(diag.bottleneck)")
        }
    }

    // MARK: - Helpers

    private func usb3Speed(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ports = obj["ports"] as? [[String: Any]],
              let transports = ports.first?["transports"] as? [String: Any]
        else { return nil }
        return transports["usb3Speed"] as? String
    }
}
