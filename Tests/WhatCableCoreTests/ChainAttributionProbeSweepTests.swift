import Foundation
import Testing
@testable import WhatCableCore

/// Corpus-replay sweep for `ChainDeviceAttribution`.
///
/// The attribution is inference over two IOKit surfaces that share no join key,
/// so the thing worth testing is not "does it place devices" but "does it ever
/// place one WRONGLY". Fixtures cannot answer that: they only contain the cases
/// somebody thought of. This replays the real corpus instead.
///
/// **Both inputs come from probes, and the fabric one was thought unavailable.**
/// `research/corpus-test-coverage.md` recorded that per-port fabric topology
/// could not be replayed from probe 29 because it lists switches and ports as
/// FLAT sections with no nesting. True, but incomplete: each switch block
/// carries `RegistryEntryID` and `ParentSwitchEntryID`, which is the same parent
/// link the live watcher uses, so the graph reconstructs exactly. That turns 30
/// daisy-chained machines into replay material where there were 4 tb-debug
/// dumps.
///
/// **Machines with more than one Thunderbolt chain are skipped**, and the count
/// is asserted so the skip cannot quietly become "all of them". Attribution runs
/// per port, and nothing in probe 29 or 38 says which port a tunnelled USB
/// device arrived on, so pairing a chain with the right devices is not possible
/// from this data. Sweeping them anyway would mean feeding the resolver one
/// port's chain and another port's devices, which is a fabricated input, and any
/// result from it would be meaningless.
///
/// Skips the full-corpus floors (not a fail) when too little of the corpus is
/// on disk to make a full-corpus claim: a fresh clone or worktree only has the
/// tracked fixtures, currently two folders
/// (`m3pro_macos27.0_l` / `_m`, added for the #493 regression below), which is
/// nowhere near the 40-chain floor. Per-folder correctness invariants still
/// run against whatever IS present, because those hold regardless of corpus
/// size.
@Suite("ChainDeviceAttribution corpus sweep")
struct ChainAttributionProbeSweepTests {

