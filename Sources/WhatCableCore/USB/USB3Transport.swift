import Foundation

/// USB 3 SuperSpeed link state for one port, sourced from the
/// `IOPortTransportStateUSB3` IOKit service. These services appear
/// dynamically when a USB 3 device is connected and disappear on unplug.
///
/// The main value here is knowing the negotiated generation: Gen 1
/// (5 Gbps) vs Gen 2 (10 Gbps). Without this data the app can still
/// detect "USB3 is active" from `transportsActive`, but can only say
/// "5 Gbps or faster" instead of the precise speed.
public struct USB3Transport: Identifiable, Hashable, Sendable {
    public let id: UInt64
    /// Port correlation key matching `PowerSource.portKey`.
    /// Format: `"\(parentPortType)/\(parentPortNumber)"`.
    public let portKey: String
    /// SuperSpeed signaling generation: 1 = Gen 1 (5 Gbps), 2 = Gen 2 (10 Gbps).
    /// Nil if the IOKit property was absent or unreadable.
    public let signaling: Int?
    /// Human-readable description from IOKit, e.g. "Gen 1" or "Gen 2".
    public let signalingDescription: String?
    /// Data role as reported by the transport: "host", "device", etc.
    public let dataRole: String?
    /// HPM controller UUID captured by walking the IOKit parent chain.
    /// Internal join key only. Never serialised to JSON or text output.
    public let hpmControllerUUID: String?
    /// Whether the transport is currently active (from the `Active` IOKit property).
    /// Nil when the property is absent. Carried as data; DataLinkDiagnostic uses
    /// `transportRestricted` as the primary gate for the blocked-by-security verdict.
    public let active: Bool?
    /// Whether macOS TRM (Trust and Restrict Management) has blocked data on this
    /// transport (from the `TRM_TransportRestricted` IOKit property). When true,
    /// the transport's signaled speed is present but macOS is not passing data until
    /// the user approves the accessory.
    public let transportRestricted: Bool?
    /// True when this transport is tunnelled through Thunderbolt rather than
    /// being the physical port's own (IOKit `Tunneled`).
    ///
    /// `portKey` is `"\(parentPortType)/\(parentPortNumber)"`, and a dock's
    /// tunnelled `Port-USB-C@N/CIO/USB3@0` node carries the SAME parent port
    /// number as the port's own transports, so without this flag a dock's
    /// internal plumbing can be selected as the port's USB3 link.
    public let tunnelled: Bool?

    public init(
        id: UInt64,
        portKey: String,
        signaling: Int?,
        signalingDescription: String?,
        dataRole: String?,
        hpmControllerUUID: String? = nil,
        active: Bool? = nil,
        transportRestricted: Bool? = nil,
        tunnelled: Bool? = nil
    ) {
        self.id = id
        self.portKey = portKey
        self.signaling = signaling
        self.signalingDescription = signalingDescription
        self.dataRole = dataRole
        self.hpmControllerUUID = hpmControllerUUID
        self.active = active
        self.transportRestricted = transportRestricted
        self.tunnelled = tunnelled
    }

    /// Canonical in-session join key: normalised UUID when captured, else portKey.
    /// Internal only; never expose in JSON or text output.
    public var canonicalJoinKey: String {
        if let uuid = hpmControllerUUID {
            let n = uuid.replacingOccurrences(of: "-", with: "").lowercased()
            if n.count == 32 { return n }
        }
        return portKey
    }

    /// True when this transport belongs to the same physical port as `port`.
    /// UUID-keyed when both sides have a UUID, portKey fallback otherwise.
    public func canonicallyMatches(port: AppleHPMInterface) -> Bool {
        guard let portKey = port.portKey else { return false }
        if let srcUUID = hpmControllerUUID, let portUUID = port.hpmControllerUUID {
            let sn = srcUUID.replacingOccurrences(of: "-", with: "").lowercased()
            let pn = portUUID.replacingOccurrences(of: "-", with: "").lowercased()
            if sn.count == 32 && pn.count == 32 { return sn == pn }
        }
        return self.portKey == portKey
    }

    /// User-facing label for the negotiated USB 3 speed.
    /// Returns nil when generation data is unavailable (caller should
    /// fall back to the generic "SuperSpeed USB" text).
    ///
    /// `signaling == 0` is IOKit's "None" sentinel and means "no live USB 3
    /// signaling on this transport." Empirically common on CIO-tunneled
    /// USB3 (signal lives on the Thunderbolt link, not as raw USB3) and on
    /// idle USB-C ports that expose a transport service but have not
    /// negotiated a SuperSpeed link. Treating 0 as a real generation
    /// produced "USB 3.2 Gen 0" in the popover for those cases (whatcable
    /// issue #190 follow-up). Other unknown values still produce a generic
    /// "Gen N" label so a hypothetical future encoding (e.g. Gen 2x2) is
    /// not silently hidden.
    public var speedLabel: String? {
        guard let gen = signaling else { return nil }
        switch gen {
        case 0: return nil
        case 1: return "USB 3.2 Gen 1 (5 Gbps)"
        case 2: return "USB 3.2 Gen 2 (10 Gbps)"
        default: return "USB 3.2 Gen \(gen)"
        }
    }
}
