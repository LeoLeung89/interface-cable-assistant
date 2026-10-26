import Testing
@testable import WhatCableCore

/// Covers the purely-visual smoothing added for #536: macOS re-attributing a
/// single power source between MagSafe and a USB-C port every 1-2 seconds
/// should not pop a "Hide empty ports" card in and out, or reorder the card
/// list.
@Suite("Port Visibility Tracker (#536)")
struct PortVisibilityTrackerTests {

    // MARK: - PortVisibilityTracker

    @Test("Attribution flap: charger-only port stays live throughout")
    func attributionFlapStaysLive() {
        let tracker = PortVisibilityTracker()
        let key = "Port-USB-C@1"

        // Power attributed here, then flips away, then back, every "second",
        // mimicking the observed 1-2s churn. As long as the gaps are inside
        // the grace window the port should never read as anything but live
        // or fading, never hidden.
        var t: Double = 0
        #expect(tracker.evaluate(portKey: key, nonPowerLive: false, powerLive: true, now: t) == .live)
        t += 1
        #expect(tracker.evaluate(portKey: key, nonPowerLive: false, powerLive: false, now: t) == .fading)
        t += 1
        #expect(tracker.evaluate(portKey: key, nonPowerLive: false, powerLive: true, now: t) == .live)
        t += 1
        #expect(tracker.evaluate(portKey: key, nonPowerLive: false, powerLive: false, now: t) == .fading)
        t += 1
        #expect(tracker.evaluate(portKey: key, nonPowerLive: false, powerLive: true, now: t) == .live)
    }

    @Test("Charger-only unplug fades, then hides after the grace window")
    func chargerOnlyUnplugFadesThenHides() {
        let tracker = PortVisibilityTracker()
        let key = "Port-MagSafe 3@1"

        #expect(tracker.evaluate(portKey: key, nonPowerLive: false, powerLive: true, now: 0) == .live)
        // Power gone: should fade, not hide, immediately after.
        #expect(tracker.evaluate(portKey: key, nonPowerLive: false, powerLive: false, now: 0.5) == .fading)
        // Still inside the grace window.
        #expect(tracker.evaluate(portKey: key, nonPowerLive: false, powerLive: false, now: PortVisibilityTracker.graceWindow - 0.1) == .fading)
        // Past the grace window: hidden.
        #expect(tracker.evaluate(portKey: key, nonPowerLive: false, powerLive: false, now: PortVisibilityTracker.graceWindow + 0.1) == .hidden)
    }

    @Test("Real device unplug hides immediately, no fade")
    func dataDeviceUnplugHidesImmediately() {
        let tracker = PortVisibilityTracker()
        let key = "Port-USB-C@2"

        #expect(tracker.evaluate(portKey: key, nonPowerLive: true, powerLive: false, now: 0) == .live)
        // Device gone a moment later: hidden straight away, not faded.
        #expect(tracker.evaluate(portKey: key, nonPowerLive: false, powerLive: false, now: 0.2) == .hidden)
    }

    @Test("Signal returning during the fade restores live")
    func signalReturningDuringFadeRestoresLive() {
        let tracker = PortVisibilityTracker()
        let key = "Port-USB-C@3"

        #expect(tracker.evaluate(portKey: key, nonPowerLive: false, powerLive: true, now: 0) == .live)
        #expect(tracker.evaluate(portKey: key, nonPowerLive: false, powerLive: false, now: 1) == .fading)
        // Power comes back mid-fade.
        #expect(tracker.evaluate(portKey: key, nonPowerLive: false, powerLive: true, now: 1.5) == .live)
        // And a fresh loss now fades from THIS live moment, not the original one.
        #expect(tracker.evaluate(portKey: key, nonPowerLive: false, powerLive: false, now: 1.5 + PortVisibilityTracker.graceWindow - 0.1) == .fading)
    }

    @Test("Never-seen port key reads hidden")
    func neverSeenPortIsHidden() {
        let tracker = PortVisibilityTracker()
        #expect(tracker.evaluate(portKey: "Port-USB-C@9", nonPowerLive: false, powerLive: false, now: 0) == .hidden)
    }

    @Test("Grace window boundary: exactly graceWindow elapsed reads hidden, not fading")
    func graceWindowBoundaryIsExclusive() {
        let tracker = PortVisibilityTracker()
        let key = "Port-USB-C@4"

        #expect(tracker.evaluate(portKey: key, nonPowerLive: false, powerLive: true, now: 0) == .live)
        // A moment before the boundary: still fading.
        #expect(tracker.evaluate(portKey: key, nonPowerLive: false, powerLive: false, now: PortVisibilityTracker.graceWindow - 0.001) == .fading)
        // Exactly at the boundary: the grace window has elapsed, not "still within it".
        #expect(tracker.evaluate(portKey: key, nonPowerLive: false, powerLive: false, now: PortVisibilityTracker.graceWindow) == .hidden)
    }

