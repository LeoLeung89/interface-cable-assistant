import Foundation

// MARK: - Tunnel grouping (DAR: TB link tree root, Phase A)
//
// A Thunderbolt link multiplexes several tunnels (DisplayPort video, USB3,
// PCIe) over the same physical lane. Each adapter's `Hop Table` carries one
// row per tunnel it forwards; the row's `pathUUID` recurs on every adapter
// that tunnel crosses, across switches, so grouping `HopTableEntry` rows by
// that UUID reconstructs each tunnel's route through the fabric.
//
// Design note: kind classification deliberately does NOT restrict itself to
// "the host root's own protocol adapter", even though that is the more
// literal reading of the original brief. Corpus evidence
// (research/dumps/tb-fabric/052-joeshaw-m2pro-asus-caldigit-daisychain.md)
// shows a crossing tunnel's Path UUID lands on the host root's LANE adapter
// and the downstream device's PROTOCOL adapter (e.g. the dock's DP-in
// port), never on a protocol adapter AT the host root itself. The host
// root's own protocol adapters (PCIe/USB/DP) there carry a wholly disjoint
// UUID set that never reaches the lane at all (single-segment, terminal =
// host root). Restricting kind lookup to "host root protocol adapter only"
// would classify every real cross-cable tunnel as `.unknown`, which
// defeats the point. Kind is derived from ANY non-lane adapter in the
// group instead (the Up/Down adapter-type pairs both map to the same
// `Kind`, so it does not matter which end of the tunnel supplies it),
// preferring the shallowest depth for determinism when more than one
// non-lane member exists.

/// One reconstructed Thunderbolt tunnel: every `HopTableEntry` across the
/// scoped fabric that shares a `pathUUID`, resolved to where it starts and
/// where it terminates.
public struct TunnelPath: Hashable {
    /// The tunnel's join key (see `HopTableEntry.pathUUID`).
    public let pathUUID: String
    /// DisplayPort video, USB3, or PCIe, inferred from any non-lane
    /// adapter carrying this UUID. `.unknown` when no non-lane adapter
    /// in the scoped fabric carries it (lane-only rows, e.g. reserved
    /// bandwidth that never resolved to a protocol adapter).
    public let kind: Kind
    /// Port number of the shallowest-depth adapter carrying this UUID.
    /// Usually the host root's lane port: where the tunnel enters the
    /// fabric. `nil` only if the group is somehow empty (should not
    /// happen; grouping only produces non-empty groups).
    public let originAdapterPortNumber: Int?
    /// UID of the deepest switch carrying this UUID: where the tunnel
    /// terminates. Internal join key only, never user-facing (matches
    /// the "never serialise `IOThunderboltSwitch.id`" rule).
    public let terminalSwitchUID: Int64?
    /// Port number of the terminal switch's non-lane adapter carrying
    /// this UUID. `nil` if only a lane adapter carries it at that depth.
    public let terminalAdapterPortNumber: Int?
    /// Adapter type of the terminal switch's non-lane adapter. `nil`
    /// under the same condition as `terminalAdapterPortNumber`.
    public let terminalAdapterType: AdapterType?
    /// Number of (switch, port, hop entry) triples sharing this UUID.
    /// `1` for a tunnel that never leaves its origin switch.
    public let segmentCount: Int
    /// Number of DISTINCT switches (by UID) this UUID's members span.
    /// A real cross-cable tunnel's path UUID is stamped on the adapters
    /// at both ends of the physical link, so it always spans >= 2
    /// switches; a UUID that only ever recurs on ONE switch's own ports
    /// (however many hop-table rows on that switch repeat it) never
    /// actually crosses a cable. See `ActiveTunnelPresentation
    /// .crossCableTunnels`, which gates on this alongside depth and kind.
    /// Verified live on an M5 + Ugreen TB5 dock: the 3 real tunnels' path
    /// UUIDs each appear on BOTH the host root and the dock; every
    /// host-internal or dock-internal path UUID appears on exactly one
    /// switch. `research/dumps/tb-fabric/052-joeshaw-m2pro-asus-caldigit
    /// -daisychain.md` around line 711 has PCIe path UUID
    /// 93B7660C-35ED-4194-8BA4-A48A9A9A1EDE occurring ONCE, only on the
    /// depth-1 ASUS switch's own PCIe adapter: a dock-internal path that
    /// without this field wrongly renders as a cross-cable tunnel.
    public let distinctSwitchCount: Int

    public enum Kind: Hashable {
        case video
        case usb
        case pcie
        case unknown

        /// Deterministic sort rank: video, usb, pcie, unknown.
        var sortRank: Int {
            switch self {
            case .video: return 0
            case .usb: return 1
            case .pcie: return 2
            case .unknown: return 3
            }
        }
    }

    public init(
        pathUUID: String,
        kind: Kind,
        originAdapterPortNumber: Int?,
        terminalSwitchUID: Int64?,
        terminalAdapterPortNumber: Int?,
        terminalAdapterType: AdapterType?,
        segmentCount: Int,
        distinctSwitchCount: Int
    ) {
        self.pathUUID = pathUUID
        self.kind = kind
        self.originAdapterPortNumber = originAdapterPortNumber
        self.terminalSwitchUID = terminalSwitchUID
        self.terminalAdapterPortNumber = terminalAdapterPortNumber
        self.terminalAdapterType = terminalAdapterType
        self.segmentCount = segmentCount
        self.distinctSwitchCount = distinctSwitchCount
    }
}

