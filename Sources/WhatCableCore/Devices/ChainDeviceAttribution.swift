import Foundation

/// Works out which Thunderbolt chain device each USB device sits inside.
///
/// The problem it solves: on a daisy chain (Mac -> display -> dock) macOS
/// publishes the USB devices as one flat forest per host controller with no
/// record of which downstream Thunderbolt device each one is physically plugged
/// into. The Thunderbolt fabric knows the chain exactly, and the USB tree knows
/// the hub cascade exactly, but nothing joins the two. Without a join, a dock's
/// Ethernet adapter renders five hub levels deep under the display the dock is
/// chained behind, which is where "12 rows, and you cannot tell what is plugged
/// into what" comes from.
///
/// No published technique exists for this on macOS. Apple's own USB report
/// (`system_profiler SPUSBHostDataType`) shows each USB controller's hub tree
/// but never which Thunderbolt box a hub is inside, so there is no ground truth
/// to copy. What follows is inference, and every step of it is
/// built to fail closed: **when the evidence does not single out one chain
/// device, the device stays unattributed and renders exactly where it does
/// today.** A wrong parent is worse than a flat list.
///
/// Evidence only. A device is grouped under a box when one of these places it,
/// and never otherwise:
///
/// 1. **Thunderbolt position.** The TB5 tunnel-hub map (route rule), the
///    USB-tunnel depth join and the PCIe Stage A and B joins.
/// 2. **USB2 pairing.** Each box's top USB2 hub, by position and a Container
///    ID only that box's structurally placed USB3 side carries.
/// 3. **The box's own identity device.** A USB device whose name equals the
///    box's model name exactly, or whose idVendor/idProduct equal the box's
///    DROM vendor/model numbers (the numbers win when the two disagree).
///
/// Identity evidence places only the identity device itself (`identityMark`
/// in `resolve`). It never passes the box on to a parent hub, and an identity
/// device that is itself a hub is not marked unless position evidence already
/// places that hub in the same box. Hubs, and everything under them, are
/// grouped by position evidence alone. A device whose own position and own
/// identity disagree is placed by neither and renders at port level.
///
/// Below a marked node, devices inherit its box down the forest, stopping at
/// the next mark. Anything nothing places stays unattributed and
/// `ConnectedDeviceTree` draws it in the port's separate "other devices"
/// section. Partial name matches and vendor IDs group nothing: in the corpus
/// they were behind most wrong groupings.
///
/// Pure logic, no IOKit. `ConnectedDeviceTree` is the only caller.
public struct ChainDeviceAttribution: Equatable {
    /// USB device id -> chain switch id: every device the evidence places,
    /// hubs included. Both view modes read this, so they cannot disagree
    /// about which chain device something is inside.
    public let regionOwner: [UInt64: Int64]

    /// The marked nodes: USB device id -> the chain switch id whose region
    /// starts there. The expanded view renders one nested subtree per entry.
    public let regionRoots: [UInt64: Int64]

    /// Devices that ARE a chain device (their own USB identity endpoint).
    /// Rendering both them and the chain row would duplicate the device, which
    /// is a good part of why the tree reads as a tangle today.
    public let absorbed: Set<UInt64>

    /// True when every chain device holds at least one region. Reported for
    /// the corpus sweep; it gates nothing.
    public let allAnchored: Bool

    /// Stage B v2 (PCI Path prefix join): USB device ids the join resolved to
    /// `forcedPortLevel` (valid-but-no-match, a tie between switches, a stale
    /// `pciEntryID`, or a contradiction with exact-name/numeric evidence). A
    /// TERMINAL, explicit port-level boundary root (plan step 8/9): excluded
    /// from every chain-attribution mechanism (never a `regionOwner`, never a
    /// `regionRoots` target, never `absorbed`), and it blocks every kind of
    /// evidence from crossing it, in both directions: inheritance stops here,
    /// vendor continuity cannot traverse it or create marks below it,
    /// redundant-root removal cannot let a mark above it cover a root below
    /// it, and nobody else's claim may redirect onto it as a hub. Only a
    /// self-anchoring claim (exact/affiliate on its own subtree, or an
    /// independent structural match) can restart ownership below one.
    /// `ConnectedDeviceTree` reads this to render the boundary explicitly in
    /// both view modes, rather than relying on the unowned-forest-root pass
    /// (which only looks at forest roots and would silently drop a
    /// mid-tree boundary).
    public let portLevelBoundaries: Set<UInt64>

    public static let none = ChainDeviceAttribution(
        regionOwner: [:], regionRoots: [:], absorbed: [], allAnchored: false, portLevelBoundaries: []
    )

    /// Nothing was attributed and nothing absorbed, so the caller can render
    /// its existing layout unchanged.
    public var isEmpty: Bool { regionOwner.isEmpty && absorbed.isEmpty }

    // MARK: - Stage B v2: PCI Path prefix join

    /// Per-device outcome of the PCI-Path-prefix join for one PCIe-carried
    /// (`carrier == .pcieTunnel`) device against one port's downstream chain.
    /// Plan: the private design note "PCIe-tunnelled USB attribution", "Stage B v2:
    /// PCI Path prefix join", resolution steps 1-7.
    enum PCIeStageBOutcome: Equatable {
        /// Some input needed for the join was missing or unusable (a
        /// downstream switch with no usable up-adapter candidate, the
        /// controller's own path/entry-ID list missing): the join does not
        /// run at all for this device, and the caller falls back to the
        /// Stage A single-switch shortcut. NOT the same as "ran and found
        /// nothing" (`.portLevel`): a missing input must never let a
        /// shallower switch win by default (completeness gate, step 2).
        case fallbackToStageA
        /// Exactly one switch's PCIe up-adapter is both entry-ID-verified
        /// (the switch's `pciEntryID` is a member of the controller's
        /// ancestor entry IDs) and the deepest matching path prefix.
        case matched(Int64)
        /// The join ran with complete, usable inputs but found no valid
        /// match (contradictory evidence: a path/entry-ID pair that once
        /// matched a switch since replaced, a tie between two DIFFERENT
        /// switches at the same depth), or found nothing at all. This is a
        /// STRUCTURAL finding, not an absence of evidence, so the caller
        /// must NOT fall back to the shortcut (step 4/12): it is stronger,
        /// terminal evidence that the device is not inside any switch on
        /// this port's chain.
        case portLevel
    }