    @Test("reconcile prunes a port key that dropped out of the evaluation set entirely")
    func reconcileDropsAbsentPortHistory() {
        let tracker = PortVisibilityTracker()
        let key = "Port-USB-C@5"

        #expect(tracker.evaluate(portKey: key, nonPowerLive: false, powerLive: true, now: 0) == .live)
        // The port's own service node disappears from the registry: a caller
        // reconciles against the (now smaller) set of keys it just evaluated,
        // which doesn't include this one.
        tracker.reconcile(keeping: [])
        // It reappears moments later, still well inside what would have been
        // the grace window off the old timestamp. Without the prune this
        // would read `.fading` off stale history; with it, it's a clean
        // `.hidden` because there's no live history for this key any more.
        #expect(tracker.evaluate(portKey: key, nonPowerLive: false, powerLive: false, now: 1) == .hidden)
    }

    // MARK: - portLivenessSplit truth table (WhatCableCore.PortLiveness.swift)

    private func splitFixturePort(isMagSafe: Bool, connectionActive: Bool) -> AppleHPMInterface {
        AppleHPMInterface(
            id: 1,
            serviceName: isMagSafe ? "Port-MagSafe 3@1" : "Port-USB-C@1",
            className: isMagSafe ? "AppleHPMInterfaceType11" : "AppleHPMInterfaceType10",
            portDescription: nil, portTypeDescription: isMagSafe ? "MagSafe 3" : "USB-C", portNumber: 1,
            connectionActive: connectionActive,
            activeCable: nil, opticalCable: nil, usbActive: nil, superSpeedActive: nil,
            usbModeType: nil, usbConnectString: nil,
            transportsSupported: [], transportsActive: [], transportsProvisioned: [],
            plugOrientation: nil, plugEventCount: nil, connectionCount: nil,
            overcurrentCount: nil, pinConfiguration: [:], powerCurrentLimits: [],
            firmwareVersion: nil, bootFlagsHex: nil, rawProperties: [:]
        )
    }

    private func splitFixtureDevice() -> USBDevice {
        USBDevice(
            id: 1, locationID: 0, vendorID: 0, productID: 0,
            vendorName: nil, productName: nil, serialNumber: nil,
            usbVersion: nil, speedRaw: nil, busPowerMA: nil, currentMA: nil,
            rawProperties: [:]
        )
    }

    private func splitFixtureIdentity() -> USBPDSOP {
        USBPDSOP(
            id: 1, endpoint: .sop,
            parentPortType: 0, parentPortNumber: 0,
            vendorID: 0, productID: 0, bcdDevice: 0,
            vdos: [], specRevision: 0
        )
    }

    private func splitFixturePowerSource() -> PowerSource {
        PowerSource(
            id: 1, name: "USB-PD", parentPortType: 2, parentPortNumber: 1,
            options: [],
            winning: PowerOption(voltageMV: 20_000, maxCurrentMA: 1490, maxPowerMW: 29_800)
        )
    }