/// One (switch, port, hop entry) triple: a single row of a tunnel's route
/// through the fabric. File-scoped: only `ThunderboltTopology.tunnels`
/// needs it.
private struct HopTriple {
    let sw: IOThunderboltSwitch
    let port: IOThunderboltPort
    let entry: HopTableEntry
}

/// Depth-then-port ordering, used to pick a deterministic "shallowest"
/// member out of a group of triples that share a path UUID.
private func isShallower(_ lhs: HopTriple, _ rhs: HopTriple) -> Bool {
    (lhs.sw.depth, lhs.port.portNumber) < (rhs.sw.depth, rhs.port.portNumber)
}

/// Switch-UID-then-port ordering, used to pick a deterministic terminal
/// member out of a group of triples tied on max depth. `members.first`
/// on an unsorted array is a silent insertion-order dependency (the order
/// `scoped` switches were walked in `tunnels(from:in:)`); sorting first
/// makes the pick stable regardless of the input switches array's order.
private func isTerminalOrderedBefore(_ lhs: HopTriple, _ rhs: HopTriple) -> Bool {
    if lhs.sw.id != rhs.sw.id { return lhs.sw.id < rhs.sw.id }
    return lhs.port.portNumber < rhs.port.portNumber
}

/// Adapter-type to tunnel-kind mapping. Up/Down variants of the same
/// protocol both map to one `Kind`; direction is a fabric-routing detail,
/// not part of what the tunnel carries.
private func tunnelKind(for member: HopTriple) -> TunnelPath.Kind {
    switch member.port.adapterType {
    case .dpIn, .dpOut: return .video
    // .usbGenTDown / .usbGenTUp are the TB5-era USB tunneling adapter
    // (0x210101 / 0x210102), a distinct encoding from the USB3 pair
    // above but the same tunnel kind: both carry USB data over the
    // fabric.
    case .usb3Down, .usb3Up, .usbGenTDown, .usbGenTUp: return .usb
    case .pcieDown, .pcieUp: return .pcie
    default: return .unknown
    }
}

extension ThunderboltTopology {
    /// Reconstruct every Thunderbolt tunnel active on `hostRoot`'s fabric,
    /// by grouping `HopTableEntry.pathUUID` across `hostRoot` and every
    /// switch downstream of it (walking `parentSwitchUID`; same scope as
    /// `tree(from:in:)`).
    ///
    /// Order is deterministic: video, usb, pcie, unknown, ties broken by
    /// `pathUUID`.
    public static func tunnels(
        from hostRoot: IOThunderboltSwitch,
        in switches: [IOThunderboltSwitch]
    ) -> [TunnelPath] {
        let downstream = flatten(tree(from: hostRoot, in: switches)).map(\.sw)
        let scoped = [hostRoot] + downstream

        var triples: [HopTriple] = []
        for sw in scoped {
            for port in sw.ports {
                for entry in port.hopTable {
                    triples.append(HopTriple(sw: sw, port: port, entry: entry))
                }
            }
        }

        var groups: [String: [HopTriple]] = [:]
        for triple in triples {
            groups[triple.entry.pathUUID, default: []].append(triple)
        }

        let paths: [TunnelPath] = groups.map { pathUUID, members in
            let originMember = members.min(by: isShallower)

            // Restricted to members `tunnelKind(for:)` can actually
            // classify, not just "any non-lane adapter". `.isLane` alone
            // also admits `.nhi` (host-interface, depth-0 only), `.inactive`,
            // and `.other`; since `kindSource` picks the SHALLOWEST member,
            // an NHI row sharing this UUID with a real downstream DP/USB/PCIe
            // adapter would deterministically win the pick (depth 0 beats
            // any downstream depth) and force the tunnel to `.unknown`,
            // suppressing a real cross-cable tunnel. Composes with the
            // USB Gen T adapter types above: those now classify too.
            let classifiableMembers = members.filter { tunnelKind(for: $0) != .unknown }
            let kindSource = classifiableMembers.min(by: isShallower)
            let kind = kindSource.map(tunnelKind(for:)) ?? .unknown

            let maxDepth = members.map(\.sw.depth).max() ?? 0
            // Sorted (not just filtered) so the terminal pick is stable
            // regardless of the input switches array's order: see
            // `isTerminalOrderedBefore`.
            let terminalMembers = members.filter { $0.sw.depth == maxDepth }.sorted(by: isTerminalOrderedBefore)
            let terminalSwitchUID = terminalMembers.first?.sw.id
            let terminalNonLane = terminalMembers.first { tunnelKind(for: $0) != .unknown }

            let distinctSwitchCount = Set(members.map(\.sw.id)).count

            return TunnelPath(
                pathUUID: pathUUID,
                kind: kind,
                originAdapterPortNumber: originMember?.port.portNumber,
                terminalSwitchUID: terminalSwitchUID,
                terminalAdapterPortNumber: terminalNonLane?.port.portNumber,
                terminalAdapterType: terminalNonLane?.port.adapterType,
                segmentCount: members.count,
                distinctSwitchCount: distinctSwitchCount
            )
        }

        return paths.sorted { lhs, rhs in
            if lhs.kind.sortRank != rhs.kind.sortRank {
                return lhs.kind.sortRank < rhs.kind.sortRank
            }
            return lhs.pathUUID < rhs.pathUUID
        }
    }
}
