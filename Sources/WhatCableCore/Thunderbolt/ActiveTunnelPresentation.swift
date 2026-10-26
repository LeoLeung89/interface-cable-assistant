import Foundation

// MARK: - Tunnel presentation (DAR: TB link tree root, Phase B)
//
// Turns `TunnelPath` + `IOThunderboltSwitch` data into localized, ready-to-
// render lines, shared by the CLI (`TextFormatter`) and the app's technical
// details view (`AdvancedPortDetails`) so both surfaces render identical
// text.
//
// Only CROSS-CABLE tunnels are surfaced: ones whose terminal switch sits at
// depth > 0 (downstream of the Mac's own controller, i.e. the tunnel
// actually crosses a cable to reach a device), whose kind resolved to
// something concrete (not `.unknown`), AND whose path UUID spans at least 2
// distinct switches. Host-internal single-segment paths (terminal = the
// host root itself, depth 0) never render: they don't cross a cable, so
// there's nothing a user plugging things in can act on. The distinct-switch
// check catches the same failure mode one level downstream: a path UUID
// that recurs only on a downstream device's OWN ports (never reaching the
// host root, or any other switch) is that device's internal routing, not
// a tunnel that crossed the cable to get there. Verified live on an M5 +
// Ugreen TB5 dock: the 3 real tunnels' path UUIDs each appear on BOTH the
// host root and the dock; every host-internal or dock-internal path UUID
// appears on exactly one switch. See `TunnelPath.distinctSwitchCount`'s doc
// comment for the corpus citation.
public enum ActiveTunnelPresentation {
    /// One line per surfaced tunnel, in the order `tunnels` is already
    /// sorted (video, usb, pcie; ties by `pathUUID`). Each line reads
    /// "<kind> → <device>" or "<kind> → <device> · adapter <N>" when the
    /// terminal adapter's port number is known.
    public static func lines(
        tunnels: [TunnelPath],
        switches: [IOThunderboltSwitch],
        bundle: Bundle
    ) -> [String] {
        crossCableTunnels(tunnels, switches: switches).compactMap { tunnel in
            // crossCableTunnels only keeps tunnels whose terminal switch was
            // resolved in `switches`, so this lookup cannot fail; guarded
            // anyway rather than force-unwrapping.
            guard let uid = tunnel.terminalSwitchUID,
                  let terminalSwitch = switches.first(where: { $0.id == uid })
            else { return nil }

            let kindLabel: String
            switch tunnel.kind {
            case .video: kindLabel = String(localized: "Video", bundle: bundle)
            case .usb: kindLabel = String(localized: "USB data", bundle: bundle)
            case .pcie: kindLabel = String(localized: "PCIe data", bundle: bundle)
            case .unknown: return nil // filtered out by crossCableTunnels
            }

            let deviceName = ThunderboltLabels.deviceName(for: terminalSwitch)
            var line = "\(kindLabel) \u{2192} \(deviceName)"
            if let adapterPort = tunnel.terminalAdapterPortNumber {
                let adapterPart = String(localized: "adapter \(adapterPort)", bundle: bundle)
                line += " \u{00B7} \(adapterPart)"
            }
            return line
        }
    }

    /// Tunnels eligible to be shown to the user: kind resolved to something
    /// concrete (not `.unknown`), the terminal switch is downstream of the
    /// host root (depth > 0), AND the path UUID spans at least 2 distinct
    /// switches (see `TunnelPath.distinctSwitchCount`). Exposed so
    /// `ConnectedDeviceTree`'s "video output N" display suffix agrees with
    /// `lines` on what counts as cross-cable, rather than re-deriving the
    /// rule.
    public static func crossCableTunnels(
        _ tunnels: [TunnelPath],
        switches: [IOThunderboltSwitch]
    ) -> [TunnelPath] {
        tunnels.filter { tunnel in
            guard tunnel.kind != .unknown, tunnel.distinctSwitchCount >= 2, let uid = tunnel.terminalSwitchUID else { return false }
            guard let terminalSwitch = switches.first(where: { $0.id == uid }) else { return false }
            return terminalSwitch.depth > 0
        }
    }
}
