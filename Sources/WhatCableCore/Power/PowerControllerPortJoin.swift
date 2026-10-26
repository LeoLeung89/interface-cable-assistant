import Foundation

/// Joins the unlabelled `PortControllerInfo` array (which lives inside
/// `AppleSmartBattery` and carries no per-item port number) onto self-keyed
/// power-source ports by content.
///
/// `PortControllerInfo` items hold rich per-port PD detail but no port id, so
/// the old code keyed them by array offset. That order is not stable (it
/// shuffles on plug/unplug and differs across Macs), which landed a charger's
/// watts on the wrong port. The reliable link is the watts: an item's
/// `PortControllerMaxPower` is matched to a `PowerSource`'s winning contract
/// watts, and the source (`IOPortFeaturePowerSource`) states the port outright.
///
/// This is **enrichment only**. The contract itself (port, watts, volts, amps)
/// is read from the self-keyed source; this helper only says which array item
/// belongs to the port the source already owns, so that item's decoded detail
/// can be attached. It never assigns a port or a wattage.
public enum PowerControllerPortJoin {
    /// Default watts tolerance. ~1.5 W absorbs rounding (e.g. 44850 vs 44800).
    public static let defaultToleranceMW = 1500

    /// Map each `PortControllerInfo` array index to the port key of the single
    /// power source whose winning watts it matches (within `toleranceMW`).
    ///
    /// An item that matches zero, or more than one *distinct* source port, is
    /// omitted (fail-safe: never emit a guessed key). The result depends only
    /// on watts, never on array position, so it is order-independent.
    ///
    /// One port advertising two sources at the same wattage (e.g. USB-PD +
    /// Brick ID) is still one distinct port, so it maps cleanly. Two *different*
    /// ports at the exact same wattage are ambiguous, so the item is omitted.
    public static func portKeysByContent(
        controllerMaxPowerMW: [Int],
        sources: [PowerSource],
        toleranceMW: Int = defaultToleranceMW
    ) -> [Int: String] {
        let keyedWatts: [(portKey: String, watts: Int)] = sources.compactMap { src in
            guard let watts = src.winning?.maxPowerMW, watts > 0 else { return nil }
            return (src.portKey, watts)
        }

        var result: [Int: String] = [:]
        for (index, maxPowerMW) in controllerMaxPowerMW.enumerated() where maxPowerMW > 0 {
            let matchedPorts = Set(
                keyedWatts
                    .filter { abs($0.watts - maxPowerMW) <= toleranceMW }
                    .map(\.portKey)
            )
            if matchedPorts.count == 1, let key = matchedPorts.first {
                result[index] = key
            }
        }
        return result
    }
}