    private static let probeRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WhatCableCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("research/customer-probes")
    }()

    // MARK: - Probe loading

    private static func folders() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: probeRoot.path))?.sorted() ?? []
    }

    private static func probeText(_ folder: String, _ file: String) -> String? {
        let url = probeRoot.appendingPathComponent(folder).appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = root["output"] as? String
        else { return nil }
        return text
    }

    // MARK: - Probe 29: the fabric graph

    private struct RawSwitch {
        let entryID: Int64
        let parentEntryID: Int64
        let depth: Int
        let model: String
        let vendor: String
        let className: String
        /// Numeric DROM identity, read independently from the same probe
        /// text (own `intValue` parser, not production's `read(...)`
        /// closure): `Device Vendor ID` / `Device Model ID`. Distinct keys
        /// from the registry's plain `Vendor ID` / `Device ID` (the
        /// PCIe/controller chip identity), which this re-derivation does not
        /// read at all, matching production's `IOThunderboltSwitch.from`.
        let dromVendorID: Int?
        let dromModelID: Int?
        /// TB5 tunnel-hub attribution: the route-string formula's own input. Not previously
        /// parsed by this sweep (the previous `model()` hardcoded 0,
        /// which every earlier check here was indifferent to since nothing
        /// used route strings before this pass).
        let routeString: Int64
        /// Raw `USB Port Map` property (TB5 tunnel-hub attribution), if the block published one.
        /// Independent parser (`portMapData(_:)` below), not
        /// `USBPortMapEntry.parse` itself: the file's OWN triplet parser is
        /// unit-tested against the reference hex; this only needs to turn
        /// probe 29's `USB Port Map =     Data[15]: 01 81 94 ...` text into
        /// the raw `Data` production reads from a live property.
        let usbPortMap: Data?
        /// The router's chip `Device ID`, used only to match probe 29's flat
        /// port blocks back to their switch (`probe29Ports`).
        let deviceID: Int64?
    }

    /// Probe 29 prints the raw `USB Port Map` bytes as
    /// `USB Port Map =     Data[15]: 01 81 94 02 82 95 ...` (space-separated
    /// hex pairs, "Data[N]:" prefix). Returns `nil` when the key is absent.
    private static func portMapData(_ body: String) -> Data? {
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("USB Port Map = ") else { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { return nil }
            let hexPart = trimmed[trimmed.index(after: colon)...]
            let bytes = hexPart.split(separator: " ").compactMap { UInt8($0, radix: 16) }
            return bytes.isEmpty ? nil : Data(bytes)
        }
        return nil
    }

    /// Instance blocks for one IOKit class. Probe 29 writes
    /// `--- ClassName[N] "name" ---` headers inside `=== ClassName ===`
    /// sections, and a block ends at the next header or section.
    private static func blocks(_ text: String, className: String) -> [(name: String, body: String)] {
        var out: [(name: String, body: String)] = []
        var header: String?
        var body: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("--- \(className)["), trimmed.hasSuffix("---") {
                if let h = header { out.append((h, body.joined(separator: "\n"))) }
                header = trimmed
                body = []
            } else if trimmed.hasPrefix("=== "), trimmed.hasSuffix(" ==="), header != nil {
                out.append((header!, body.joined(separator: "\n")))
                header = nil
                body = []
            } else if header != nil {
                body.append(line)
            }
        }
        if let h = header { out.append((h, body.joined(separator: "\n"))) }
        return out
    }

    private static func intValue(_ body: String, _ key: String) -> Int64? {
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(key) = ") else { continue }
            let after = trimmed.dropFirst(key.count + 3).drop(while: { $0 == " " })
            let digits = after.prefix { $0.isNumber || $0 == "-" }
            if let v = Int64(digits) { return v }
        }
        return nil
    }

    private static func stringValue(_ body: String, _ key: String) -> String? {
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(key) = ") else { continue }
            let after = trimmed.dropFirst(key.count + 3).drop(while: { $0 == " " })
            guard after.hasPrefix("\"") else { continue }
            let inner = after.dropFirst()
            if let close = inner.firstIndex(of: "\"") { return String(inner[..<close]) }
        }
        return nil
    }

    private static func rawSwitches(_ text: String) -> [RawSwitch] {
        var byEntry: [Int64: RawSwitch] = [:]
        for (name, body) in blocks(text, className: "IOThunderboltSwitch") {
            guard let entry = intValue(body, "RegistryEntryID"),
                  let depth = intValue(body, "Depth")
            else { continue }
            // Probe 29 can list the same node twice (once per host-root walk).
            byEntry[entry] = RawSwitch(
                entryID: entry,
                parentEntryID: intValue(body, "ParentSwitchEntryID") ?? 0,
                depth: Int(depth),
                model: stringValue(body, "Device Model Name") ?? "",
                vendor: stringValue(body, "Device Vendor Name") ?? "",
                className: name.replacingOccurrences(of: "--- IOThunderboltSwitch", with: ""),
                dromVendorID: intValue(body, "Device Vendor ID").map(Int.init),
                dromModelID: intValue(body, "Device Model ID").map(Int.init),
                routeString: intValue(body, "Route String") ?? 0,
                usbPortMap: Self.portMapData(body),
                deviceID: intValue(body, "Device ID")
            )
        }
        return byEntry.values.sorted { $0.entryID < $1.entryID }
    }

    private static func model(_ raw: RawSwitch, ports: [IOThunderboltPort] = []) -> IOThunderboltSwitch {
        IOThunderboltSwitch(
            id: raw.entryID,
            className: "IOThunderboltSwitch",
            vendorID: 0,
            vendorName: raw.vendor,
            modelName: raw.model,
            routerID: raw.depth,
            depth: raw.depth,
            routeString: raw.routeString,
            upstreamPortNumber: 1,
            maxPortNumber: 12,
            supportedSpeed: SupportedSpeedMask(rawValue: 0),
            ports: ports,
            // Entry IDs stand in for UIDs here: the graph only needs the parent
            // link to be internally consistent, which it is.
            parentSwitchUID: raw.parentEntryID == 0 ? nil : raw.parentEntryID,
            dromVendorID: raw.dromVendorID,
            dromModelID: raw.dromModelID,
            usbPortMap: raw.usbPortMap
        )
    }

    /// Downstream chains, one per host root that has anything below it.
    private static func chains(
        _ raws: [RawSwitch],
        ports: [Int64: [IOThunderboltPort]] = [:]
    ) -> [[IOThunderboltSwitchNode]] {
        let switches = raws.map { model($0, ports: ports[$0.entryID] ?? []) }
        return raws
            .filter { $0.depth == 0 }
            .map { ThunderboltTopology.tree(from: model($0), in: switches) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Probe 38: the USB forest

    /// Probe 38 writes `--- Device[N] ---` blocks with single-spaced
    /// `key = value` lines. Deliberately parsed here rather than reusing the
    /// copy in `ConnectedDeviceTreeTests`: an independent parser is the point.
    private static func usbDevices(_ text: String) -> [USBDevice] {
        var devices: [USBDevice] = []
        var body: [String] = []
        var index: UInt64 = 0

        func flush() {
            defer { body = [] }
            guard !body.isEmpty else { return }
            let joined = body.joined(separator: "\n")
            func hex(_ key: String) -> UInt32? {
                for line in body {
                    let t = line.trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix("\(key) = ") else { continue }
                    let v = t.dropFirst(key.count + 3).trimmingCharacters(in: .whitespaces)
                    if v.hasPrefix("0x") { return UInt32(v.dropFirst(2), radix: 16) }
                    return UInt32(v)
                }
                return nil
            }
            guard let loc = hex("locationID") else { return }
            index += 1
            devices.append(USBDevice(
                id: index,
                locationID: loc,
                vendorID: hex("idVendor").map { UInt16(truncatingIfNeeded: $0) } ?? 0,
                productID: hex("idProduct").map { UInt16(truncatingIfNeeded: $0) } ?? 0,
                vendorName: stringLine(joined, "USB Vendor Name"),
                productName: stringLine(joined, "USB Product Name"),
                serialNumber: nil,
                usbVersion: nil,
                speedRaw: hex("Device Speed").map { UInt8(truncatingIfNeeded: $0) },
                busPowerMA: nil,
                currentMA: nil,
                busIndex: Int(loc >> 24),
                deviceClass: hex("bDeviceClass").map { UInt8(truncatingIfNeeded: $0) },
                rawProperties: [:]
            ))
        }

        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("--- Device[") {
                flush()
            } else {
                body.append(line)
            }
        }
        flush()
        return devices
    }

    private static func stringLine(_ text: String, _ key: String) -> String? {
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("\(key) = \"") else { continue }
            let inner = t.dropFirst(key.count + 4)
            if let close = inner.firstIndex(of: "\"") { return String(inner[..<close]) }
        }
        return nil
    }

    // MARK: - Probe 37: PCIe bridge depth for tunnelled devices
    //
    // The `m3pro_macos27.0_l`/`_m` copies of
    // `research/customer-probes/*/37_tb_tunnel_port_map.json` are tracked in
    // git (`.gitignore` negation, alongside their probe-29/38 siblings), so
    // this half of the sweep runs on a fresh clone or a worktree too, not
    // just the primary folder after a private probe-ingest step.
    // Every OTHER folder's probe 37 stays untracked, so `probe37BridgeDepths`
    // still returns an empty map for them there; the caller treats that as
    // "leave every device's structural fields nil", exactly the same honest
    // degrade the live `USBWatcher` walk produces when its own bound is
    // exceeded.
    //
    // Independent parser: probe 37's own C source
    // (`probes/test-kit/37_tb_tunnel_port_map.c`) prints the same
    // `IORegistryEntryGetPath` strings `USBWatcher.tunnelBridgeAncestry` reads
    // live, but this re-derives the count from the printed path text rather
    // than sharing any code with `USBWatcher`.
    private static func probe37BridgeDepths(_ text: String) -> [UInt32: (depth: Int, root: String)] {
        guard let section = text.range(of: "--- Tunnelled USB devices"),
              let hpmSection = text.range(of: "=== HPM UUID map", range: section.upperBound..<text.endIndex)
        else { return [:] }
        let body = text[section.upperBound..<hpmSection.lowerBound]

        var result: [UInt32: (depth: Int, root: String)] = [:]
        var pendingLoc: UInt32?
        for rawLine in body.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("locationID="), let paren = line.firstIndex(of: "(") {
                let hexPart = line[line.index(after: paren)...].prefix { $0 != ")" }
                pendingLoc = UInt32(hexPart.dropFirst(2), radix: 16) // "0x..." -> drop "0x"
                continue
            }
            guard line.hasPrefix("IOService:"), let loc = pendingLoc else { continue }
            pendingLoc = nil
            var bridgeCount = 0
            var rootName: String?
            for segment in line.split(separator: "/") {
                let name = segment.split(separator: "@").first.map(String.init) ?? String(segment)
                if name == "pci-bridge" { bridgeCount += 1 }
                if name.hasPrefix("apciec") { rootName = name }
            }
            if let rootName {
                result[loc] = (bridgeCount, rootName)
            }
        }
        return result
    }

    /// The switch UIDs a production caller would pass as `usbTunnelSwitchUIDs`:
    /// every chain switch sitting at a depth some device's own
    /// `tunnelBridgeDepth / 2` names. This is test SETUP for the real
    /// function under test (preparing its inputs the way the doc comment on
    /// `ChainDeviceAttribution.resolve` says a caller should), not part of
    /// the independent re-derivation `structuralMarks` does separately below.
    private static func usbTunnelSwitchUIDs(chainNodes: [IOThunderboltSwitchNode], devices: [USBDevice]) -> Set<Int64> {
        let candidateDepths = Set(devices.compactMap { device -> Int? in
            guard device.isThunderboltTunnelled,
                  let bd = device.tunnelBridgeDepth, bd >= 2, bd % 2 == 0
            else { return nil }
            return bd / 2
        })
        return Set(chainNodes.filter { candidateDepths.contains($0.sw.depth) }.map { $0.sw.id })
    }

    /// Rebuilds a device list with `isThunderboltTunnelled` / `tunnelBridgeDepth`
    /// / `tunnelRootName` filled in from the probe-37 map, matched by
    /// `locationID`. Devices with no entry in the map (everything probe 37
    /// didn't report as tunnelled) pass through unchanged.
    private static func applyBridgeDepths(
        _ devices: [USBDevice],
        _ depths: [UInt32: (depth: Int, root: String)]
    ) -> [USBDevice] {
        guard !depths.isEmpty else { return devices }
        return devices.map { device in
            guard let entry = depths[device.locationID] else { return device }
            return USBDevice(
                id: device.id, locationID: device.locationID,
                vendorID: device.vendorID, productID: device.productID,
                vendorName: device.vendorName, productName: device.productName,
                serialNumber: device.serialNumber, usbVersion: device.usbVersion,
                speedRaw: device.speedRaw, busPowerMA: device.busPowerMA, currentMA: device.currentMA,
                busIndex: device.busIndex, controllerPortName: device.controllerPortName,
                isThunderboltTunnelled: true,
                tunnelBridgeDepth: entry.depth, tunnelRootName: entry.root,
                // Probe 37 maps AppleUSBXHCITR controllers only, so every
                // depth entry here is a USB-tunnel capture by construction.
                tunnelCarrier: .usbTunnel,
                deviceClass: device.deviceClass, rawProperties: device.rawProperties
            )
        }
    }

    // MARK: - Independent re-derivations

    private static func normalise(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    /// Independent re-derivation of the structural passes: exact name matches
    /// settle regions, then word-run matches fill gaps they do not contradict, a
    /// hub claimed by two different chain devices is claimed by neither.
    ///
    /// **Deliberately shares no code with production, including the word-run
    /// matcher.** An earlier version of this called
    /// `ChainDeviceAttribution.affiliated(product:model:)` directly, which meant
    /// a false positive in that function produced the identical wrong answer on
    /// both sides and every comparison below agreed with itself. Flagged in
    /// review, and it is the project's own rule: a check that reads the same
    /// source as the thing it checks certifies bugs rather than catching them.
    ///
    /// Returns the marks AND the set of chain devices that actually hold a
    /// region, which are different from the set that merely matched a name: where
    /// two chain devices name endpoints on one shared hub, both matched and
    /// neither holds a region. The vendor-continuity gate keys on regions, so the
    /// test has to re-derive that rather than read `allAnchored` back off the
    /// result. It read the result at first, which made the check agree with a
    /// mutation that removed the gate.
    /// Chain device whose DROM (Device Vendor ID, Device Model ID) exactly
    /// equals a USB device's own (idVendor, idProduct), if any. Own
    /// re-derivation, reading the same `dromVendorID`/`dromModelID` fields
    /// `RawSwitch`/`model()` parsed independently above.
    ///
    /// Own re-derivation of production's two defensive rules (#493 round 5):
    /// zero never counts (a failed USB descriptor read defaults
    /// idVendor/idProduct to 0, and a fixture-constructed DROM pair could
    /// carry a raw 0 too), and the match SET is checked for ambiguity, not
    /// just existence, mirroring the file's duplicate-name rule: more than
    /// one chain device sharing an identical DROM VID+PID pair is refused,
    /// not resolved to "whichever comes first".
    private static func numericIdentity(of device: USBDevice, chain: [IOThunderboltSwitchNode]) -> IOThunderboltSwitchNode? {
        guard device.vendorID != 0, device.productID != 0 else { return nil }
        let matches = chain.filter {
            guard let dvid = $0.sw.dromVendorID, dvid != 0,
                  let dmid = $0.sw.dromModelID, dmid != 0
            else { return false }
            return dvid == Int(device.vendorID) && dmid == Int(device.productID)
        }
        return matches.count == 1 ? matches.first : nil
    }

    /// Own re-derivation of production's identity rule (owner ruling
    /// 2026-10-08): an identity claim places only the identity device itself,
    /// never its parent hub. The box it names is the device's own DROM
    /// numbers when they identify exactly one chain device, else the name
    /// match's (numbers beat the name). A hub identity device is not marked:
    /// production marks one only where position already places that hub in
    /// the same box, and the structural merge in `structuralMarks`
    /// reproduces that mark on its own.
    private static func claimBox(
        _ device: USBDevice,
        claimedBy switchID: Int64,
        chain: [IOThunderboltSwitchNode]
    ) -> Int64? {
        if device.isHub { return nil }
        return numericIdentity(of: device, chain: chain)?.sw.id ?? switchID
    }

    private static func structuralMarks(
        chain: [IOThunderboltSwitchNode],
        devices: [USBDevice]
    ) -> (marks: [UInt64: Int64], resolvedSwitches: Set<Int64>, affiliateMarksRefused: Int) {
        let forest = USBDeviceNode.buildTree(from: devices)

        func marks(_ matches: [(device: USBDevice, switchID: Int64)]) -> [UInt64: Int64] {
            var result: [UInt64: Int64] = [:]
            for match in matches {
                guard let box = Self.claimBox(match.device, claimedBy: match.switchID, chain: chain) else { continue }
                result[match.device.id] = box
            }
            return result
        }

        func ownership(_ current: [UInt64: Int64]) -> [UInt64: Int64] {
            var owner: [UInt64: Int64] = [:]
            func walk(_ node: USBDeviceNode, _ inherited: Int64?) {
                let mine = current[node.device.id] ?? inherited
                if let mine { owner[node.device.id] = mine }
                for child in node.children { walk(child, mine) }
            }
            for root in forest { walk(root, nil) }
            return owner
        }

        // Identity claims: an exact name match, or a device whose own
        // VID/PID equal exactly one chain device's DROM pair. Partial names
        // group nothing (2026-10-08).
        var exactMatches: [(device: USBDevice, switchID: Int64)] = []
        for device in devices {
            if let product = device.productName, normalise(product).count >= 3 {
                let named = chain.filter { normalise($0.sw.modelName).count >= 3 }
                let exact = named.filter { normalise($0.sw.modelName) == normalise(product) }
                if !exact.isEmpty {
                    if exact.count == 1, let id = exact.first?.sw.id { exactMatches.append((device, id)) }
                    continue
                }
            }
            if let box = numericIdentity(of: device, chain: chain) { exactMatches.append((device, box.sw.id)) }
        }

        // Structural tunnel pass, independent re-derivation: a
        // tunnelled device's `tunnelBridgeDepth` divided by two is the TB
        // DROM depth of the switch that owns its tunnel, looked up directly,
        // no name involved. Shares no code with `ChainDeviceAttribution`
        // beyond `USBDeviceNode.buildTree`, which is plain tree
        // infrastructure, not an attribution decision.
        //
        // Restricted to CONFIRMED USB-tunnel-bearing depths, independently
        // derived from the same probe-37 bridge-depth evidence devices
        // already carry (not from calling any production helper): the depths
        // any device's own `tunnelBridgeDepth / 2` actually names. This
        // mirrors production's `usbTunnelSwitchUIDs` restriction (only
        // switches THIS port's fabric confirms carry a USB tunnel), then
        // gates PER DEPTH within that set (only depths with exactly one such
        // switch resolve), not per whole chain: the #493 reporter's own
        // ground-truth machine has a depth-2 sibling (OWC, no USB tunnel)
        // next to the LaCie (which has one), and a whole-chain gate, or one
        // that counted every switch at a depth rather than only
        // confirmed-tunnelled ones, would wrongly refuse the LaCie too.
        let candidateDepths = Set(devices.compactMap { device -> Int? in
            guard device.isThunderboltTunnelled,
                  let bd = device.tunnelBridgeDepth, bd >= 2, bd % 2 == 0
            else { return nil }
            return bd / 2
        })
        var depthCounts: [Int: [Int64]] = [:]
        for node in chain where candidateDepths.contains(node.sw.depth) {
            depthCounts[node.sw.depth, default: []].append(node.sw.id)
        }
        var switchByDepth: [Int: Int64] = [:]
        for (depth, ids) in depthCounts where ids.count == 1 { switchByDepth[depth] = ids[0] }

        // Root-name internal consistency, mirroring production's fallback
        // when `expectedTunnelRootName` is unknown (which this sweep never
        // supplies, since it has no acioRootName data to derive it from):
        // every candidate must agree on `tunnelRootName`, or the whole
        // structural pass is refused.
        let candidateRoots = Set(devices.compactMap { device -> String? in
            guard device.isThunderboltTunnelled,
                  let bd = device.tunnelBridgeDepth, bd >= 2, bd % 2 == 0,
                  switchByDepth[bd / 2] != nil
            else { return nil }
            return device.tunnelRootName
        })
        let rootsAreConsistent = candidateRoots.count <= 1

        var exactByDevice: [UInt64: Int64] = [:]
        for match in exactMatches { exactByDevice[match.device.id] = match.switchID }

        var structuralResult: [UInt64: Int64] = [:]
        if rootsAreConsistent {
            for device in devices {
                guard device.isThunderboltTunnelled,
                      let bridgeDepth = device.tunnelBridgeDepth,
                      bridgeDepth >= 2, bridgeDepth % 2 == 0,
                      let switchID = switchByDepth[bridgeDepth / 2]
                else { continue }
                // Precedence safety: a device whose own exact-name or
                // numeric match disagrees with the structural switch is not
                // placed structurally. Production goes further and also
                // drops the identity claim and stops inheritance below it
                // (`forcedPortLevelIDs`); this oracle still keeps the
                // identity claim, so the ownership equality below would fail
                // on any swept folder that reached that case. None does
                // today.
                if let namedSwitch = exactByDevice[device.id], namedSwitch != switchID { continue }
                structuralResult[device.id] = switchID
            }
        }

        // Structural wins outright over name matching (when it does not
        // conflict with a device's own name match, per the precedence-safety
        // check above), mirroring production's precedence.
        var result = marks(exactMatches)
        result.merge(structuralResult) { _, structural in structural }
        return (result, Set(result.values), 0)
    }

    /// Word-run containment, either direction, written from the rule rather than
    /// from the production implementation: one name's words must appear as an
    /// unbroken run inside the other's.
    private static func wordRunMatch(_ a: String, _ b: String) -> Bool {
        func words(_ s: String) -> [String] {
            var out: [String] = []
            var current = ""
            for character in s.lowercased() {
                if character.isLetter || character.isNumber {
                    current.append(character)
                } else if !current.isEmpty {
                    out.append(current)
                    current = ""
                }
            }
            if !current.isEmpty { out.append(current) }
            return out
        }
        func run(_ needle: [String], in haystack: [String]) -> Bool {
            guard !needle.isEmpty, needle.count <= haystack.count else { return false }
            var start = 0
            while start + needle.count <= haystack.count {
                var offset = 0
                while offset < needle.count, haystack[start + offset] == needle[offset] { offset += 1 }
                if offset == needle.count { return true }
                start += 1
            }
            return false
        }
        let left = words(a)
        let right = words(b)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return run(right, in: left) || run(left, in: right)
    }

    // MARK: - The sweep

    @Test("Corpus sweep: attribution never places a device wrongly, and degrades where it cannot tell")
    func sweep() throws {
        var swept = 0
        var skippedMultiChain = 0
        var withProbes = 0
        var chainDevices = 0
        var multiDeviceChains = 0
        var absorbedTotal = 0
        var marks = 0
        var vendorMarks = 0
        var affiliateMarksRefused = 0
        var allAnchoredChains = 0
        var multiDeviceAllAnchored = 0
        var placedEndpoints = 0
        var pins: [String: String] = [:]
        // Only the m3pro_macos27.0_l/_m probe-37 pair is tracked, so these
        // are non-zero on a fresh clone or a worktree but still well below
        // what a fully-ingested primary folder sees. That is a known,
        // printed gap, not a silent one; see the non-vacuity check after the
        // loop.
        var foldersWithProbe37 = 0
        var structurallyPlacedDevices = 0

        for folder in Self.folders() {
            guard let text29 = Self.probeText(folder, "29_usb4_router_interfaces.json"),
                  let text38 = Self.probeText(folder, "38_usb_device_tree.json")
            else { continue }
            let raws = Self.rawSwitches(text29)
            let allChains = Self.chains(raws)
            var devices = Self.usbDevices(text38)
            guard !allChains.isEmpty, !devices.isEmpty else { continue }

            // Fold in probe 37's PCIe bridge depths, when the raw
            // probe is on disk. `applyBridgeDepths` is a no-op (returns
            // `devices` unchanged) when the file is absent, so the rest of
            // this sweep's assertions run identically with or without it;
            // only the ground-truth checks below and the structural-mark
            // count depend on it being present.
            if let text37 = Self.probeText(folder, "37_tb_tunnel_port_map.json") {
                let depths = Self.probe37BridgeDepths(text37)
                if !depths.isEmpty {
                    foldersWithProbe37 += 1
                    devices = Self.applyBridgeDepths(devices, depths)
                }
            }
            withProbes += 1
            guard allChains.count == 1 else { skippedMultiChain += 1; continue }
            let chain = allChains[0]
            // Flattened, because a chain node carries its children: the chain's
            // DEVICES are the flattened list, and `chain` itself is only its
            // first hops. Getting this wrong made the first run of this sweep
            // fail on the code rather than on the data.
            let chainNodes = ThunderboltTopology.flatten(chain)
            swept += 1

            let forest = USBDeviceNode.buildTree(from: devices)
            let flat = USBDeviceNode.flatten(forest)
            let result = ChainDeviceAttribution.resolve(
                chain: chain, forest: forest,
                usbTunnelSwitchUIDs: Self.usbTunnelSwitchUIDs(chainNodes: chainNodes, devices: devices)
            )

            var parentOf: [UInt64: UInt64] = [:]
            for node in flat {
                for child in node.children { parentOf[child.device.id] = node.device.id }
            }
            let chainIDs = Set(chainNodes.map(\.sw.id))
            let deviceIDs = Set(devices.map(\.id))
            chainDevices += chainNodes.count
            if chainNodes.count > 1 { multiDeviceChains += 1 }
            if result.allAnchored {
                allAnchoredChains += 1
                if chainNodes.count > 1 { multiDeviceAllAnchored += 1 }
            }
            absorbedTotal += result.absorbed.count
            marks += result.regionRoots.count
            structurallyPlacedDevices += devices.filter { $0.isThunderboltTunnelled && $0.tunnelBridgeDepth != nil }.count

            // 1. Every owner is a real chain device on THIS port, and every
            // marked or owned id is a real device.
            for (deviceID, switchID) in result.regionOwner {
                #expect(chainIDs.contains(switchID), "\(folder): owner \(switchID) is not a chain device on this port")
                #expect(deviceIDs.contains(deviceID), "\(folder): owned id \(deviceID) is not a device")
            }
            for (deviceID, switchID) in result.regionRoots {
                #expect(deviceIDs.contains(deviceID), "\(folder): marked id \(deviceID) is not a device")
                #expect(result.regionOwner[deviceID] == switchID,
                    "\(folder): device \(deviceID) is marked for \(switchID) but owned by \(String(describing: result.regionOwner[deviceID]))")
            }
            #expect(result.absorbed.isSubset(of: deviceIDs), "\(folder): absorbed an id that is not a device")

            // 2. Ownership is inheritance-consistent: a device's owner is its
            // nearest marked ancestor's mark, itself included. Walked here from
            // the forest, not read back off the result.
            for node in flat {
                var expected: Int64?
                var cursor: UInt64? = node.device.id
                while let id = cursor {
                    if let mark = result.regionRoots[id] { expected = mark; break }
                    cursor = parentOf[id]
                }
                #expect(result.regionOwner[node.device.id] == expected,
                    "\(folder): device \(node.device.id) owner \(String(describing: result.regionOwner[node.device.id])) is not its nearest mark \(String(describing: expected))")
            }

            // 3. Everything absorbed is a chain device's own identity device:
            // its product name equals one chain device's model name, or its
            // idVendor/idProduct equal one chain device's DROM numbers. Either
            // way it matches exactly one. This re-checks the absorb rule
            // against the raw values rather than trusting the resolver's own
            // matching.
            for id in result.absorbed {
                guard let device = devices.first(where: { $0.id == id }) else {
                    Issue.record("\(folder): absorbed id \(id) is not a device")
                    continue
                }
                let byName = device.productName.map { product in
                    chainNodes.filter { Self.normalise($0.sw.modelName) == Self.normalise(product) }
                } ?? []
                let byNumbers = chainNodes.filter {
                    guard device.vendorID != 0, device.productID != 0,
                          let dvid = $0.sw.dromVendorID, dvid != 0,
                          let dmid = $0.sw.dromModelID, dmid != 0
                    else { return false }
                    return dvid == Int(device.vendorID) && dmid == Int(device.productID)
                }
                #expect(byName.count == 1 || byNumbers.count == 1,
                    "\(folder): absorbed '\(device.productName ?? "?")' matches \(byName.count) chain devices by name and \(byNumbers.count) by DROM numbers, not 1 of either")
            }

            // 4. Every mark is evidence the re-derivation reproduces.
            let (structural, resolvedSwitches, refusedHere) = Self.structuralMarks(chain: chainNodes, devices: devices)
            affiliateMarksRefused += refusedHere
            // Marks production made that the re-derivation did not. Production
            // collapses redundant nested marks, so this is not a count
            // difference. Expected to stay 0: nothing guesses any more.
            vendorMarks += result.regionRoots.keys.filter { structural[$0] == nil }.count
            let everyChainDeviceResolved = resolvedSwitches.count == chainNodes.count
            #expect(result.allAnchored == everyChainDeviceResolved,
                "\(folder): allAnchored says \(result.allAnchored) but \(resolvedSwitches.count) of \(chainNodes.count) chain devices hold a region")

            // Compared as OWNERSHIP, not as mark sets. The two are not the same
            // thing: production drops a mark whose nearest marked ancestor has
            // the same owner, because inheritance already covers that subtree and
            // keeping it would render the subtree twice. `m2max_macos26.5.2_f`
            // (a CalDigit TS5, which names itself twice at two nesting levels) is
            // the real case. Ownership is what the rows are built from, so
            // ownership is what has to agree.
            var expectedOwner: [UInt64: Int64] = [:]
            func inherit(_ node: USBDeviceNode, _ inherited: Int64?) {
                let owner = structural[node.device.id] ?? inherited
                if let owner { expectedOwner[node.device.id] = owner }
                for child in node.children { inherit(child, owner) }
            }
            for root in forest { inherit(root, nil) }

            // No vendor pass exists any more, so ownership must equal the
            // oracle's on every chain, fully matched or not.
            #expect(result.regionOwner == expectedOwner,
                "\(folder): ownership differs from the evidence-only re-derivation")

            // No mark may sit under another mark for the same chain device: that
            // is the duplicate-subtree bug above, and it is only detectable here
            // as an invariant on the result.
            for (id, owner) in result.regionRoots {
                var cursor = parentOf[id]
                while let ancestor = cursor {
                    if let ancestorOwner = result.regionRoots[ancestor] {
                        #expect(ancestorOwner != owner,
                            "\(folder): device \(id) is marked for the same chain device as its ancestor \(ancestor), so its subtree would render twice")
                        break
                    }
                    cursor = parentOf[ancestor]
                }
            }

            placedEndpoints += flat.filter { !$0.device.isHub && result.regionOwner[$0.device.id] != nil }.count

            // Named pins. Folder suffix letters are positional, so these are
            // pinned by the shape they were chosen for and skipped if the shape
            // changes, rather than asserted blind.
            if folder == "m4_macos26.5.2_x", chainNodes.count == 2 {
                pins["m4_macos26.5.2_x"] = "marks=\(result.regionRoots.count) absorbed=\(result.absorbed.count)"
                #expect(Set(result.regionRoots.keys) == result.absorbed,
                    "m4_macos26.5.2_x: both chain devices name endpoints on one hub, so only the two endpoints themselves are marked")
            }
            if folder == "m5_macos26.5.1_p", chainNodes.count == 2 {
                let lan = devices.first { $0.productName?.contains("10_100_1000 LAN") == true }
                if let lan, let owner = result.regionOwner[lan.id] {
                    let name = chainNodes.first { $0.sw.id == owner }?.sw.modelName ?? "?"
                    pins["m5_macos26.5.1_p"] = "LAN owner=\(name)"
                    #expect(name.contains("Docking Station"),
                        "m5_macos26.5.1_p: the Ethernet adapter is in the dock, not the \(name)")
                }
            }

            // Structural-join ground truth: issue #493's own reporter, two independent
            // captures on the same daisy chain (Mac -> CalDigit dock -> LaCie
            // 1big -> Studio Display). Only runs when probe 37 is on disk (see
            // `foldersWithProbe37`). Devices behind the Studio Display whose
            // product name is a bare "USB2 Hub" / "USB3 Gen2 Hub" (naming
            // nothing about the display) is exactly the shape name matching
            // cannot place and the structural join exists for.
            if folder == "m3pro_macos27.0_l" || folder == "m3pro_macos27.0_m",
               devices.contains(where: { $0.tunnelBridgeDepth != nil }) {
                let laCieSwitch = chainNodes.first { $0.sw.modelName.contains("1big Dock") }
                let displaySwitch = chainNodes.first { $0.sw.modelName == "Studio Display" }
                #expect(laCieSwitch != nil, "\(folder): fixture assumption failed, no LaCie switch in the fabric")
                #expect(displaySwitch != nil, "\(folder): fixture assumption failed, no Studio Display switch in the fabric")

                let unnamedDisplayHub = devices.first {
                    $0.tunnelBridgeDepth != nil && ($0.productName == "USB2 Hub" || $0.productName == "USB3 Gen2 Hub")
                }
                if let unnamedDisplayHub, let displaySwitch {
                    pins["\(folder) structural"] = "unnamed hub owner=\(result.regionOwner[unnamedDisplayHub.id].map(String.init) ?? "nil")"
                    #expect(result.regionOwner[unnamedDisplayHub.id] == displaySwitch.sw.id,
                        "\(folder): '\(unnamedDisplayHub.productName ?? "?")' names nothing about the Studio Display, so only the structural join can place it there")
                }
                if let laCieSwitch {
                    let laCieDevices = devices.filter {
                        $0.tunnelBridgeDepth != nil && $0.productName?.hasPrefix("1big Dock") == true
                    }
                    // In this sweep the OWC Express sits at the LaCie's depth
                    // and the tunnel set is read from bridge depths, so the
                    // depth join cannot single the LaCie out, and "1big Dock..."
                    // only partly matches its model. With evidence only these
                    // devices may be unplaced, but never in another box.
                    for device in laCieDevices {
                        let owner = result.regionOwner[device.id]
                        #expect(owner == nil || owner == laCieSwitch.sw.id,
                            "\(folder): '\(device.productName ?? "?")' must never be placed outside the LaCie")
                    }
                }
            }
        }

        // Floors, only meaningful when the corpus is on disk. No probe-29 file
        // was tracked in git, so a fresh clone swept zero folders and this
        // test passed without asserting anything: a known gap, not a pass.
        // #493 added the first two tracked probe-29 fixtures
        // (m3pro_macos27.0_l / _m, for the regression test below), so a
        // fresh clone or worktree now sweeps those two and nothing else.
        // Per-folder invariants (checks 1-4 in the loop above) still run
        // against whatever is on disk, because those are correctness
        // properties that hold regardless of corpus size. The floors right
        // below make a claim about the FULL corpus, not "whatever happens to
        // be present", so they need their own stronger gate: skip (not
        // fail) when `swept` doesn't clear the same bar the floor asserts,
        // matching the skip-not-fail convention in
        // PowerSourceSynthesisProbeSweepTests / PDODecodeCorpusSweepTests.
        print("""
            [chain attribution sweep] folders with both probes: \(withProbes), swept: \(swept), \
            skipped (2+ chains, port unknowable): \(skippedMultiChain)
              chain devices: \(chainDevices), multi-device chains: \(multiDeviceChains)
              fully matched: \(allAnchoredChains) chains, of which multi-device: \(multiDeviceAllAnchored)
              marks: \(marks) (not re-derived: \(vendorMarks)), absorbed: \(absorbedTotal), \
            endpoints placed: \(placedEndpoints)
              affiliate marks refused: \(affiliateMarksRefused)
              Structural join: folders with probe 37 on disk: \(foldersWithProbe37), \
            devices carrying a bridge depth: \(structurallyPlacedDevices)
              pins: \(pins)
            """)
        guard swept >= 40 else {
            print("[chain attribution sweep] skipping full-corpus floors: only \(swept) chain(s) swept")
            return
        }
        // Non-vacuity floors. Measured on the 2026-07-30 corpus: 84 chains
        // swept, 111 chain devices, 24 multi-device chains, 23 with every chain
        // device holding a region (4 of them multi-device), 77 marks of which 46
        // vendor-derived, 30 absorbed, 145 endpoints placed, 1 conflict. Every one of those figures
        // was produced independently by a Python re-implementation over the same
        // probes first and matched exactly. Floors sit below the measurements so
        // new submissions cannot fail the build, but a resolver that quietly
        // stopped attributing anything would.
        #expect(swept >= 40, "swept only \(swept) chains; the sweep is barely covering anything")
        #expect(multiDeviceChains >= 10, "no daisy chains swept, which is the case this feature exists for")
        #expect(marks >= 20, "the structural pass placed almost nothing; it is probably broken")
        #expect(absorbedTotal >= 15, "nothing was absorbed; the exact-match rule is probably broken")
        #expect(allAnchoredChains >= 1, "no fully matched chain")
        #expect(multiDeviceAllAnchored >= 1, "no fully matched DAISY chain, which is the case the whole ticket is about")
        #expect(vendorMarks == 0, "production made \(vendorMarks) mark(s) the evidence re-derivation did not")
        // Deliberately NOT asserted: measured at 0 on the 2026-07-30 corpus. No
        // corpus machine has a chain device whose model name partly matches a
        // device an exact match already placed inside a DIFFERENT chain device, so
        // this sweep cannot catch a regression in the exact-settles-first rule.
        // Confirmed by mutation: removing that rule leaves this sweep green.
        // `affiliateMatchCannotOverrideAnExactMatch` is the only guard on it, and
        // it is a fixture for exactly that reason. If this number ever goes
        // non-zero the shape has arrived in real data and the sweep starts
        // covering it.
        #expect(skippedMultiChain < withProbes, "every folder was skipped; the sweep is vacuous")

        // Only meaningful where probe 37 is on disk. It is not a
        // tracked fixture, so a fresh clone or a worktree sees 0 here and
        // this block is skipped entirely: a known, printed gap (see the log
        // line above), not a silent pass dressed as coverage. Where it DOES
        // run (the primary folder, after ingest), it must find something,
        // or the probe-37 wiring above is dead code that happens to compile.
        if foldersWithProbe37 > 0 {
            #expect(structurallyPlacedDevices >= 1,
                "probe 37 was on disk for \(foldersWithProbe37) folder(s) but no device ever carried a bridge depth")
            #expect(pins.keys.contains { $0.hasSuffix("structural") },
                "probe 37 was on disk but the m3pro_macos27.0_l/_m ground-truth pin never ran")
        } else {
            print("[chain attribution sweep] structural join: probe 37 not on disk anywhere in the corpus copy; structural-join half of the sweep skipped")
        }
    }

    // MARK: - Grouping against physical truth (opt-in)

    /// locationID -> (idVendor, kUSBContainerID) from probe 25, the only probe
    /// that records the Container ID; probe 38 does not.
    private static func probe25ContainerIDs(_ text: String) -> [UInt32: (vendorID: UInt16, id: String)] {
        var result: [UInt32: (vendorID: UInt16, id: String)] = [:]
        var location: UInt32?
        var vendor: UInt16?
        var cid: String?
        func flush() {
            if let location, let vendor, let cid { result[location] = (vendor, cid) }
            location = nil
            vendor = nil
            cid = nil
        }
        func value(_ line: String) -> String {
            line.split(separator: "=", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("--- IOUSBHostDevice[") { flush(); continue }
            if line.hasPrefix("locationID =") {
                location = value(line).split(separator: " ").first.flatMap { UInt32($0) }
            } else if line.hasPrefix("idVendor =") {
                vendor = value(line).split(separator: " ").first.flatMap { UInt16($0) }
            } else if line.hasPrefix("kUSBContainerID =") {
                cid = value(line)
            }
        }
        flush()
        return result
    }

    /// `devices` with each one's probe-25 Container ID attached, matched by
    /// locationID and confirmed by vendor ID.
    private static func withContainerIDs(_ devices: [USBDevice], _ ids: [UInt32: (vendorID: UInt16, id: String)]) -> [USBDevice] {
        devices.map { d in
            guard let entry = ids[d.locationID], entry.vendorID == d.vendorID else { return d }
            return USBDevice(
                id: d.id, locationID: d.locationID, vendorID: d.vendorID, productID: d.productID,
                vendorName: d.vendorName, productName: d.productName, serialNumber: d.serialNumber,
                usbVersion: d.usbVersion, speedRaw: d.speedRaw, busPowerMA: d.busPowerMA, currentMA: d.currentMA,
                busIndex: d.busIndex, controllerPortName: d.controllerPortName,
                isThunderboltTunnelled: d.isThunderboltTunnelled, isBehindInternalHub: d.isBehindInternalHub,
                tunnelBridgeDepth: d.tunnelBridgeDepth, tunnelRootName: d.tunnelRootName,
                tunnelCarrier: d.tunnelCarrier, tunnelControllerRegistryPath: d.tunnelControllerRegistryPath,
                tunnelAncestorEntryIDs: d.tunnelAncestorEntryIDs, deviceClass: d.deviceClass,
                ioClassName: d.ioClassName, billboard: d.billboard, containerID: entry.id,
                rawProperties: d.rawProperties
            )
        }
    }

    /// Each chain switch's adapters, rebuilt from probe 29 the way
    /// production reads them from IOKit (`IOThunderboltSwitch.ports`). Probe
    /// 29 lists port blocks flat, with no parent switch, so they are split
    /// into runs, a new run starting at a host interface adapter, at a change
    /// of router Device ID, or at a change of a lane's Micro Route String,
    /// and each run is matched to the switch with the same Device ID and
    /// route string. A switch with no matching run, or with runs that
    /// disagree, gets no list, which is what an unpublished list is in
    /// production: the USB3 check never refuses on it.
    private static func probe29Ports(_ text: String, switches: [RawSwitch]) -> [Int64: [IOThunderboltPort]] {
        struct Run { var route: Int64?; var deviceID: Int64?; var ports: [IOThunderboltPort] }
        var runs: [Run] = []
        for (_, body) in blocks(text, className: "IOThunderboltPort") {
            let type = intValue(body, "Adapter Type") ?? -1
            let route = intValue(body, "Micro Route String")
            let deviceID = intValue(body, "Device ID")
            let last = runs.last
            let startsRun = last == nil || type == 2 || deviceID != last?.deviceID
                || (route != nil && last?.route != nil && last?.route != route)
            if startsRun { runs.append(Run(route: route, deviceID: deviceID, ports: [])) }
            if route != nil, runs[runs.count - 1].route == nil { runs[runs.count - 1].route = route }
            guard type >= 0, let number = intValue(body, "Port Number") else { continue }
            runs[runs.count - 1].ports.append(IOThunderboltPort(
                portNumber: Int(number), socketID: nil,
                adapterType: AdapterType.from(rawValue: UInt32(truncatingIfNeeded: type)),
                currentSpeed: nil, currentWidth: nil, targetWidth: nil,
                rawTargetSpeed: nil, linkBandwidthRaw: nil
            ))
        }
        var result: [Int64: [IOThunderboltPort]] = [:]
        for sw in switches where sw.depth > 0 {
            let candidates = runs.filter { $0.deviceID == sw.deviceID && $0.route == sw.routeString }
            // Probe 29 can list a switch's ports twice (once per host-root
            // walk). Duplicates must agree exactly, or the switch gets no list.
            let lists = Set(candidates.map { $0.ports.map { "\($0.portNumber):\($0.adapterType)" } })
            guard lists.count == 1, let run = candidates.first else { continue }
            result[sw.entryID] = run.ports
        }
        return result
    }

    /// The acceptance gate for evidence-only grouping, replayed over the
    /// corpus with Container IDs fed from probe 25. Opt-in: the truth table
    /// is a private, hand-checked file outside this repo, named by
    /// `WC_CHAIN_TRUTH` (tab-separated, header row, columns folder, id, ...,
    /// physical in column 8 as `B0`, `B1` or `B0|B1`). Boxes are numbered in
    /// chain order, B0 the first hop. Every chain switch counts as
    /// USB-tunnelled, the convention the truth was scored under. Each box
    /// carries its adapters from probe 29 (`probe29Ports`), so the USB3
    /// check on identity claims sees what production sees.
    ///
    /// Right: the device's box is its only physical box. Wrong: a box it is
    /// not in. Ungrouped devices are neither: they render in the port's
    /// separate section.
    @Test("Grouping gate: no device in a wrong box, at least the floor in the right one (set WC_CHAIN_TRUTH)")
    func groupingAgainstPhysicalTruth() throws {
        guard let truthPath = ProcessInfo.processInfo.environment["WC_CHAIN_TRUTH"] else { return }
        let floor = ProcessInfo.processInfo.environment["WC_CHAIN_RIGHT_FLOOR"].flatMap(Int.init) ?? 883
        var truth: [String: [Int: Set<String>]] = [:]
        for line in try String(contentsOfFile: truthPath, encoding: .utf8).split(separator: "\n").dropFirst() {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 8, let id = Int(f[1]) else { continue }
            truth[f[0], default: [:]][id] = Set(f[7].split(separator: "|").map(String.init))
        }
        try #require(!truth.isEmpty, "the truth file at \(truthPath) has no rows")

        var right = 0, wrong = 0, unknown = 0, ungrouped = 0, scored = 0
        var boxes = 0, boxesWithPorts = 0
        var wrongRows: [String] = []
        for folder in Self.folders() {
            guard let rows = truth[folder],
                  let text29 = Self.probeText(folder, "29_usb4_router_interfaces.json"),
                  let text38 = Self.probeText(folder, "38_usb_device_tree.json")
            else { continue }
            let raws = Self.rawSwitches(text29)
            let allChains = Self.chains(raws, ports: Self.probe29Ports(text29, switches: raws))
            var devices = Self.usbDevices(text38)
            guard allChains.count == 1, !devices.isEmpty else { continue }
            if let text37 = Self.probeText(folder, "37_tb_tunnel_port_map.json") {
                let depths = Self.probe37BridgeDepths(text37)
                if !depths.isEmpty { devices = Self.applyBridgeDepths(devices, depths) }
            }
            if let text25 = Self.probeText(folder, "25_usb_bos_descriptor.json") {
                devices = Self.withContainerIDs(devices, Self.probe25ContainerIDs(text25))
            }
            let chain = allChains[0]
            let chainNodes = ThunderboltTopology.flatten(chain)
            let label = Dictionary(uniqueKeysWithValues: chainNodes.enumerated().map { ($1.sw.id, "B\($0)") })
            boxes += chainNodes.count
            boxesWithPorts += chainNodes.filter { !$0.sw.ports.isEmpty }.count
            let result = ChainDeviceAttribution.resolve(
                chain: chain,
                forest: USBDeviceNode.buildTree(from: devices),
                usbTunnelSwitchUIDs: Set(chainNodes.map(\.sw.id))
            )
            for device in devices {
                guard let physical = rows[Int(device.id)] else { continue }
                scored += 1
                guard let box = result.regionOwner[device.id].flatMap({ label[$0] }) else { ungrouped += 1; continue }
                if physical == [box] {
                    right += 1
                } else if physical.contains(box) {
                    unknown += 1
                } else {
                    wrong += 1
                    wrongRows.append("\(folder) id \(device.id) in \(box), physically \(physical.sorted())")
                }
            }
        }
        print("[grouping gate] scored \(scored), right \(right), wrong \(wrong), can't tell \(unknown), separate tree \(ungrouped)")
        print("[grouping gate] boxes \(boxes), with an adapter list from probe 29 \(boxesWithPorts), without (never refuse) \(boxes - boxesWithPorts)")
        for row in wrongRows { print("[grouping gate] wrong: \(row)") }
        #expect(scored > 0, "no truth row matched a corpus folder; the corpus is not linked or the file is wrong")
        #expect(wrong == 0, "\(wrong) device(s) grouped in a wrong box")
        #expect(unknown == 0, "\(unknown) device(s) grouped where the truth cannot tell")
        #expect(right >= floor, "\(right) grouped right, below the floor of \(floor)")
    }

    // MARK: - Regression: issue #493

    /// `m3pro_macos27.0_l`: the OWC Express 1M2 (a single-port NVMe
    /// enclosure, no hub of its own) sits as a plain sibling of the CalDigit
    /// TB4 Pro Dock's shared internal "TBT4 Pro USB2.0 Hub". Its USB product
    /// name exactly matches the chain device model name "Express 1M2", so it
    /// gets absorbed and its claim looked for a parent hub to promote to.
    /// Before the fix, `claimTarget` promoted unconditionally, handing the
    /// CalDigit hub and its six descendants (the OWC device itself, a TI
    /// power chip, and four more CalDigit-branded nodes: three hub chips and
    /// one `IOUSBHostDevice`) to the OWC. The shared-hub guard never fired
    /// because only ONE chain device named the hub.
    ///
    /// **Round 4 (numeric-first): this now resolves on NUMBERS, not
    /// strings.** The OWC endpoint's own `idVendor`/`idProduct` (0x174c /
    /// 0x2465) exactly match the OWC Express 1M2 chain device's own DROM
    /// (`Device Vendor ID` / `Device Model ID`), so `claimTarget`'s numeric
    /// identity confirms the name match rather than overriding it. The
    /// CalDigit hub's own `idVendor`/`idProduct` (0x2188 / 0x5803) match no
    /// chain device's DROM exactly (the CalDigit dock's own DROM model id is
    /// 0x5988, not 0x5803: the hub is one of the dock's internal chips), so
    /// tier (a)/(b) do not fire; the hub's VID (0x2188) does equal the
    /// CalDigit dock's DROM vendor id, a DIFFERENT chain device from the OWC
    /// (0x174c), so tier (c) refuses the promotion. The vendor-name STRING
    /// tier (d) is never reached at all for this folder.
    ///
    /// Proven red on the unfixed code: temporarily reverting `claimTarget`'s
    /// #493 change (both the round-3 string-only rule and, separately, the
    /// round-4 numeric rule) and running this test failed with the CalDigit
    /// hub owned by the OWC's switch id, exactly the bug. See the PR
    /// description for the captured failure output.
    @Test("Regression #493: a lone claim over a shared dock hub is not promoted to it")
    func regression493SharedDockHubNotClaimedByLoneDevice() throws {
        let folder = "m3pro_macos27.0_l"
        guard let text29 = Self.probeText(folder, "29_usb4_router_interfaces.json"),
              let text38 = Self.probeText(folder, "38_usb_device_tree.json")
        else {
            // Raw probes are gitignored except for tracked replay fixtures.
            // This folder's 29 + 38 are tracked specifically so this
            // regression replays on a fresh clone; if they are ever missing,
            // skip rather than silently pass on the wrong premise.
            Issue.record("\(folder): probe 29 or 38 fixture missing; #493 regression cannot replay")
            return
        }
        let raws = Self.rawSwitches(text29)
        let allChains = Self.chains(raws)
        let devices = Self.usbDevices(text38)
        try #require(allChains.count == 1, "\(folder): expected exactly one Thunderbolt chain")
        let chain = allChains[0]
        let chainNodes = ThunderboltTopology.flatten(chain)
        let forest = USBDeviceNode.buildTree(from: devices)
        let flat = USBDeviceNode.flatten(forest)

        let owcSwitch = try #require(
            chainNodes.first { $0.sw.modelName == "Express 1M2" },
            "\(folder): expected an 'Express 1M2' chain device"
        )
        let owcDevice = try #require(
            devices.first { $0.productName == "Express 1M2" },
            "\(folder): expected an 'Express 1M2' USB device"
        )
        let hubNode = try #require(
            flat.first { $0.device.id == owcDevice.id }.flatMap { owc in
                flat.first { $0.children.contains(where: { $0.device.id == owc.device.id }) }
            },
            "\(folder): expected the Express 1M2 to have a parent hub node"
        )
        #expect(hubNode.device.productName == "TBT4 Pro USB2.0 Hub")
        #expect(hubNode.device.vendorName?.contains("CalDigit") == true)

        // The descendants the bug drags along with the hub. Asserted
        // non-empty FIRST: without this, every negative assertion below
        // (nothing under the hub is owned by the OWC) would pass vacuously
        // on a resolver, or a probe fixture, that produced no attribution at
        // all, or on a fixture whose hub happens to have no children.
        let hubDescendants = USBDeviceNode.flatten(hubNode.children).filter { $0.device.id != owcDevice.id }
        try #require(!hubDescendants.isEmpty,
            "\(folder): expected the CalDigit hub to have descendants besides the OWC device; the fixture may have changed shape")

        let result = ChainDeviceAttribution.resolve(chain: chain, forest: forest)

        // Positive: the OWC device itself IS owned by, and absorbed into, its
        // own switch's region. This is the exact-match/absorb rule working as
        // intended, and it is what makes the negative checks below meaningful
        // rather than a resolver that attributed nothing at all.
        #expect(result.absorbed.contains(owcDevice.id),
            "\(folder): the OWC's own identity endpoint must be absorbed into its chain device")
        #expect(result.regionOwner[owcDevice.id] == owcSwitch.sw.id,
            "\(folder): the OWC's own identity endpoint must be owned by its own switch id")

        // Positive: the CalDigit hub's final state, asserted explicitly
        // rather than only "not the OWC". The fixed code leaves it UNOWNED,
        // not reattributed to the CalDigit dock: an identity claim places
        // only the identity device, so the OWC's claim never reaches the
        // hub, and nothing on this fabric independently claims the
        // hub FOR the CalDigit dock either (the dock's own identity endpoint
        // sits on a different hub). An unowned hub is the file's documented
        // fail-closed behaviour: "when the evidence does not single out one
        // chain device, the device stays unattributed."
        #expect(result.regionOwner[hubNode.device.id] == nil,
            "\(folder): the CalDigit hub must be unowned, not reattributed to anyone")
        #expect(
            result.regionOwner[hubNode.device.id] != owcSwitch.sw.id,
            "\(folder): the CalDigit hub must not be claimed by the OWC's switch id \(owcSwitch.sw.id)"
        )
        // The OWC device itself is excluded: it IS meant to be owned by its
        // own switch id (that is the absorb rule working correctly, checked
        // positively above). The bug this guards against is everything ELSE
        // under the shared hub, e.g. the other CalDigit hub chips and the TI
        // power chip, being dragged along with it.
        for descendant in hubDescendants {
            #expect(
                result.regionOwner[descendant.device.id] != owcSwitch.sw.id,
                "\(folder): CalDigit hub descendant \(descendant.device.productName ?? "?") must not be attributed to the OWC's switch id \(owcSwitch.sw.id)"
            )
        }
    }

    // MARK: - TB5 Gen T shared-controller tunnel-hub mapping

    /// Corpus-replay sweep for the new pass specifically. Runs
    /// `ChainDeviceAttribution.resolveTB5TunnelHubMap` DIRECTLY (not just
    /// through `resolve()`) over every single-chain folder, so a folder
    /// where the pass fires (returns a non-empty bijection) is unambiguous:
    /// it is by construction a folder whose attribution is NEW relative to
    /// pre-TB5-pass production, since nothing else in `ChainDeviceAttribution`
    /// ever placed these anonymous Intel tunnel hubs before this pass
    /// existed (spec section 1: name, inheritance and vendor continuity all
    /// fail to place them). That makes "the pass fired" and "old vs new
    /// differ for this folder" the same fact here, without needing to run
    /// two builds of production side by side.
    ///
    /// Floor (spec section 8 phase 4): the sweep must find the 5 known
    /// route-byte points named in the ticket evidence
    /// (the private notes (tree-attribution, TICKET.md): byte 3 -> port 1
    /// x3, byte 5 -> port 2, byte 7 -> port 3), so a silent regression in
    /// the pass cannot pass as a clean "found nothing" run.
    @Test("TB5 corpus sweep: the TB5 tunnel-hub pass fires on known folders and never wrongly")
    func tb5TunnelHubMapSweep() throws {
        var swept = 0
        var passFired = 0
        var hubsMapped = 0
        var hubsAttributedInFullResult = 0
        var perFolderDiff: [String] = []
        var knownRouteBytePoints: Set<String> = []

        for folder in Self.folders() {
            guard let text29 = Self.probeText(folder, "29_usb4_router_interfaces.json"),
                  let text38 = Self.probeText(folder, "38_usb_device_tree.json")
            else { continue }
            let raws = Self.rawSwitches(text29)
            let allChains = Self.chains(raws)
            var devices = Self.usbDevices(text38)
            guard allChains.count == 1, !devices.isEmpty else { continue }

            if let text37 = Self.probeText(folder, "37_tb_tunnel_port_map.json") {
                let depths = Self.probe37BridgeDepths(text37)
                if !depths.isEmpty { devices = Self.applyBridgeDepths(devices, depths) }
            }

            let chain = allChains[0]
            let chainNodes = ThunderboltTopology.flatten(chain)
            guard chainNodes.count >= 2 else { continue } // needs a real daisy chain
            swept += 1

            let forest = USBDeviceNode.buildTree(from: devices)
            // Known plumbing gap, documented rather than hidden: this
            // sweep's `usbTunnelSwitchUIDs(chainNodes:devices:)` helper
            // (shared with the main `sweep()` test) derives from probe 37's
            // PCIe BRIDGE depth, which production never uses for the
            // scope gate either, and which is structurally unable to name
            // 2+ switches sharing ONE tunnelled controller anyway: every
            // device behind a SHARED controller reports the SAME bridge
            // depth (that IS the bug this pass exists to fix), so
            // `switchIDByDepth` can only ever resolve ONE depth bucket from
            // it, undercounting exactly the shape this test needs to
            // exercise. Production's real signal is hop-table-derived
            // (`ThunderboltTopology.tunnels(...).filter { $0.kind == .usb
            // }`), which needs per-port `Hop Table` parsing this sweep does
            // not do (`model()` never populates `ports`). Rather than
            // silently under-testing the scope gate, this passes every
            // chain switch as "confirmed" for a 2+-switch chain: the scope
            // gate's OWN pass/fail correctness is covered at the unit-test
            // level (`tb5ScopeGateClosedWithoutEitherSignal` /
            // `tb5GenTAdapterAloneOpensScopeGate`), so this sweep is free to
            // focus on what it CAN validate against real data: the
            // route-byte arithmetic, the candidate/silicon gate, and the
            // isomorphism walk.
            let usbTunnelSwitchUIDs = chainNodes.count >= 2 ? Set(chainNodes.map(\.sw.id)) : []

            guard let hubMap = ChainDeviceAttribution.resolveTB5TunnelHubMap(
                chainNodes: chainNodes, forest: forest, usbTunnelSwitchUIDs: usbTunnelSwitchUIDs
            ), !hubMap.isEmpty else { continue }

            passFired += 1
            hubsMapped += hubMap.count
            perFolderDiff.append("\(folder): \(hubMap.count) hub(s) newly mapped by the TB5 pass")

            // The 5 known route-byte points (spec: verified on 5 independent
            // corpus/live points, byte 3 -> port 1 x3, byte 5 -> port 2,
            // byte 7 -> port 3). Recorded by (folder, routeByte) so the
            // floor assertion below can check every named point actually
            // replays, not just that SOME folder fired.
            for node in chainNodes where node.sw.depth >= 1 {
                let shift = 8 * (node.sw.depth - 1)
                guard shift < 64 else { continue }
                let byte = (node.sw.routeString >> shift) & 0xFF
                if byte == 3 || byte == 5 || byte == 7 {
                    knownRouteBytePoints.insert("\(folder):\(byte)")
                }
            }

            // No folder may produce a hub claimed against its OWN
            // name/numeric evidence: cross-check every mapped hub that also
            // carries a product name against the SAME exact-name rule
            // production's `resolve()` uses. Independent re-derivation
            // (normalise + exact string compare), not a call into
            // production's `normalized`/`affiliated`.
            let result = ChainDeviceAttribution.resolve(
                chain: chain, forest: forest, usbTunnelSwitchUIDs: usbTunnelSwitchUIDs
            )
            for (hubID, mappedSwitchID) in hubMap {
                guard let hubDevice = devices.first(where: { $0.id == hubID }) else { continue }
                if let product = hubDevice.productName, Self.normalise(product).count >= 3 {
                    let exactNameMatches = chainNodes.filter { Self.normalise($0.sw.modelName) == Self.normalise(product) }
                    if exactNameMatches.count == 1, let namedSwitchID = exactNameMatches.first?.sw.id {
                        #expect(
                            namedSwitchID == mappedSwitchID || result.regionOwner[hubID] != mappedSwitchID,
                            "\(folder): hub \(hubID) has an exact name match to switch \(namedSwitchID) but the TB5 pass placed it under \(mappedSwitchID) in the final result, contradicting its own name"
                        )
                    }
                }
                if result.regionOwner[hubID] == mappedSwitchID {
                    hubsAttributedInFullResult += 1
                }
                // Every mapped switch id is a real chain switch on this port
                // (defence against a stale/foreign id leaking through).
                #expect(chainNodes.contains { $0.sw.id == mappedSwitchID },
                    "\(folder): TB5 pass mapped hub \(hubID) to switch \(mappedSwitchID), which is not on this port's chain")
            }
        }

        print("""
            [TB5 tunnel-hub sweep] daisy chains swept: \(swept), pass fired: \(passFired), \
            hubs newly mapped: \(hubsMapped), of which reflected in the final result: \(hubsAttributedInFullResult)
              known route-byte points replayed: \(knownRouteBytePoints.sorted())
              per-folder diff (every folder whose attribution changed vs. pre-TB5-pass production):
            \(perFolderDiff.sorted().map { "    \($0)" }.joined(separator: "\n"))
            """)

        guard swept >= 5 else {
            // Review fix: this used to return silently in both cases (no
            // corpus at all, or a corpus present but suspiciously thin),
            // which is the "green from no data looks identical to green
            // from good data" trap the house rules call out. The two cases
            // are now told apart: a genuinely absent corpus (no `research`
            // symlink, matching every sibling sweep's skip-not-fail
            // convention, e.g. `PowerSourceSynthesisProbeSweepTests`) still
            // skips quietly, but a corpus that IS on disk failing to clear
            // 5 daisy chains is a FAILURE, not a skip: this checkout's
            // corpus sweeps 37 (verified by running this test before this
            // fix), so 5 is a safe floor, and a run that swept fewer than
            // that on a present corpus means something upstream broke, not
            // that the corpus is merely small.
            if Self.folders().isEmpty {
                print("[TB5 tunnel-hub sweep] skipping floor: no corpus on disk (research symlink missing?)")
                return
            }
            Issue.record("[TB5 tunnel-hub sweep] corpus is present (\(Self.folders().count) folder(s)) but only \(swept) daisy chain(s) swept, below the 5-chain floor")
            return
        }
        // Floor: the pass must fire at least once (a clean "found nothing"
        // run must not pass silently), and at least one of the named
        // route-byte points from the ticket evidence must replay. Not all 5
        // named points are guaranteed present in every corpus snapshot
        // (folder suffix letters are positional and the corpus keeps
        // growing), so this checks the SHAPE of the evidence (known byte
        // values appear somewhere) rather than an exact count.
        #expect(passFired >= 1, "the TB5 tunnel-hub pass never fired on real corpus data; it is probably broken or the gate is too strict")
        #expect(hubsMapped >= 2, "the pass fired but mapped almost nothing")
        let observedBytes = Set(knownRouteBytePoints.map { $0.split(separator: ":").last.map(String.init) ?? "" })
        #expect(observedBytes.contains("3"), "byte 3 -> hub port 1 is the reference machine's own shape and must replay")
        // Byte 7 -> hub port 3 is present in this corpus snapshot via
        // `m2max_macos26.5.2_f` (verified: this folder's own edge carries
        // route byte 7, printed in `knownRouteBytePoints` above), so it is
        // asserted alongside byte 3 rather than left as an unchecked extra
        // data point. Byte 5 -> hub port 2 is NOT asserted here: it is
        // spec-verified from live-desk evidence (section 2 point 3 of
        // the private design note "TB5 tunnel-hub attribution"), but this
        // corpus snapshot's tracked single-active-port subset carries no
        // folder whose edge presents a route byte of 5 (checked: this run's
        // `knownRouteBytePoints` never contains a `:5` entry), so asserting
        // it here would either fail on every checkout or silently pass
        // vacuously depending on `swept`. Revisit once a byte-5 folder is
        // ingested.
        #expect(observedBytes.contains("7"), "byte 7 -> hub port 3 (m2max_macos26.5.2_f) is in this corpus snapshot and must replay")
    }
}