    /// Exhaustive over every boolean input `portLivenessSplit` and
    /// `isPortLive` both take: `nonPower || power` must equal `isPortLive`'s
    /// own verdict on every one of the 2^7 = 128 combinations (hasDevice,
    /// hasIdentity, hasTunnelledDevice, isMagSafe, connectionActive,
    /// chargerAttached, hasPowerSource). This is the review's required
    /// truth table: it is what pins the split against
    /// silently drifting from `isPortLive` again the way the original,
    /// forced-empty-arguments version of the split did.
    @Test("nonPower || power always equals isPortLive, across every input combination")
    func splitAlwaysMatchesIsPortLive() {
        var checked = 0
        for hasDevice in [false, true] {
            for hasIdentity in [false, true] {
                for hasTunnelledDevice in [false, true] {
                    for isMagSafe in [false, true] {
                        for connectionActive in [false, true] {
                            for chargerAttached in [false, true] {
                                for hasPowerSource in [false, true] {
                                    let port = splitFixturePort(isMagSafe: isMagSafe, connectionActive: connectionActive)
                                    let devices = hasDevice ? [splitFixtureDevice()] : []
                                    let identities = hasIdentity ? [splitFixtureIdentity()] : []
                                    let powerSources = hasPowerSource ? [splitFixturePowerSource()] : []

                                    let expected = isPortLive(
                                        port: port, powerSources: powerSources, identities: identities,
                                        matchingDevices: devices, chargerAttached: chargerAttached,
                                        hasStructurallyScopedTunnelledDevices: hasTunnelledDevice
                                    )
                                    let split = portLivenessSplit(
                                        port: port, powerSources: powerSources, identities: identities,
                                        matchingDevices: devices, chargerAttached: chargerAttached,
                                        hasStructurallyScopedTunnelledDevices: hasTunnelledDevice
                                    )
                                    #expect(
                                        (split.nonPower || split.power) == expected,
                                        "hasDevice=\(hasDevice) hasIdentity=\(hasIdentity) hasTunnelledDevice=\(hasTunnelledDevice) isMagSafe=\(isMagSafe) connectionActive=\(connectionActive) chargerAttached=\(chargerAttached) hasPowerSource=\(hasPowerSource)"
                                    )
                                    checked += 1
                                }
                            }
                        }
                    }
                }
            }
        }
        // Floor: a broken loop nest (e.g. an accidentally-empty inner array)
        // would silently check nothing and still report green.
        #expect(checked == 128)
    }

    @Test("connectionActive-only port (no power, no device) unplugging hides immediately")
    func connectionActiveOnlyUnplugHidesImmediately() {
        // A USB2-only device or a power-role-less display: connectionActive
        // is true, nothing else is present. This is exactly the case the
        // review flagged as previously misclassified as "power".
        let port = splitFixturePort(isMagSafe: false, connectionActive: true)
        let split = portLivenessSplit(
            port: port, powerSources: [], identities: [], matchingDevices: [],
            chargerAttached: false, hasStructurallyScopedTunnelledDevices: false
        )
        #expect(split.nonPower == true)
        #expect(split.power == false)

        let tracker = PortVisibilityTracker()
        let key = "Port-USB-C@6"
        #expect(tracker.evaluate(portKey: key, nonPowerLive: split.nonPower, powerLive: split.power, now: 0) == .live)
        // Unplugged: connectionActive drops with it (no lingering, that's
        // the MagSafe-specific issue #47 case). Hides immediately, no fade.
        #expect(tracker.evaluate(portKey: key, nonPowerLive: false, powerLive: false, now: 0.2) == .hidden)
    }

    @Test("Lingering connectionActive after a device/PD signal drops still hides immediately")
    func lingeringConnectionActiveAfterDeviceLossStillHidesImmediately() {
        let port = splitFixturePort(isMagSafe: false, connectionActive: true)
        let tracker = PortVisibilityTracker()
        let key = "Port-USB-C@7"

        // A device is present: nonPower is true regardless of connectionActive.
        let withDevice = portLivenessSplit(
            port: port, powerSources: [], identities: [], matchingDevices: [splitFixtureDevice()],
            chargerAttached: false, hasStructurallyScopedTunnelledDevices: false
        )
        #expect(tracker.evaluate(portKey: key, nonPowerLive: withDevice.nonPower, powerLive: withDevice.power, now: 0) == .live)

        // The device watcher's own IOKit notification fires and the device is
        // gone, but `connectionActive` (a separate, slower-to-update flag on
        // the port controller) is still momentarily `true`. Because bare
        // `connectionActive` is itself a non-power signal, this still reads
        // as `nonPower == true`, so it stays `.live`, not `.hidden` yet:
        // that's correct, the port controller genuinely still reports a
        // connection. The immediate-hide guarantee is about the moment
        // BOTH signals are gone at once, checked next.
        let deviceGoneButStillActive = portLivenessSplit(
            port: port, powerSources: [], identities: [], matchingDevices: [],
            chargerAttached: false, hasStructurallyScopedTunnelledDevices: false
        )
        #expect(tracker.evaluate(portKey: key, nonPowerLive: deviceGoneButStillActive.nonPower, powerLive: deviceGoneButStillActive.power, now: 0.1) == .live)

        // A moment later `connectionActive` itself clears too: everything is
        // gone in the same evaluation. Hides immediately, not a fade, because
        // the last live evaluation (just above) had a non-power signal
        // (bare connectionActive), so `hadNonPowerSignal` was `true`.
        #expect(tracker.evaluate(portKey: key, nonPowerLive: false, powerLive: false, now: 0.2) == .hidden)
    }

    // MARK: - Sort stability (AppleHPMInterface.stableOrder)

    private func port(serviceName: String, connectionActive: Bool?) -> AppleHPMInterface {
        AppleHPMInterface(
            id: UInt64(abs(serviceName.hashValue)),
            serviceName: serviceName, className: "AppleHPMInterfaceType10",
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

    @Test("Sort order depends only on serviceName, not connectionActive")
    func sortOrderIgnoresConnectionActive() {
        let names = ["Port-USB-C@1", "Port-USB-C@2", "Port-MagSafe 3@1", "Port-USB-C@3"]
        let allInactive = names.map { port(serviceName: $0, connectionActive: false) }
            .sorted(by: AppleHPMInterface.stableOrder)
            .map(\.serviceName)

        // Flip which port is "active" across several runs. The sorted
        // serviceName order must never change: that's the whole point of
        // #536's fix (macOS flips `connectionActive` between two ports every
        // 1-2 seconds; the card order must not follow it).
        for activeIndex in names.indices {
            var ports = names.enumerated().map { index, name in
                port(serviceName: name, connectionActive: index == activeIndex)
            }
            ports.sort(by: AppleHPMInterface.stableOrder)
            #expect(ports.map(\.serviceName) == allInactive)
        }
    }
}
