import Foundation

/// Decide whether a port is physically live based on the union of IOKit
/// watcher state (devices, power sources, PD identities) and the port-level
/// `ConnectionActive` flag.
///
/// Why this helper exists:
///
/// - `AppleHPMInterface.connectionActive` lingers `true` for several seconds after
///   unplug on MagSafe (`AppleHPMInterfaceType11`), so we can't trust it
///   alone there.
/// - The power source watcher caches the last negotiated PDO, so a port
///   with nothing plugged in can still expose a USB-PD source long after
///   the cable was removed (issue #47).
///
/// So we treat each signal differently. Devices and PD identities are
/// strong: their watchers terminate on real IOKit notifications, no
/// caching. The port-level `connectionActive` flag is trusted on
/// non-MagSafe. Power sources need corroboration before they count.
///
/// MagSafe is the awkward one. Normally a connected MagSafe charger exposes a
/// per-port power source (the negotiated PDO), which corroborates liveness.
/// But in rare cases macOS produces no per-port power source for a genuinely
/// connected MagSafe charger (one machine in the whole probe corpus),
/// and then the port has nothing to corroborate and reads as "nothing
/// connected". MagSafe's `connectionActive` does report the connection, but it
/// also lingers `true` for seconds after unplug (issue #47), so it can't be
/// trusted on its own. The tie-breaker is `chargerAttached`: whether the Mac
/// actually has an external adapter attached right now. That clears immediately
/// on unplug, so it rules out the lingering case while still surfacing a
/// genuinely connected MagSafe charger even when no per-port source appears.
///
/// - Parameter chargerAttached: whether an external charger is attached to the
///   Mac. Used only to corroborate a MagSafe `connectionActive`. Defaults to
///   `false` so callers that can't supply it keep the prior behaviour.
/// - Parameter hasStructurallyScopedTunnelledDevices: whether a tunnelled USB
///   device has been structurally joined to THIS port (`TunnelledDeviceGrouping
///   .structurallyScopedTunnelledDevices`), i.e. reached the Mac over a
///   Thunderbolt tunnel whose root names this exact port. Such devices never
///   appear in `matchingDevices` (that is the native, non-tunnel join;
///   `AppleHPMInterface.matchingDevices` explicitly excludes anything
///   `isThunderboltTunnelled`), so without this a port whose ONLY connected
///   devices are behind a dock or display reads as empty and "Hide empty
///   ports" removes it, along with every device nested under it: a port
///   carrying attributed devices is not empty. Defaults to `false` so callers
///   that can't supply it (or genuinely have no such devices) keep the prior
///   behaviour.
public func isPortLive(
    port: AppleHPMInterface,
    powerSources: [PowerSource],
    identities: [USBPDSOP],
    matchingDevices: [USBDevice],
    chargerAttached: Bool = false,
    hasStructurallyScopedTunnelledDevices: Bool = false
) -> Bool {
    if !matchingDevices.isEmpty { return true }
    if hasStructurallyScopedTunnelledDevices { return true }
    if !identities.isEmpty { return true }

    let isMagSafe = port.portTypeDescription?.hasPrefix("MagSafe") == true
    if !isMagSafe && port.connectionActive == true { return true }

    // MagSafe reporting connected, corroborated by a charger actually attached.
    // This is what surfaces an M1/M2 MagSafe charger (no per-port power source
    // on that silicon). Gated on `connectionActive == true`, so the issue
    // #47 / #185 stale cases (a cached PDO on a disconnected port, where
    // `connectionActive` is false) are untouched. `chargerAttached` handles the
    // post-unplug lingering-true flag: once the only charger is gone the
    // adapter clears and this stops firing. (If a *second* charger is on
    // another port during the unplug, the port can read live until
    // `connectionActive` drains a few seconds later. Bounded, and no worse than
    // before, where an M1/M2 MagSafe charger never showed at all.)
    if isMagSafe && port.connectionActive == true && chargerAttached { return true }

    // Power sources alone aren't enough: the watcher's cached PDO can
    // outlive the physical connection. Only count them when the port
    // itself agrees something is connected.
    if !powerSources.isEmpty && port.connectionActive == true { return true }

    return false
}

/// Splits `isPortLive`'s branches into the two halves `PortVisibilityTracker`
/// (#536) needs to tell a real disconnect from a power-attribution flap:
/// `nonPower` (device, PD identity, structurally-scoped tunnel, or bare
/// non-MagSafe `connectionActive`) and `power` (an actual power source
/// corroborated by `connectionActive`, on either MagSafe or USB-C).
///
/// `nonPower || power` always equals `isPortLive`'s own verdict for the same
/// inputs; `PortLivenessSplitTests` pins that with an exhaustive truth table.
/// Kept as a second function rather than having `isPortLive` call this one
/// and OR the results, so `isPortLive`'s existing branch order and early
/// returns (documented above) are untouched for its other callers.
///
/// Bare non-MagSafe `connectionActive` is deliberately on the `nonPower`
/// side: it means "the port itself reports something plugged in" (a USB2
/// -only device, a display with no power role), which has nothing to do with
/// a power source being attributed here. Putting it on the power side (an
/// earlier version of this split did, by calling `isPortLive` with
/// `matchingDevices`/`identities` forced empty) misread a real device
/// disconnect as a power-only change and gave it an undeserved fade.
public func portLivenessSplit(
    port: AppleHPMInterface,
    powerSources: [PowerSource],
    identities: [USBPDSOP],
    matchingDevices: [USBDevice],
    chargerAttached: Bool = false,
    hasStructurallyScopedTunnelledDevices: Bool = false
) -> (nonPower: Bool, power: Bool) {
    let isMagSafe = port.portTypeDescription?.hasPrefix("MagSafe") == true
    let bareConnectionActive = !isMagSafe && port.connectionActive == true

    let nonPower = !matchingDevices.isEmpty
        || hasStructurallyScopedTunnelledDevices
        || !identities.isEmpty
        || bareConnectionActive

    let magSafeChargerAttached = isMagSafe && port.connectionActive == true && chargerAttached
    let powerSourceCorroborated = !powerSources.isEmpty && port.connectionActive == true
    let power = magSafeChargerAttached || powerSourceCorroborated

    return (nonPower, power)
}
