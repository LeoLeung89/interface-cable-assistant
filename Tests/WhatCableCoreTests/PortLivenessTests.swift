import Testing
@testable import WhatCableCore

@Suite("Port Liveness")
struct PortLivenessTests {

    // MARK: - Fixtures

    private func usbCPort(
        connectionActive: Bool = false
    ) -> USBCPort {
        USBCPort(
            id: 1, serviceName: "Port-USB-C@1", className: "AppleHPMInterfaceType10",
            portDescription: nil, portTypeDescription: "USB-C", portNumber: 1,
            connectionActive: connectionActive,
            activeCable: nil, opticalCable: nil, usbActive: nil, superSpeedActive: nil,
            usbModeType: nil, usbConnectString: nil,
            transportsSupported: [], transportsActive: [], transportsProvisioned: [],
            plugOrientation: nil, plugEventCount: nil, connectionCount: nil,
            overcurrentCount: nil, pinConfiguration: [:], powerCurrentLimits: [],
            firmwareVersion: nil, bootFlagsHex: nil, rawProperties: [:]
        )
    }

    private func magSafePort(
        connectionActive: Bool = false
    ) -> USBCPort {
        USBCPort(
            id: 1, serviceName: "Port-MagSafe 3@1", className: "AppleHPMInterfaceType11",
            portDescription: nil, portTypeDescription: "MagSafe 3", portNumber: 1,
            connectionActive: connectionActive,
            activeCable: nil, opticalCable: nil, usbActive: nil, superSpeedActive: nil,
            usbModeType: nil, usbConnectString: nil,
            transportsSupported: [], transportsActive: [], transportsProvisioned: [],
            plugOrientation: nil, plugEventCount: nil, connectionCount: nil,
            overcurrentCount: nil, pinConfiguration: [:], powerCurrentLimits: [],
            firmwareVersion: nil, bootFlagsHex: nil, rawProperties: [:]
        )
    }

    private func staleUSBPDSource() -> PowerSource {
        PowerSource(
            id: 1, name: "USB-PD", parentPortType: 2, parentPortNumber: 1,
            options: [],
            winning: PowerOption(voltageMV: 20_000, maxCurrentMA: 1490, maxPowerMW: 29_800)
        )
    }

    private func partnerIdentity() -> USBPDSOP {
        USBPDSOP(
            id: 99, endpoint: .sop,
            parentPortType: 0, parentPortNumber: 0,
            vendorID: 0, productID: 0, bcdDevice: 0,
            vdos: [], specRevision: 0
        )
    }

    private func usbDevice() -> USBDevice {
        USBDevice(
            id: 42, locationID: 0, vendorID: 0, productID: 0,
            vendorName: nil, productName: nil, serialNumber: nil,
            usbVersion: nil, speedRaw: nil, busPowerMA: nil, currentMA: nil,
            rawProperties: [:]
        )
    }

    // MARK: - Cases