    /// Resolves one PCIe-carried device against one port's downstream chain,
    /// implementing resolution steps 1-7 of the Stage B v2 plan. Pure: no
    /// IOKit, callable from unit tests and the corpus-replay sweep alike.
    ///
    /// - Parameters:
    ///   - device: the PCIe-carried USB device (`tunnelCarrier == .pcieTunnel`).
    ///     Callers are expected to have already checked this; the function
    ///     itself does not branch on `tunnelCarrier`.
    ///   - chainNodes: the port's downstream Thunderbolt switches, flattened
    ///     (`ThunderboltTopology.flatten(chain)`). The host root is never a
    ///     member of this list by construction (`ThunderboltTopology.tree`
    ///     returns the root's CHILDREN), so step 1's "host-root adapters are
    ///     never candidates" rule holds automatically; nothing here needs to
    ///     filter depth 0 explicitly.
    static func resolvePCIeTunnelCandidate(
        device: USBDevice,
        chainNodes: [IOThunderboltSwitchNode]
    ) -> PCIeStageBOutcome {
        // Review fix (HIGH, round 2026-08-13): a device with no `tunnelRootName`
        // at all (the walk never reached an `apciecN` root, the Stage A
        // failure invariant) must never be evaluated by Stage B, matched OR
        // forced to port level. Stage B's own port-scope gate (step 7,
        // `rootIsTrusted` in `resolve()`) only refuses a WRONG root; a nil
        // root skips that check entirely (nothing to compare) and would
        // otherwise reach the completeness/path/entry-ID gates below on
        // controller data that has no port to belong to. Checked first, so
        // a no-root device always falls back to the Stage A shortcut path
        // (itself gated on `tunnelRootName != nil` in `resolve()`, so a
        // nil-root device stays fully unattributed there too).
        guard device.tunnelRootName != nil else { return .fallbackToStageA }

        // Path hygiene (step 6): nonempty, starts "IOService:/". Anything
        // else (nil, empty, whitespace, a truncated capture) is "not usable"
        // and trips the completeness gate below, never treated as a ""
        // prefix that would match everything.
        // Review fix (MEDIUM, round 2026-08-13): the old version validated
        // the TRIMMED string but returned the untrimmed `raw` value, so a
        // value carrying leading/trailing whitespace (" IOService:/..." or a
        // trailing newline from a truncated capture) passed hygiene while
        // still comparing UNEQUAL to a clean string at the same logical
        // path: two candidates that should tie (or match) would silently
        // disagree, and a device whose only "problem" was one-sided
        // whitespace landed in `forcedPortLevel` (a structural finding)
        // instead of `fallbackToStageA` (a missing/unusable-input finding).
        // Reject rather than normalise: a value that isn't ALREADY exactly
        // its own trimmed form is unusable, full stop, same bucket as
        // empty/malformed.
        func usablePath(_ raw: String?) -> String? {
            guard let raw else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw == trimmed, !trimmed.isEmpty, trimmed.hasPrefix("IOService:/") else { return nil }
            return raw
        }

        struct Candidate { let switchID: Int64; let path: String; let entryID: UInt64 }

        // Step 1 + step 2 (completeness gate): collect one PCIe up-adapter
        // candidate per downstream switch. If ANY downstream switch lacks a
        // usable candidate, no prefix attribution happens for this port at
        // all: return immediately rather than silently letting the switches
        // that DO have a candidate compete. A missing deeper path must never
        // let a shallower switch win by default.
        var candidates: [Candidate] = []
        for node in chainNodes {
            guard
                let upAdapter = node.sw.ports.first(where: { $0.adapterType == .pcieUp }),
                let path = usablePath(upAdapter.pciPath),
                let entryID = upAdapter.pciEntryID
            else {
                return .fallbackToStageA
            }
            candidates.append(Candidate(switchID: node.sw.id, path: path, entryID: entryID))
        }
        guard !candidates.isEmpty else { return .fallbackToStageA }

        // Step 3: the controller's own record must carry a usable path and
        // at least one ancestor entry ID, or there is nothing to join
        // against and the caller falls back to the shortcut.
        guard
            let controllerPath = usablePath(device.tunnelControllerRegistryPath),
            !device.tunnelAncestorEntryIDs.isEmpty
        else {
            return .fallbackToStageA
        }

        // Step 4 + step 11 (instance identity): a candidate matches only
        // when BOTH hold: its `pciEntryID` is a member of the controller's
        // ancestor entry IDs (the registry-instance check: a stale record
        // whose landing node died fails this even with an identical path
        // string), and its path is a boundary-safe prefix of the
        // controller's path (component-wise: `.../pci-bridge@1` must never
        // prefix-match `.../pci-bridge@10`, hence the explicit "/" join
        // rather than a bare `hasPrefix`).
        let matches = candidates.filter { candidate in
            device.tunnelAncestorEntryIDs.contains(candidate.entryID)
                && (candidate.path == controllerPath || controllerPath.hasPrefix(candidate.path + "/"))
        }
        guard !matches.isEmpty else {
            // Valid-but-no-match (step 4/12): complete, usable evidence, zero
            // matches. Structural, terminal: port level, NOT the shortcut.
            return .portLevel
        }

        // Step 5: pick the deepest match. A candidate's path is always a
        // component-wise prefix of the controller's path once it passes the
        // filter above, so within this matching set, longer path length
        // (character count) is equivalent to "landing node deeper in the
        // controller's ancestor list" / "longer matching prefix": comparing
        // lengths of two strings in a prefix relationship is exactly what
        // ordering their nesting depth means. Duplicate equal-length paths
        // on the SAME switch collapse via the `Set` below before the tie
        // check runs, so they never falsely register as a tie.
        let deepestLength = matches.map { $0.path.count }.max()!
        let deepestSwitchIDs = Set(matches.filter { $0.path.count == deepestLength }.map(\.switchID))
        guard deepestSwitchIDs.count == 1, let winner = deepestSwitchIDs.first else {
            // Two DIFFERENT switches tied at the same depth: a registry
            // anomaly, not a resolvable join. Port level (step 5).
            return .portLevel
        }
        return .matched(winner)
    }

    // MARK: - TB5 Gen T shared-controller tunnel-hub mapping

    /// Intel silicon known to publish an anonymous internal USB3 hub on a
    /// TB5 Gen T shared-controller tunnel tree (spec 3.2's known-silicon
    /// table). Extend from corpus evidence; unknown silicon fails the
    /// candidate-count gate closed rather than guessing.
    private static let tb5TunnelHubProductIDs: Set<UInt16> = [0x0B40, 0x0B41, 0x5787]
    private static let tb5TunnelHubVendorID: UInt16 = 0x8087

