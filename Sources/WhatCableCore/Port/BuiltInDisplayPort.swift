import Foundation

/// A native video output socket on an Apple Silicon Mac (today: the HDMI 2.1
/// port on the MacBook Pro 14"/16", Mac mini Pro, and Mac Studio). These
/// sockets aren't wired to the USB-C port-controller silicon, so they have no
/// `AppleHPMInterface` and never show up in the per-port iteration that drives
/// the popover, CLI text, JSON and widget. This type fills that gap with a
/// slim entity carrying only the things a native video port actually has: its
/// port type ("HDMI"), its port number, and the live display(s) attached. No
/// e-marker, no PD, no transports, no Thunderbolt fabric.
///
/// Issue #352: a user reported that WhatCable was labelling their HDMI 2.1
/// display on the native HDMI port as "going through a USB-C to HDMI adapter"
/// and "rate limited". The verdict was wrong for two reasons: there is no
/// adapter on this path (the SoC drives HDMI directly), and the DSC carve-out
/// that handles HBR3 + max-lanes was being skipped because `dfpType` reported
/// HDMI and the diagnostic assumed an adapter was in the chain. The fix lives
/// in `DisplayDiagnostic` (gate the adapter heuristic on
/// `parentPortTypeDescription`); this type lets the same display also appear
/// in the popover, CLI, and JSON, not just the Pro Display Diagnostics screen.
public struct BuiltInDisplayPort: Identifiable, Equatable, Sendable {
    /// Stable per-port identifier for SwiftUI iteration. Built from the port
    /// type + number so two ports on the same machine don't collide and so
    /// the same socket keeps the same id across snapshot updates.
    public var id: String { serviceName }

    /// "HDMI" today. Kept as a string rather than an enum so future native
    /// video ports (if any) can flow through without a model migration.
    public let portType: String

    /// 1-based socket index on the host. Matches Apple's own labelling
    /// ("HDMI port 1"). Comes from `ParentPortNumber` on the DisplayPort
    /// transport node.
    public let portNumber: Int

    /// Synthesized name, mirroring the `Port-USB-C@N` / `Port-MagSafe 3@N`
    /// convention used by `AppleHPMInterface.serviceName`. The user-facing
    /// labelling ("HDMI port 1") is rendered separately by the formatters
    /// from `portType` + `portNumber`.
    public var serviceName: String { "Port-\(portType)@\(portNumber)" }

    /// The DisplayPort transport node(s) for this socket. One per attached
    /// display. Empty is impossible by construction (the type only exists
    /// when at least one DP node is present on the socket); we keep the
    /// array shape so a future "two displays through one HDMI port via MST"
    /// case has somewhere to go.
    public let displays: [IOPortTransportStateDisplayPort]

    public init(portType: String, portNumber: Int, displays: [IOPortTransportStateDisplayPort]) {
        self.portType = portType
        self.portNumber = portNumber
        self.displays = displays
    }
}

extension BuiltInDisplayPort {
    /// Group a flat list of DisplayPort transport nodes into one entry per
    /// physical native video port.
    ///
    /// A DP node belongs to a native video port when its parent port type is
    /// something other than USB-C (USB-C ports already have their own
    /// `AppleHPMInterface` card, so a DP node sitting under a USB-C port is
    /// already represented and must not be duplicated here) AND its
    /// DisplayPort link isn't tunnelled (DP-over-Thunderbolt always sits
    /// downstream of a USB-C port; not a native socket).
    ///
    /// Critically: we don't gate on `parentPortBuiltIn`. IOKit's
    /// `ParentPortBuiltIn` property is emitted as a real bool for USB-C
    /// transport-component nodes (probe 01) but is absent on every
    /// `IOPortTransportStateDisplayPort` node attached to a native HDMI
    /// port (0 of 79 across the customer-probe corpus). Reading absent
    /// as false would silently exclude every real HDMI port. So we use
    /// the parent-port-type description, which corpus probe 33 confirms
    /// is "HDMI" for the M-series MacBook Pro / Mac mini Pro / Mac Studio
    /// native HDMI socket across every chip family from M1 Pro through
    /// M5 Pro.
    public static func group(from displays: [IOPortTransportStateDisplayPort]) -> [BuiltInDisplayPort] {
        var byKey: [String: [IOPortTransportStateDisplayPort]] = [:]
        var keyOrder: [String] = []
        for dp in displays {
            // The IOKit `IOPortTransportStateDisplayPort` node exists even
            // when nothing's plugged in (corpus shows idle HDMI ports with
            // `Active = false`). The popover/CLI/JSON contract is "appears
            // only when a display is attached", so filter inactive nodes
            // here so the resulting port entity never carries a non-display.
            guard dp.link.active else { continue }
            guard !dp.link.tunneled else { continue }
            guard let type = dp.parentPortTypeDescription, type.uppercased() != "USB-C" else { continue }
            let key = "\(type)#\(dp.parentPortNumber)"
            if byKey[key] == nil { keyOrder.append(key) }
            byKey[key, default: []].append(dp)
        }
        return keyOrder.compactMap { key in
            guard let group = byKey[key], let first = group.first else { return nil }
            return BuiltInDisplayPort(
                portType: first.parentPortTypeDescription ?? "",
                portNumber: first.parentPortNumber,
                displays: group
            )
        }
    }
}