    @Test("Nothing present is not live")
    func nothingPresentIsNotLive() {
        #expect(!isPortLive(
            port: usbCPort(connectionActive: false),
            powerSources: [], identities: [], matchingDevices: []
        ))
    }

    @Test("USB device makes port live")
    func usbDeviceMakesPortLive() {
        #expect(isPortLive(
            port: usbCPort(connectionActive: false),
            powerSources: [], identities: [], matchingDevices: [usbDevice()]
        ))
    }

    @Test("USB PD SOP makes port live")
    func usbPDSOPMakesPortLive() {
        #expect(isPortLive(
            port: usbCPort(connectionActive: false),
            powerSources: [], identities: [partnerIdentity()], matchingDevices: []
        ))
    }

    /// Issue #573 part 2 (Codex design review "downstream audit omission"):
    /// PD identities are strong liveness evidence (`if !identities.isEmpty
    /// { return true }`), so once `USBPDSOPWatcher` starts producing a
    /// MagSafe cable identity, that identity has to behave the same way as
    /// any other one here. Pinned with a MagSafe-shaped fixture (endpoint
    /// `.sopPrime`, `parentPortType == 17`, empty `vdos`) rather than
    /// trusting the generic `partnerIdentity()` case above to stand in for
    /// it.
    private func magSafeCableIdentity() -> USBPDSOP {
        USBPDSOP(
            id: 1, endpoint: .sopPrime,
            parentPortType: 17, parentPortNumber: 1,
            vendorID: 0x05AC, productID: 0x7800, bcdDevice: 0,
            vdos: [], specRevision: 0
        )
    }

    @Test("A MagSafe cable identity makes the port live")
    func magSafeCableIdentityMakesPortLive() {
        #expect(isPortLive(
            port: magSafePort(connectionActive: false),
            powerSources: [], identities: [magSafeCableIdentity()], matchingDevices: []
        ))
    }

    /// Stale-identity/unplug recovery (Codex design review, "prompt removal
    /// on unplug is correctness, not polish"): the StateCC node PERSISTS
    /// across unplug (unlike the SOP-component classes, whose add/terminate
    /// notifications fire per connection), so a MagSafe cable identity only
    /// ever disappears from `identities` when the watcher's own interest
    /// callback / refresh() removes it. Once it's gone, `connectionActive`
    /// lingering `true` (issue #47, MagSafe-specific) and no charger
    /// attached must still read as not live: the identity's absence is
    /// exactly what liveness is supposed to fall back on here.
    @Test("Removing the MagSafe cable identity (unplug) returns the port to not live, even with a lingering connectionActive flag")
    func removingMagSafeCableIdentityReturnsPortToNotLive() {
        #expect(!isPortLive(
            port: magSafePort(connectionActive: true),   // lingering true, issue #47
            powerSources: [], identities: [], matchingDevices: []
            // no chargerAttached: false by default
        ))
    }

    @Test("Non-MagSafe connectionActive makes port live")
    func nonMagSafeConnectionActiveMakesPortLive() {
        #expect(isPortLive(
            port: usbCPort(connectionActive: true),
            powerSources: [], identities: [], matchingDevices: []
        ))
    }

    // MARK: - Issue #47 regressions

    @Test("Stale power source alone does not make port live")
    func stalePowerSourceAloneDoesNotMakePortLive() {
        // Issue #47: M2 MBA showed disconnected ports as connected because the
        // PowerSourceWatcher held a stale negotiated PDO. The port itself
        // correctly reports connectionActive=false, so the union must not
        // light up purely on the cached source.
        #expect(!isPortLive(
            port: usbCPort(connectionActive: false),
            powerSources: [staleUSBPDSource()],
            identities: [],
            matchingDevices: []
        ))
    }

    @Test("Stale power source on disconnected MagSafe is not live")
    func stalePowerSourceOnDisconnectedMagSafeIsNotLive() {
        // The MagSafe port from issue #47's JSON dump: connectionActive=false,
        // but the watcher still exposes a 30W winning PDO from the previous
        // session. Must not be treated as live.
        #expect(!isPortLive(
            port: magSafePort(connectionActive: false),
            powerSources: [staleUSBPDSource()],
            identities: [],
            matchingDevices: []
        ))
    }

    @Test("Power source with active connection is live")
    func powerSourceWithActiveConnectionIsLive() {
        // Charger genuinely plugged in: power source plus an active
        // connection. This is the case we still want to count as live, on
        // both USB-C and MagSafe.
        #expect(isPortLive(
            port: usbCPort(connectionActive: true),
            powerSources: [staleUSBPDSource()],
            identities: [],
            matchingDevices: []
        ))
        #expect(isPortLive(
            port: magSafePort(connectionActive: true),
            powerSources: [staleUSBPDSource()],
            identities: [],
            matchingDevices: []
        ))
    }

    @Test("MagSafe connectionActive alone is not live")
    func magSafeConnectionActiveAloneIsNotLive() {
        // The original MagSafe quirk: connectionActive=true lingers for
        // several seconds after unplug. Without any other live signal, we
        // shouldn't trust it.
        #expect(!isPortLive(
            port: magSafePort(connectionActive: true),
            powerSources: [], identities: [], matchingDevices: []
        ))
    }

    // MARK: - MagSafe charge-port-hidden (M1/M2: no per-port power source)

    @Test("Connected MagSafe with a charger attached is live, even with no power source")
    func connectedMagSafeWithChargerIsLive() {
        // The reported case (M1/M2 silicon): the MagSafe port reports connected
        // but exposes no per-port power source, so without the charger
        // corroboration it read as "nothing connected" and was hidden.
        #expect(isPortLive(
            port: magSafePort(connectionActive: true),
            powerSources: [], identities: [], matchingDevices: [],
            chargerAttached: true
        ))
    }

    @Test("Connected MagSafe with no charger attached is not live (lingering flag after unplug)")
    func connectedMagSafeWithoutChargerIsNotLive() {
        // connectionActive lingers true for seconds after unplug. With no
        // adapter attached, that must not keep the port live.
        #expect(!isPortLive(
            port: magSafePort(connectionActive: true),
            powerSources: [], identities: [], matchingDevices: [],
            chargerAttached: false
        ))
    }

    @Test("Disconnected MagSafe with a stale PDO stays not live even with a charger attached (issue #47 / #185)")
    func disconnectedMagSafeStalePDONotLiveWithCharger() {
        // The stale-cache case is connectionActive=false. A charger on another
        // port (chargerAttached=true) must not resurrect it, because the new
        // MagSafe branch is gated on connectionActive==true.
        #expect(!isPortLive(
            port: magSafePort(connectionActive: false),
            powerSources: [staleUSBPDSource()],
            identities: [], matchingDevices: [],
            chargerAttached: true
        ))
    }
}