    /// Per the TB5 tunnel-hub attribution spec (the private design note "TB5 tunnel-hub attribution", sections 3.1-3.4): on a TB5 chain where every box's USB3 tunnel
    /// shares ONE tunnelled controller (Gen T tunneling), each box
    /// contributes one anonymous Intel internal hub to that shared USB
    /// forest, with no name or vendor string tying it to its box (the
    /// existing name/inheritance/vendor-continuity signals cannot place
    /// them). This walks the fabric's route strings to compute which hub
    /// belongs to which box, and returns the full `[hub deviceID: switch
    /// id]` bijection only when the topology resolves one-to-one. Every gate
    /// fails closed (returns `nil`), mirroring
    /// `resolvePCIeTunnelCandidate`'s shape: pure, no IOKit, callable
    /// directly from tests and the corpus-replay sweep.
    static func resolveTB5TunnelHubMap(
        chainNodes: [IOThunderboltSwitchNode],
        forest: [USBDeviceNode],
        usbTunnelSwitchUIDs: Set<Int64>
    ) -> [UInt64: Int64]? {
        guard !chainNodes.isEmpty else { return nil }

        // 3.1 Scope gate: the shared-controller shape, primarily. The
        // owner's own JHL9580 dock capture publishes plain `usb3Up`
        // (0x200102) adapters, not Gen T (0x210102), so the Gen T adapter
        // check alone would refuse the exact machine this pass exists for.
        // `usbTunnelSwitchUIDs` already names every chain switch THIS
        // port's fabric confirms carries a USB tunnel
        // (`ThunderboltTopology.tunnels(...).filter { $0.kind == .usb }`).
        // Two or more of them on one port's chain means they share ONE
        // `AppleUSBXHCITR` controller by construction: a TB3/TB4
        // separate-controller chain gives every box its OWN tunnelled
        // controller, so it can never produce two-or-more members here.
        // The Gen T adapter check is kept as a corroborating OR (spec's
        // "with the Gen T adapter check as a corroborating OR, not the
        // sole trigger"), for silicon that does publish it.
        let confirmedTunnelSwitchCount = chainNodes.filter { usbTunnelSwitchUIDs.contains($0.sw.id) }.count
        let sharedControllerShape = confirmedTunnelSwitchCount >= 2
        // One box on its own, its USB tunnel confirmed by the fabric: the walk
        // below reduces to that box claiming the one top candidate hub.
        // Without this a JHL9580 dock alone never reaches the pass.
        let loneConfirmedBox = chainNodes.count == 1 && confirmedTunnelSwitchCount == 1
        let genTAdapterPresent = chainNodes.contains { node in
            node.sw.ports.contains { $0.adapterType == .usbGenTUp }
        }
        guard sharedControllerShape || loneConfirmedBox || genTAdapterPresent else { return nil }

        // 3.2 Candidate tunnel hubs: Intel known-silicon VID/PID, positioned
        // either at the top of this port's USB forest or directly under
        // another candidate (a chain of anonymous hubs, one per box).
        let allNodes = USBDeviceNode.flatten(forest)
        var parentOfDevice: [UInt64: UInt64] = [:]
        for node in allNodes {
            for child in node.children { parentOfDevice[child.device.id] = node.device.id }
        }
        let vendorMatches = allNodes.filter {
            $0.device.vendorID == tb5TunnelHubVendorID && tb5TunnelHubProductIDs.contains($0.device.productID)
        }
        let vendorMatchIDs = Set(vendorMatches.map(\.device.id))
        let candidates = vendorMatches.filter { node in
            guard let parentID = parentOfDevice[node.device.id] else { return true }
            return vendorMatchIDs.contains(parentID)
        }
        // Hard gate (spec 3.2's one-to-one invariant): candidate count must
        // equal chain box count EXACTLY. Fewer (a box in USB fallback,
        // its own follow-up ticket) or more (unknown silicon, duplicated PIDs)
        // aborts the whole pass rather than attributing a partial or
        // ambiguous set.
        guard candidates.count == chainNodes.count, !candidates.isEmpty else { return nil }
        let candidateByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.device.id, $0) })

        let rootCandidates = candidates.filter { parentOfDevice[$0.device.id] == nil }
        guard rootCandidates.count == 1, let rootCandidate = rootCandidates.first else { return nil }

        // 3.3 Expected topology from the fabric side: which chain switch is
        // the depth-1 box (attaches directly to the host root, so it is not
        // any other chain switch's child), and the parent -> child switch
        // edges among the rest.
        var switchByID: [Int64: IOThunderboltSwitchNode] = [:]
        for node in chainNodes { switchByID[node.sw.id] = node }
        var childSwitchesOf: [Int64: [IOThunderboltSwitchNode]] = [:]
        var rootSwitches: [IOThunderboltSwitchNode] = []
        for node in chainNodes {
            if let parentUID = node.sw.parentSwitchUID, switchByID[parentUID] != nil {
                childSwitchesOf[parentUID, default: []].append(node)
            } else {
                rootSwitches.append(node)
            }
        }
        // Mirrors 3.4's "two candidates at root position, abort" rule on the
        // fabric side: this pass is built for one linear chain per port (the
        // shape the bug report is about), so more than one depth-1 box on
        // the same port's chain is refused rather than guessed at.
        guard rootSwitches.count == 1, let rootSwitch = rootSwitches.first else { return nil }

        // 3.4 Matching: walk the expected tree onto the candidate hubs,
        // exact bijection or nothing. The depth-1 box claims the root
        // candidate unconditionally (spec 3.3); every other edge computes an
        // expected hub port from the child switch's own route-string byte
        // and requires exactly one unclaimed candidate there.
        var hubForSwitch: [Int64: UInt64] = [rootSwitch.sw.id: rootCandidate.device.id]
        var claimedHubs: Set<UInt64> = [rootCandidate.device.id]
        var queue: [IOThunderboltSwitchNode] = [rootSwitch]
        while !queue.isEmpty {
            let parent = queue.removeFirst()
            guard let parentHubID = hubForSwitch[parent.sw.id], let parentHub = candidateByID[parentHubID]
            else { return nil }
            for child in childSwitchesOf[parent.sw.id] ?? [] {
                // Spec 2 point 1: the child's Route String byte at index
                // (depth - 1) is the Adapter Number of the PARENT's
                // downstream lane port the child is plugged into. Verified
                // against `DataLinkDiagnostic.partnerSwitch`'s own
                // routeString-low-byte convention (a depth-1 partner's low
                // byte, index 0, is the parent's port number): index scales
                // with depth the same way here.
                let depth = child.sw.depth
                guard depth >= 1 else { return nil }
                let shift = 8 * (depth - 1)
                guard shift < 64 else { return nil }
                let routeByte = UInt8((child.sw.routeString >> shift) & 0xFF)
                // Spec 2 point 3 / 3.3: hub_port = (route_byte - 1) / 2,
                // requiring an odd byte in range. A non-odd or zero byte is
                // not a valid Adapter Number under this formula: abort the
                // whole pass rather than guess a rounded value.
                guard routeByte >= 1, routeByte % 2 == 1 else { return nil }
                let expectedPort = Int(routeByte - 1) / 2

                // Cross-check against the parent switch's `USB Port Map`
                // when it publishes one (spec 3.3). Review fix: this used
                // to check only that SOME entry named `expectedPort` as its
                // `usb4Port`, never reading `usb3Adapter` at all, so the
                // field the spec is actually about (USB4 2.0 s5.2.5's
                // "USB4 ports pair with USB3 adapters in order of
                // increasing Adapter Numbers") went unverified. Now:
                // - Order the parent's own USB3-capable adapter ports
                //   ascending by `portNumber`. Measured live on the
                //   JHL-family reference rig (2026-08-24): this includes
                //   the switch's UPSTREAM adapter (`.usb3Up`/`.usbGenTUp`),
                //   not just its downstream ones. A first version of this
                //   check ordered downstream adapters only, which put
                //   usb4Port 1 at ordinal 0 against the wrong adapter (a
                //   downstream one instead of the upstream one the map
                //   actually names) and made the whole pass abort on the
                //   owner's own dock. Confirmed pairing: usb4Port 1 pairs
                //   the upstream USB3 adapter, usb4Ports 2+ pair downstream
                //   adapters in ascending order (the JHL9580 reference:
                //   port 20 = usb3Up pairs usb4Port 1, ports 21-23 =
                //   usb3Down pair usb4Ports 2-4). Ordinal 0 -> usb4Port 1,
                //   and so on. This ordinal comparison is verified on this
                //   silicon family (JHL-class) only.
                // - The entry for `expectedPort` must exist AND its
                //   `usb3Adapter` must equal the adapter at ordinal
                //   `expectedPort - 1` in that ordered list. A swapped
                //   pairing (right port numbers, wrong adapter) now aborts
                //   instead of silently passing.
                // - When the parent's `ports` carries no USB3-capable
                //   adapter at all (some fixtures/probe-29 replays never
                //   populate `ports`), there is nothing to order against,
                //   so this falls back to the weaker existence check: the
                //   entry for `expectedPort` must exist, unpaired.
                // A missing or empty map (truncated on a zero-downstream
                // box, or an older capture) still skips the check entirely
                // rather than aborting: the formula alone is the
                // 5/5-verified primary signal.
                if let rawMap = parent.sw.usbPortMap {
                    let entries = USBPortMapEntry.parse(rawMap)
                    if !entries.isEmpty {
                        guard let mapEntry = entries.first(where: { $0.usb4Port == expectedPort }) else { return nil }
                        let orderedAdapters = parent.sw.ports
                            .filter {
                                $0.adapterType == .usb3Up || $0.adapterType == .usb3Down
                                    || $0.adapterType == .usbGenTUp || $0.adapterType == .usbGenTDown
                            }
                            .sorted { $0.portNumber < $1.portNumber }
                        if !orderedAdapters.isEmpty {
                            let ordinal = expectedPort - 1
                            guard ordinal >= 0, ordinal < orderedAdapters.count,
                                  orderedAdapters[ordinal].portNumber == mapEntry.usb3Adapter
                            else { return nil }
                        }
                    }
                }

                let matchingCandidates = candidates.filter { candidate in
                    !claimedHubs.contains(candidate.device.id)
                        && USBDevice.childHubPort(
                            parent: parentHub.device.locationID,
                            child: candidate.device.locationID
                        ) == expectedPort
                }
                guard matchingCandidates.count == 1, let matched = matchingCandidates.first else { return nil }
                hubForSwitch[child.sw.id] = matched.device.id
                claimedHubs.insert(matched.device.id)
                queue.append(child)
            }
        }

        // Every box must claim exactly one hub and every candidate hub must
        // be claimed (spec 3.4): the count gate above makes this an exact
        // bijection once the walk succeeds, but a switch the walk never
        // reached (a `parentSwitchUID` graph that doesn't cover every chain
        // switch) would otherwise silently return a partial map.
        guard hubForSwitch.count == chainNodes.count, claimedHubs.count == candidates.count else { return nil }

        var result: [UInt64: Int64] = [:]
        for (switchID, hubID) in hubForSwitch { result[hubID] = switchID }
        return result
    }

    // MARK: - USB2 top hubs by position and Container ID

    /// The comparable form of a published Container ID, or nil when there is
    /// nothing to pair on. macOS publishes the all-zero UUID for a device that
    /// declares none, so it means absent, not shared.
    static func containerIDKey(_ raw: String?) -> String? {
        guard let key = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !key.isEmpty,
              key != "00000000-0000-0000-0000-000000000000"
        else { return nil }
        return key
    }

    /// USB2 hub id -> chain switch id: each box's top USB2 hub, found box by
    /// box in chain order. A hub's USB2 and USB3 halves are separate USB
    /// devices sharing one Container ID, and only the USB3 half sits where
    /// the structural pass can place it. A box's top USB2 hub sits directly
    /// under the top USB2 hub of the box above it (directly under the USB
    /// root for a first box) and carries an ID that one of the box's owned
    /// USB3-side devices carries and no other box's does. No list of IDs is
    /// needed: an ID two boxes share is dropped from both.
    ///
    /// An ID qualifies a box only if no USB3-side device owned by another box
    /// on the chain carries it: a shared ID identifies neither box.
    ///
    /// All or nothing: exactly one hub must qualify for every box. If any box
    /// gets none, two, or one `accepts` refuses, the result is empty and the
    /// USB2 side renders as it does today. A partial answer would leave the
    /// unpaired box's USB2 devices inside the box above it.
    ///
    /// Side is the device's own speed: a USB2-only device in a USB3 socket
    /// enumerates on the hub's USB2 half, so speed and side cannot disagree.
    static func resolveUSB2HubPairing(
        chainNodes: [IOThunderboltSwitchNode],
        forest: [USBDeviceNode],
        usb3Owner: [UInt64: Int64],
        accepts: (_ hubID: UInt64, _ switchID: Int64) -> Bool = { _, _ in true }
    ) -> [UInt64: Int64] {
        var nodeByID: [UInt64: USBDeviceNode] = [:]
        var keysByBox: [Int64: Set<String>] = [:]
        for node in USBDeviceNode.flatten(forest) {
            nodeByID[node.device.id] = node
            guard (node.device.speedRaw ?? 0) >= 3,
                  let key = containerIDKey(node.device.containerID),
                  let owner = usb3Owner[node.device.id]
            else { continue }
            keysByBox[owner, default: []].insert(key)
        }

        let chainIDs = Set(chainNodes.map(\.sw.id))
        var hubForBox: [Int64: UInt64] = [:]
        var result: [UInt64: Int64] = [:]
        // `chainNodes` is a preorder walk, so a box's parent is settled first.
        for box in chainNodes {
            let position: [USBDeviceNode]
            if let parentUID = box.sw.parentSwitchUID, chainIDs.contains(parentUID) {
                guard let parentHubID = hubForBox[parentUID], let parentHub = nodeByID[parentHubID] else { return [:] }
                position = parentHub.children
            } else {
                position = forest
            }
            // An ID another box's USB3 side also carries identifies neither box.
            var keys = keysByBox[box.sw.id] ?? []
            for (other, otherKeys) in keysByBox where other != box.sw.id { keys.subtract(otherKeys) }
            let qualifying = position.filter { node in
                guard node.device.isHub, let speed = node.device.speedRaw, speed <= 2,
                      let key = containerIDKey(node.device.containerID)
                else { return false }
                return keys.contains(key)
            }
            guard qualifying.count == 1, let hub = qualifying.first, accepts(hub.device.id, box.sw.id) else { return [:] }
            hubForBox[box.sw.id] = hub.device.id
            result[hub.device.id] = box.sw.id
        }
        return result
    }

    // MARK: - USB3 check on identity claims

    /// True when `device` cannot be `box`'s identity device: it enumerated
    /// at SuperSpeed or faster, and the box publishes adapters but no USB3
    /// one. A device carried over a PCIe tunnel is exempt, since Thunderbolt
    /// 3 docks carry their USB that way and publish no USB3 adapter. An empty
    /// adapter list is no evidence either way, so it never refuses.
    static func usb3CheckRefuses(_ device: USBDevice, box: IOThunderboltSwitch) -> Bool {
        guard (device.speedRaw ?? 0) >= 3,
              device.tunnelCarrier != .pcieTunnel,
              !box.ports.isEmpty
        else { return false }
        let usb3Adapters: Set<AdapterType> = [.usb3Down, .usb3Up, .usbGenTDown, .usbGenTUp]
        return !box.ports.contains { usb3Adapters.contains($0.adapterType) }
    }

    // MARK: - Resolution

    /// - Parameters:
    ///   - chain: the downstream Thunderbolt tree for ONE port, as
    ///     `ThunderboltTopology.tree(from:in:)` returns it.
    ///   - forest: the USB device forest for the same port, as
    ///     `USBDeviceNode.buildTree(from:)` returns it.
    ///   - usbTunnelSwitchUIDs: the switch UIDs of the USB-carrying tunnels
    ///     THIS port's fabric actually reports (`ThunderboltTopology
    ///     .tunnels(from:in:).filter { $0.kind == .usb }
    ///     .compactMap(\.terminalSwitchUID)`). The structural tunnel join
    ///     below only ever considers switches in this set: an empty set
    ///     (no hop-table data, or the caller didn't compute it) means the
    ///     structural pass places nothing, which is the correct fail-closed
    ///     default, not a silent behaviour change.
    ///   - expectedTunnelRootName: this port's own `apciecN` root name (from
    ///     its host root switch's `acioRootName`, converted by
    ///     `ThunderboltTopology.apciecRootName(fromAcioRootName:)`), used to
    ///     refuse a tunnelled device whose `tunnelRootName` names a
    ///     DIFFERENT port. `nil` when the caller could not derive it (older
    ///     capture, or the acio walk's bound was exceeded); the structural
    ///     pass still runs then, but falls back to an internal-consistency
    ///     check (see below).
    public static func resolve(
        chain: [IOThunderboltSwitchNode],
        forest: [USBDeviceNode],
        usbTunnelSwitchUIDs: Set<Int64> = [],
        expectedTunnelRootName: String? = nil
    ) -> ChainDeviceAttribution {
        let chainNodes = ThunderboltTopology.flatten(chain)
        let allNodes = USBDeviceNode.flatten(forest)
        guard !chainNodes.isEmpty, !allNodes.isEmpty else { return .none }

        var nodeByID: [UInt64: USBDeviceNode] = [:]
        var parentOf: [UInt64: UInt64] = [:]
        for node in allNodes { nodeByID[node.device.id] = node }
        for node in allNodes {
            for child in node.children { parentOf[child.device.id] = node.device.id }
        }

        // Numeric identity (#493/PR 500): a chain device's Thunderbolt DROM
        // carries a NUMERIC vendor/model pair (`Device Vendor ID`, `Device
        // Model ID`) alongside its name, and a native USB endpoint's own
        // `idVendor`/`idProduct` match those numbers EXACTLY for a
        // single-function accessory. Hoisted up here (it used to live
        // further down, inside the name-matching section) because the
        // structural tunnel join below needs it too, for the same
        // precedence-safety reason the name match does: a device whose OWN
        // numeric identity disagrees with its structurally-derived switch is
        // not safe to place structurally either.
        //
        // Two defensive rules, both found by review (#493 round 5):
        //
        // 1. Zero is refused explicitly, even though `IOThunderboltSwitch`
        //    already normalises a non-positive/out-of-range DROM value to
        //    `nil` at parse time (see `IOThunderboltLink.swift`). Belt and
        //    suspenders: `USBDevice.vendorID`/`productID` default to 0 on a
        //    failed descriptor read (`USBWatcher.swift`), and a fixture or a
        //    future caller could still construct an `IOThunderboltSwitch`
        //    with `dromVendorID`/`dromModelID` of 0 directly, bypassing that
        //    normalisation. Without this guard, two unrelated devices that
        //    BOTH failed their descriptor read would "exactly match" each
        //    other on 0/0, and reproducing that promoted an unrelated hub.
        //
        // 2. The match set is checked for AMBIGUITY, not just existence,
        //    mirroring the file's existing duplicate-name rule ("two chain
        //    devices with the same model name match neither", `exact[...]`
        //    below). Two chain devices sharing an identical DROM VID+PID
        //    pair (two identical daisy-chained docks, the same product
        //    twice) both match, and picking "whichever comes first" silently
        //    cross-attributes one region into the other. More than one match
        //    is refused outright, exactly like the name-based case: no
        //    numeric identity is safer than a wrong one.
        func numericIdentity(of device: USBDevice) -> IOThunderboltSwitchNode? {
            guard device.vendorID != 0, device.productID != 0 else { return nil }
            let matches = chainNodes.filter {
                guard let dvid = $0.sw.dromVendorID, dvid != 0,
                      let dmid = $0.sw.dromModelID, dmid != 0
                else { return false }
                return dvid == Int(device.vendorID) && dmid == Int(device.productID)
            }
            return matches.count == 1 ? matches.first : nil
        }

        // 1. Anchors: a USB product name that matches a chain device's model
        // name. Matched against `modelName`, NOT
        // `ThunderboltLabels.deviceName(for:)`: that prepends the DROM vendor
        // ("Ugreen Group Limited TBT5 Docking Station 10-in-1") and would never
        // match the USB side. Names are whitespace-collapsed and case-folded
        // because the fabric reports "Studio Display " with a trailing space.
        var switchIDsByName: [String: Set<Int64>] = [:]
        for node in chainNodes {
            let key = normalized(node.sw.modelName)
            // Two characters is not a name, it is a chance collision.
            guard key.count >= 3 else { continue }
            switchIDsByName[key, default: []].insert(node.sw.id)
        }

        var exact: [UInt64: Int64] = [:]
        for node in allNodes {
            guard let product = node.device.productName else { continue }
            let key = normalized(product)
            guard key.count >= 3 else { continue }
            // Two chain devices with the same model name (two identical
            // daisy-chained displays: "UltraFine 4K" twice in the corpus)
            // cannot be told apart by name, so neither is matched.
            if let ids = switchIDsByName[key], ids.count == 1, let id = ids.first {
                exact[node.device.id] = id
            }
        }

        // 1b. Structural tunnel join, ahead of every OTHER name-based signal
        // below (the affiliate pass, vendor continuity) but SUBORDINATE to a
        // device's own exact-name or numeric identity (checked just below):
        // two strong, independent signals disagreeing means one of them is
        // wrong and this function cannot tell which, so the device fails
        // closed and neither places it (see the precedence-safety note
        // below).
        //
        // A tunnelled USB device (`isThunderboltTunnelled`) carries
        // `tunnelBridgeDepth`: the count of PCIe bridge hops between its
        // `AppleUSBXHCITR` controller and the port's `apciecN` root. On Apple
        // Silicon that count is always twice the TB DROM `Depth` of the
        // switch whose own USB tunnel the device rides
        // (`research/usb-chain-attribution-identifiers.md`, confirmed on the
        // #493 reporter's own two captures and re-checked across ~40 further
        // corpus folders during the follow-up investigation: a LaCie 1big at
        // DROM depth 2 sits 4 bridge hops from its port's `apciec2` root, a
        // Studio Display chained behind it at depth 3 sits 6 hops from the
        // SAME root). Dividing by two turns the raw count into a `sw.depth`
        // to look up directly against this port's chain, no name required:
        // this catches devices a name match cannot, like a Studio Display's
        // internal "USB2 Hub" and "USB3 Gen2 Hub" personas, which carry no
        // name hinting at the display at all.
        //
        // THREE gates, all of which must pass, in order:
        //
        // 1. **Only switches this port's fabric confirms carry a USB
        //    tunnel** (`usbTunnelSwitchUIDs`, derived by the caller from
        //    `ThunderboltTopology.tunnels(...).filter { $0.kind == .usb }`).
        //    Gated per DEPTH within that set, not per whole chain: a target
        //    depth only resolves when exactly one CONFIRMED-tunnelled switch
        //    sits there. This is deliberately narrower than "the whole chain
        //    is linear" would be, and the difference is real, not
        //    theoretical: the #493 reporter's own ground-truth machine has
        //    the CalDigit dock fan out to TWO depth-2 siblings, an OWC
        //    Express 1M2 (PCIe tunnel only, no USB tunnel of its own) and the
        //    LaCie 1big (tunnel bridge depth 4). A whole-chain gate, or a
        //    gate that counted every switch at a depth rather than only
        //    confirmed USB-tunnel ones, would refuse the LaCie's structural
        //    join purely because the OWC happens to share its depth, even
        //    though the OWC contributes zero conflicting bridge-depth
        //    evidence: nothing ever computes a target depth of 2 from the
        //    OWC, because it has no `AppleUSBXHCITR` controller to walk.
        //    Restricting to `usbTunnelSwitchUIDs` resolves LaCie's devices
        //    (and the Studio Display's, depth 3, chained behind it) while OWC
        //    is excluded from `depthCounts` entirely, which is the correct
        //    "cannot own anything" outcome for a device with no USB tunnel.
        //    Two GENUINELY USB-tunnelled switches sharing one depth is the
        //    actually-unproven case (zero corpus examples: 10 ports have
        //    more than one tunnelled controller, all 10 at distinct depths),
        //    and per-depth gating refuses exactly that, and only that.
        // 2. **The device's `tunnelRootName` belongs to THIS port.** When
        //    `expectedTunnelRootName` is known, an exact string match is
        //    required: a mismatch means this device's tunnel controller sits
        //    under a DIFFERENT physical port's `apciecN` root, a cross-port
        //    mixup, and it is refused outright regardless of how well the
        //    depth arithmetic lines up. When `expectedTunnelRootName` is
        //    `nil` (the caller could not derive it), this function falls
        //    back to an INTERNAL consistency check across every candidate in
        //    THIS resolve() call: if they disagree on `tunnelRootName`
        //    amongst themselves, that is itself evidence of a cross-port
        //    mixup upstream (devices from two different ports ended up in
        //    the same `forest`), and every one of them is refused; if they
        //    agree (or none report a root at all, e.g. replaying probe data
        //    that only captured up to the old terminator), the pass
        //    proceeds as before.
        // 3. **Precedence safety.** A device whose own exact-name match
        //    (`exact[id]`) or numeric identity (`numericIdentity(of:)`)
        //    resolves to a DIFFERENT chain device than the structural depth
        //    lookup is placed by NEITHER signal: it goes into
        //    `forcedPortLevelIDs`, its name/numeric claim is stripped before
        //    the marks/identityMark pipeline below, and it stops inherited
        //    ownership for its subtree. A device tunnelled at a depth
        //    pointing one way and named toward another has produced two
        //    signals that cannot both be right, and placing it by either
        //    risks putting it (and, if it is a hub, everything under it)
        //    in the wrong box. It renders in the port's separate list.
        var depthCounts: [Int: [Int64]] = [:]
        for node in chainNodes where usbTunnelSwitchUIDs.contains(node.sw.id) {
            depthCounts[node.sw.depth, default: []].append(node.sw.id)
        }
        var switchIDByDepth: [Int: Int64] = [:]
        for (depth, ids) in depthCounts where ids.count == 1 { switchIDByDepth[depth] = ids[0] }

        // Raw candidates: every tunnelled device whose bridge depth resolves
        // to an unambiguous switch, BEFORE the root-name and
        // precedence-safety gates. Built first (rather than folded into one
        // loop) because the root-name internal-consistency fallback needs to
        // see every candidate's `tunnelRootName` before deciding whether ANY
        // of them can be trusted.
        // Which mechanism produced a raw candidate. `.usbTunnelDepth`,
        // `.tb5TunnelHubMap` (the route-string/USB-Port-Map join in
        // `resolveTB5TunnelHubMap`) and `.pcieStageBMatch` all get the
        // STRONG contradiction rule: a name/numeric disagreement sends the
        // device to `forcedPortLevel`, excluded from every later pass, so
        // neither signal places it. Only `.pcieStageAShortcut` keeps the
        // weaker `structurallyConflicted` rule (excluded from `absorbed`
        // only); Stage A runs only on a one-box chain, where its candidate
        // and any identity claim name the same box. See the contradiction
        // check below.
        enum CandidateSource { case usbTunnelDepth, pcieStageAShortcut, pcieStageBMatch, tb5TunnelHubMap }
        struct StructuralCandidate { let id: UInt64; let switchID: Int64; let rootName: String?; let source: CandidateSource }
        var rawCandidates: [StructuralCandidate] = []
        // Terminal port-level outcome (Stage B v2 plan step 8/9, widened):
        // devices the PCI-Path join positively places OUTSIDE every chain
        // switch on this port (valid-but-no-match, a tie, a stale entry ID),
        // or whose usbTunnel-depth, TB5 route-map or Stage B candidate
        // contradicts independent name/numeric evidence. Populated
        // here and by the contradiction check further down; consumed by the
        // exact/affiliate filter, `descend`, `vendorDescend`, and the
        // redundant-root removal pass, all below.
        var forcedPortLevelIDs: Set<UInt64> = []
        for node in allNodes {
            guard node.device.isThunderboltTunnelled else { continue }
            // Carrier-gated: each structural path requires the carrier that
            // proves its arithmetic applies. A nil (unknown) carrier joins
            // nothing structurally: old fixtures and replays of captures that
            // never recorded the terminator keep exactly the name-pass +
            // fallback behaviour they had before carriers existed.
            switch node.device.tunnelCarrier {
            case .usbTunnel:
                // The corpus-verified USB-tunnel depth relation
                // (bridgeDepth == 2 x DROM depth).
                guard let bridgeDepth = node.device.tunnelBridgeDepth,
                      bridgeDepth >= 2, bridgeDepth.isMultiple(of: 2),
                      let switchID = switchIDByDepth[bridgeDepth / 2]
                else { continue }
                rawCandidates.append(StructuralCandidate(id: node.device.id, switchID: switchID, rootName: node.device.tunnelRootName, source: .usbTunnelDepth))
            case .pcieTunnel:
                // Stage B v2: PCI Path prefix join (resolution steps 1-7),
                // falling back to the Stage A single-switch shortcut when an
                // input is missing, and recording a terminal port-level
                // boundary when the join positively finds no match.
                switch Self.resolvePCIeTunnelCandidate(device: node.device, chainNodes: chainNodes) {
                case .matched(let switchID):
                    rawCandidates.append(StructuralCandidate(id: node.device.id, switchID: switchID, rootName: node.device.tunnelRootName, source: .pcieStageBMatch))
                case .portLevel:
                    forcedPortLevelIDs.insert(node.device.id)
                case .fallbackToStageA:
                    // Stage A single-switch shortcut (plan v5): a device on a
                    // dock-supplied PCIe xHCI (LG UltraFine, TS3+ class) whose
                    // rootName scopes it to this port attributes to the chain's
                    // sole downstream switch, with NO depth arithmetic. The
                    // rootName requirement is what makes this a structural
                    // claim rather than a guess: a no-root device (walk never
                    // reached apciecN) stays fully unattributed (not even the
                    // shortcut fires).
                    guard chainNodes.count == 1,
                          node.device.tunnelRootName != nil
                    else { continue }
                    rawCandidates.append(StructuralCandidate(id: node.device.id, switchID: chainNodes[0].sw.id, rootName: node.device.tunnelRootName, source: .pcieStageAShortcut))
                }
            case nil:
                continue
            }
        }

        // TB5 Gen T shared-controller tunnel-hub mapping (spec
        // 3.1-3.5). Runs once per port, over the whole forest, rather than
        // per device: appended AFTER the per-device loop above so that, in
        // the rare case a hub device also satisfies the existing
        // `usbTunnelDepth` conditions (every device behind a SHARED
        // controller reports the SAME `tunnelBridgeDepth`, which is exactly
        // why that pass cannot solve this shape: see spec section 1), this
        // pass's own per-hub answer is the one `rawCandidates` processing
        // order lets win.
        let tb5HubMap = Self.resolveTB5TunnelHubMap(
            chainNodes: chainNodes, forest: forest, usbTunnelSwitchUIDs: usbTunnelSwitchUIDs
        )
        if let tb5HubMap {
            // Review fix: `tb5HubMap` is a `Dictionary`, with no defined
            // iteration order. The comment just above this block promises
            // rawCandidates processing order puts a parent before its
            // child (the `for candidate in rawCandidates` loop further
            // down reads `structuralOwner[parentID]`), so appending in
            // dictionary order made that guarantee accidental rather than
            // real: 25 randomised runs never caught it, but nothing
            // enforced it either. Sorting by each hub's USB-tree preorder
            // position (parents always precede their children in a
            // preorder walk) makes the order deterministic and restores
            // the guarantee on purpose.
            let preorderIndex: [UInt64: Int] = Dictionary(
                uniqueKeysWithValues: allNodes.enumerated().map { ($1.device.id, $0) }
            )
            let orderedHubs = tb5HubMap.sorted {
                (preorderIndex[$0.key] ?? Int.max) < (preorderIndex[$1.key] ?? Int.max)
            }
            for (hubDeviceID, switchID) in orderedHubs {
                let rootName = nodeByID[hubDeviceID]?.device.tunnelRootName
                rawCandidates.append(StructuralCandidate(id: hubDeviceID, switchID: switchID, rootName: rootName, source: .tb5TunnelHubMap))
            }
        }

        let rootIsTrusted: (String?) -> Bool
        if let expectedTunnelRootName {
            rootIsTrusted = { $0 == expectedTunnelRootName }
        } else {
            let distinctRoots = Set(rawCandidates.compactMap(\.rootName))
            rootIsTrusted = distinctRoots.count > 1 ? { _ in false } : { _ in true }
        }

        var structuralOwner: [UInt64: Int64] = [:]
        var structuralRoots: [UInt64: Int64] = [:]
        // Excluded from `absorbed` only. Only a `.pcieStageAShortcut`
        // candidate can land here now; every other conflicting source goes
        // to `forcedPortLevelIDs` instead (see the contradiction check).
        var structurallyConflicted: Set<UInt64> = []
        // `rawCandidates` preserves `allNodes`'s pre-order (`USBDeviceNode
        // .flatten`), so a device's parent is always processed before it,
        // which lets the region-root check below read
        // `structuralOwner[parentID]` immediately rather than needing a
        // second pass.
        for candidate in rawCandidates {
            // Live-rig fix: for `.tb5TunnelHubMap` candidates specifically, a
            // nil `rootName` is TRUSTED rather than refused. Every other
            // source keeps the unconditional `rootIsTrusted` check, nil
            // included (this is NOT the same situation as the nil-root
            // handling in `resolvePCIeTunnelCandidate` above, despite the
            // surface similarity of "nil root, don't refuse blindly": that
            // guard makes Stage B fall back to Stage A rather than treating
            // nil as trusted, because a normal tunnelled device's nil root
            // means the watcher's own walk to an apciecN root FAILED for a
            // device that should have one. Here it means something
            // different: the anonymous Intel tunnel hubs this pass places
            // structurally never carry tunnel-controller ancestry of their
            // own to walk in the first place (they are the shared
            // controller's OWN internal hub, not something tunnelled behind
            // it), so `tunnelRootName` is nil by construction, not by
            // failure. `resolveTB5TunnelHubMap`'s scope gate has already
            // proven these candidates belong to THIS port before this loop
            // ever runs (built from `usbTunnelSwitchUIDs`, itself
            // caller-scoped per port, and drawn from this port's own
            // `forest`), so requiring a root-name stamp these devices
            // structurally cannot carry would refuse the pass on the exact
            // devices it exists to place. A non-nil root that disagrees with
            // `expectedTunnelRootName` is still refused exactly as before:
            // this only widens what counts as "nothing to compare", it does
            // not accept a wrong answer.
            if candidate.source == .tb5TunnelHubMap {
                if let rootName = candidate.rootName, !rootIsTrusted(rootName) { continue }
            } else {
                guard rootIsTrusted(candidate.rootName) else { continue }
            }
            guard let node = nodeByID[candidate.id] else { continue }
            // Terminal: once forced (by Stage B, or by an earlier candidate's
            // conflict below), no later candidate may mark this device.
            if forcedPortLevelIDs.contains(candidate.id) { continue }
            let namedConflict = exact[candidate.id].map { $0 != candidate.switchID } ?? false
            let numericConflict = numericIdentity(of: node.device).map { $0.sw.id != candidate.switchID } ?? false
            if namedConflict || numericConflict {
                // Two strong, independent signals disagree: the device's
                // position puts it in one box, its own name or numbers name
                // another. This function cannot tell which is wrong, and a
                // device in the wrong box is worse than one left in the
                // port's separate list, so for every structural source that
                // can name a box other than the identity's, the device goes
                // to `forcedPortLevel`: a TERMINAL exclusion from every later
                // pass, not merely from `absorbed`. Its name/numeric claim is
                // stripped just below (`exact`, then the numeric loop that
                // builds `identityClaims`), so neither signal places it, it
                // never becomes a mark, and it stops inherited ownership for
                // its subtree.
                //
                // The conflict uses the RAW `exact` and `numericIdentity`,
                // before the USB3 check filters `identityClaims`: a claim
                // that check would refuse still counts as a disagreement,
                // which is the conservative side.
                //
                // `.pcieStageAShortcut` keeps the weaker
                // `structurallyConflicted` rule (excluded from `absorbed`
                // only). Stage A only fires on a one-box chain, so its
                // candidate and any identity claim name the same box and this
                // branch is not reachable for it in practice.
                switch candidate.source {
                case .usbTunnelDepth, .tb5TunnelHubMap, .pcieStageBMatch:
                    forcedPortLevelIDs.insert(candidate.id)
                    // A device can carry two candidates (a TB5 hub can also
                    // satisfy the depth join). Drop any structural mark an
                    // earlier, agreeing candidate left, so a forced device is
                    // never a region root.
                    structuralOwner[candidate.id] = nil
                    structuralRoots[candidate.id] = nil
                case .pcieStageAShortcut:
                    structurallyConflicted.insert(candidate.id)
                }
                continue
            }
            structuralOwner[candidate.id] = candidate.switchID
            // Region root only at the boundary of the structural group: if
            // the nearest USB-tree parent already carries the SAME owner,
            // inheritance already covers this device and marking it again
            // would render its subtree twice (the same redundant-mark
            // hazard step 5 below guards against for the name-based passes).
            let parentSharesOwner = parentOf[candidate.id].flatMap { structuralOwner[$0] } == candidate.switchID
            if !parentSharesOwner {
                structuralRoots[candidate.id] = candidate.switchID
            }
        }

        // 2. Identity claims name a box. A device's own DROM numbers are a
        // far stronger join than a product-name string, which can coincide
        // by accident or by a generic word, so when a device's idVendor/
        // idProduct identify exactly one box (`numericIdentity(of:)`), that
        // box wins over the box its name matched. Numeric evidence counts
        // only when it POSITIVELY matches: some units report a different
        // vendor id on the Thunderbolt and USB sides, so a mismatch proves
        // nothing on its own. The claim itself places only the identity
        // device (see `identityMark` below).
        func claimedBox(_ device: USBDevice, nameMatch switchID: Int64) -> Int64 {
            numericIdentity(of: device)?.sw.id ?? switchID
        }
        // Position evidence is now complete except for the USB2 pairing,
        // which is position evidence too (place plus Container ID) and runs
        // next, so that identity claims meet ALL of it in one place below.

        // Each box's top USB2 hub, by position and Container ID. Owners come
        // from structural marks alone, inherited down the forest, so an
        // identity claim never seeds this pass. `accepts` is the precedence
        // check, and it reads position marks and the hub's OWN identity only:
        // - a hub forced to port level, or one a structural mark already
        //   places in another box, is refused (position against position:
        //   the pairing yields, and all or nothing empties it);
        // - a hub whose own identity (exact name or DROM numbers) names
        //   another box is a same-node contradiction, so it is forced to
        //   port level as well as refused, exactly as the candidate loop
        //   above forces a structural candidate that contradicts its own
        //   identity. Forcing is what keeps the contradiction on record
        //   after all-or-nothing has wiped the pairing's own evidence;
        //   without it the hub's numbers would mark it into the box its
        //   position contradicts.
        // An identity claim from a device below the hub is not consulted
        // here: it places only that device (`identityMark`).
        var structuralInherited: [UInt64: Int64] = [:]
        func inheritStructural(_ node: USBDeviceNode, _ inherited: Int64?) {
            let owner = forcedPortLevelIDs.contains(node.device.id)
                ? nil
                : (structuralRoots[node.device.id] ?? inherited)
            if let owner { structuralInherited[node.device.id] = owner }
            for child in node.children { inheritStructural(child, owner) }
        }
        for root in forest { inheritStructural(root, nil) }
        let topUSB2Hubs = Self.resolveUSB2HubPairing(
            chainNodes: chainNodes, forest: forest, usb3Owner: structuralInherited
        ) { hubID, switchID in
            if forcedPortLevelIDs.contains(hubID) { return false }
            if let structural = structuralRoots[hubID], structural != switchID { return false }
            if let hub = nodeByID[hubID]?.device,
               let ownIdentity = numericIdentity(of: hub)?.sw.id ?? exact[hubID],
               ownIdentity != switchID {
                forcedPortLevelIDs.insert(hubID)
                return false
            }
            return true
        }

        // A `forcedPortLevel` device (Stage B v2 step 8, a structural
        // conflict in the candidate loop, or a pairing conflict just above)
        // is excluded from EVERY chain-attribution mechanism, name-based
        // ones included. Strip it from `exact` now, after every pass that
        // needed the raw `exact` to detect a conflict and before `exact`
        // seeds `identityClaims`; the numeric half of `identityClaims` skips
        // forced devices where it is built. So a forced device can never
        // become a `regionRoot` or get `absorbed` on its own name/numeric
        // evidence, and `identityMark` is never invoked with it as the
        // claimant either.
        if !forcedPortLevelIDs.isEmpty {
            exact = exact.filter { !forcedPortLevelIDs.contains($0.key) }
        }

        // Position evidence ABOUT one node: a structural candidate of its
        // own, or the pairing's choice of it as a box's top USB2 hub.
        // Inherited ownership is not position evidence about the node.
        func positionBox(_ deviceID: UInt64) -> Int64? {
            structuralOwner[deviceID] ?? topUSB2Hubs[deviceID]
        }

        // THE RULE where identity evidence meets position evidence (owner
        // ruling, 2026-10-08). Every identity claim (exact name or DROM
        // numbers) passes through here once, after all position evidence is
        // settled, and nothing else combines the two. In full:
        //
        // 1. Identity evidence places only the identity device itself. It
        //    never passes the box on to a parent hub: no tier of numeric or
        //    vendor evidence promotes a claim onto the hub above it.
        // 2. An identity device that is itself a hub is not marked, unless
        //    position evidence already places that same hub in the same box,
        //    where the mark changes nothing. Hubs, and everything under
        //    them, are grouped only by position evidence: the TB5 route map,
        //    the USB-tunnel depth join, PCIe Stage A and B, and the USB2
        //    pairing.
        // 3. A device whose own position evidence names a different box
        //    from its identity is placed by neither: it is forced to port
        //    level (the candidate loop and the pairing's `accepts` above),
        //    so it never reaches here as a claimant. The check here is the
        //    same rule applied once more, defensively.
        // 4. Position marks are then merged over identity marks. By 2 and 3,
        //    the two never name different boxes for one node, so the merge
        //    adds and never overrides.
        //
        // Why: a mark on a hub flows down to everything below it, and an
        // identity device can hang on a hub that belongs to another box (a
        // chained enclosure's billboard on the dock's own USB2 hub). Every
        // earlier attempt to fence that flow guarded one meeting point and
        // left the next one open. A mark that lands only on a device that
        // is not a hub cannot carry anything with it.
        func identityMark(_ deviceID: UInt64, claimedBy switchID: Int64) -> Int64? {
            guard let device = nodeByID[deviceID]?.device,
                  !forcedPortLevelIDs.contains(deviceID)
            else { return nil }
            let box = claimedBox(device, nameMatch: switchID)
            if let positioned = positionBox(deviceID) { return positioned == box ? box : nil }
            return device.isHub ? nil : box
        }

        // The box's own identity devices: an exact name match, or a device
        // whose VID/PID equal one box's DROM numbers. Numeric identity wins
        // in `claimedBox` when the two disagree.
        var identityClaims = exact
        for node in allNodes where identityClaims[node.device.id] == nil
            && !forcedPortLevelIDs.contains(node.device.id) {
            if let box = numericIdentity(of: node.device) { identityClaims[node.device.id] = box.sw.id }
        }
        // USB3 check: a SuperSpeed device reached the Mac over a USB3 path,
        // so it cannot be the identity device of a box that has none. The
        // box is the one the claim names, after any numeric override.
        identityClaims = identityClaims.filter { deviceID, switchID in
            guard let device = nodeByID[deviceID]?.device else { return true }
            let boxID = claimedBox(device, nameMatch: switchID)
            guard let box = chainNodes.first(where: { $0.sw.id == boxID }) else { return true }
            return !Self.usb3CheckRefuses(device, box: box.sw)
        }
        var regionRoots: [UInt64: Int64] = [:]
        for (deviceID, switchID) in identityClaims {
            if let box = identityMark(deviceID, claimedBy: switchID) { regionRoots[deviceID] = box }
        }

        // 3. Position marks over identity marks. `identityMark` has already
        // kept every identity mark off a node position places elsewhere, so
        // this merge only adds: `structural` wins is a statement of
        // precedence, not a path that fires.
        regionRoots.merge(structuralRoots) { _, structural in structural }
        for (hubID, switchID) in topUSB2Hubs { regionRoots[hubID] = switchID }

        // 3. Inherit down the forest. A deeper mark overrides a shallower one,
        // which is exactly how a chained dock's subtree separates from the
        // display's while nested inside it.
        var regionOwner: [UInt64: Int64] = [:]
        func descend(_ node: USBDeviceNode, _ inherited: Int64?) {
            // Stage B v2 boundary (step 9): a `forcedPortLevel` node stops
            // inherited ownership dead, both for itself (it never takes an
            // owner from above, even though nothing marks it a regionRoot
            // either) and for everything below it, UNLESS a descendant
            // carries its own independent `regionRoots` entry (a
            // self-anchoring claim), which `regionRoots[node.device.id] ??
            // inherited` already picks up ahead of `inherited` on that
            // descendant's own recursive call.
            let isBoundary = forcedPortLevelIDs.contains(node.device.id)
            let owner = isBoundary ? nil : (regionRoots[node.device.id] ?? inherited)
            if let owner { regionOwner[node.device.id] = owner }
            let childInherited = isBoundary ? nil : owner
            for child in node.children { descend(child, childInherited) }
        }
        for root in forest { descend(root, nil) }

        // Reported, not acted on: no pass reads it any more.
        let allAnchored = Set(regionRoots.values).count == chainNodes.count

        // 5. Drop redundant marks: a region root whose nearest marked ancestor
        // has the same owner adds nothing, because inheritance already covers
        // its subtree. Left in, it would render that subtree TWICE in the
        // expanded view, once inside its ancestor and once as a region of its
        // own.
        //
        // Reachable, not theoretical: a box's own identity endpoint (marked
        // by its name or numbers) routinely hangs below a hub that position
        // evidence already places in the same box. Two marks, same chain
        // device, nested. Decided against the marks as they stood, not against a set being
        // mutated underneath the loop: with a three-deep nest, each level has to
        // be judged against its real nearest ancestor rather than one that a
        // previous iteration has already removed.
        let marked = regionRoots
        for (id, owner) in marked {
            // `seen` is what makes this walk provably terminate: each pass either
            // stops or adds a new id to a finite set. `parentOf` is keyed by IOKit
            // entry ID rather than locationID, and while the forest itself cannot
            // contain a cycle (`parentLocationID` clears a nibble, so the path
            // strictly shortens), two devices arriving with the SAME entry ID
            // would collide in this map and could form one. A hang in the menu
            // bar app's render path is the worst outcome available here, so it is
            // ruled out structurally rather than assumed away.
            var seen: Set<UInt64> = [id]
            var cursor = parentOf[id]
            while let ancestor = cursor, !seen.contains(ancestor) {
                seen.insert(ancestor)
                // Stage B v2 boundary (step 9, round-9 finding): a mark ABOVE
                // a `forcedPortLevel` ancestor must never be treated as
                // covering a root below it. Stop the walk at the boundary
                // without matching, exactly as though nothing further up
                // marked anything: the descendant's own regionRoots entry
                // (an independently anchored subtree) survives untouched.
                if forcedPortLevelIDs.contains(ancestor) { break }
                if let ancestorOwner = marked[ancestor] {
                    if ancestorOwner == owner { regionRoots[id] = nil }
                    break
                }
                cursor = parentOf[ancestor]
            }
        }

        // 6. Absorbed: the final identity decision for each identity claim
        // (exact name or DROM numbers), not the raw `identityClaims`
        // dictionary. `identityMark` is re-run here, so an absorbed device
        // is exactly one whose claim marks it: a hub claimant `identityMark`
        // refused is not marked, so it is not collapsed into a box row
        // either. A device flagged `structurallyConflicted` above
        // (only a Stage A shortcut candidate disagreeing with this SAME
        // identity claim) is excluded: its name/numeric placement is kept,
        // but it is not collapsed into the chain row as though there were no
        // doubt about its identity. A device forced to port level never
        // reaches this loop: it is not in `identityClaims`.
        var absorbed: Set<UInt64> = []
        for (deviceID, switchID) in identityClaims {
            guard !structurallyConflicted.contains(deviceID),
                  identityMark(deviceID, claimedBy: switchID) != nil
            else { continue }
            absorbed.insert(deviceID)
        }

        return ChainDeviceAttribution(
            regionOwner: regionOwner,
            regionRoots: regionRoots,
            absorbed: absorbed,
            allAnchored: allAnchored,
            portLevelBoundaries: forcedPortLevelIDs
        )
    }

    /// Whitespace-collapsed, case-folded name for matching a USB product name
    /// against a fabric model name. Internal punctuation is kept: it is part of
    /// the name ("10-in-1") and dropping it would let unrelated names collide.
    static func normalized(_ name: String) -> String {
        name.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }
}
