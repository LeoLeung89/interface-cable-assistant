import Foundation
import Testing
@testable import WhatCableCore

/// Corpus-replay sweep for two small, previously-untested `WhatCableCore`
/// helpers that both read directly off probe 01 (the PD-tree walk):
///
/// - `isPortLive(port:powerSources:identities:matchingDevices:chargerAttached:)`
///   (`Sources/WhatCableCore/Port/PortLiveness.swift`)
/// - `DisplayPortLaneConfig.init(usb3Active:rawPinAssignment:)`
///   (`Sources/WhatCableCore/Display/DisplayPortLaneConfig.swift`)
///
/// ## `isPortLive` scope note
///
/// Real callers (`ContentView.matchingDevices(for:)`) resolve `matchingDevices`
/// via a locationID/`controllerPortName` walk that needs live IOKit data no
/// flat probe dump carries (the same limitation documented in
/// `Probe38TreeWalkTests` and `InternalHubPIDCorpusTests`). This sweep always
/// passes `matchingDevices: []` and `powerSources: []`, and restricts itself
/// to USB-C ports (skipping MagSafe, whose liveness rule additionally depends
/// on `chargerAttached`, a system-wide adapter reading this sweep has no real
/// value for). That leaves two of `isPortLive`'s five branches exercisable
/// against real data: the `!identities.isEmpty` branch and the non-MagSafe
/// `connectionActive == true` branch. Both are checked below by name against
/// the source's own logic, not invented.
@Suite("isPortLive + DisplayPortLaneConfig: corpus sweep")
struct PortLivenessAndLaneConfigTests {

    private static let probeRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WhatCableCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("research/customer-probes")
    }()

    private static func allFolders() -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: probeRoot.path) else { return [] }
        return entries.filter { entry in
            var isDir: ObjCBool = false
            let path = probeRoot.appendingPathComponent(entry).path
            FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            return isDir.boolValue
        }.sorted()
    }

    private static func loadProbeText(folder: String, probe: String) -> String? {
        let url = probeRoot.appendingPathComponent(folder).appendingPathComponent("\(probe).json")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let text = root["output"] as? String
        else { return nil }
        return text
    }

    // MARK: - Probe 01: per-port blocks
    //
    // Same block-splitting approach as the other probe-01 sweeps in this
    // target (DataLinkDiagnosticCIOCorpusTests / CableTrustProbeSweepTests /
    // PortSummaryCorpusSweepTests), copied rather than shared because
    // `private` is file-scoped. This copy keeps the raw body text (needed
    // for `DisplayPortPinAssignment`, which none of the existing `ProbePort`
    // copies expose) instead of narrowing to a fixed struct.

    private struct ProbePortBlock {
        let serviceName: String
        let portTypeDescription: String?
        let portNumber: Int
        let transportsSupported: [String]
        let transportsActive: [String]
        let connectionActive: Bool
        /// Raw `DisplayPortPinAssignment` value. Corpus samples show this
        /// field emitted two different ways across machines/OS builds: as an
        /// integer (`0 (0x0)`) or as a bare boolean (`true`). Since
        /// `DisplayPortLaneConfig` only keeps this value for reference (see
        /// its type doc / issue #228) and never derives `assignment` from it,
        /// this sweep tolerates both shapes and normalises to 0 for the
        /// boolean form rather than guessing a meaningless integer.
        let rawPinAssignment: Int

        var asAppleHPMInterface: AppleHPMInterface {
            AppleHPMInterface(
                id: UInt64(portNumber),
                serviceName: serviceName,
                className: "AppleHPMInterfaceType10",
                portDescription: serviceName,
                portTypeDescription: portTypeDescription,
                portNumber: portNumber,
                connectionActive: connectionActive,
                activeCable: nil,
                opticalCable: nil,
                usbActive: nil,
                superSpeedActive: nil,
                usbModeType: nil,
                usbConnectString: nil,
                transportsSupported: transportsSupported,
                transportsActive: transportsActive,
                transportsProvisioned: [],
                plugOrientation: nil,
                plugEventCount: nil,
                connectionCount: nil,
                overcurrentCount: nil,
                pinConfiguration: [:],
                displayPortPinAssignment: rawPinAssignment,
                powerCurrentLimits: [],
                firmwareVersion: nil,
                bootFlagsHex: nil,
                rawProperties: [:]
            )
        }
    }

    private static func loadPorts(folder: String) -> [ProbePortBlock] {
        guard let text = loadProbeText(folder: folder, probe: "01_walk_pd_tree") else { return [] }

        let rawChunks = text.components(separatedBy: "=== IOAccessoryManager[")
        guard rawChunks.count > 1 else { return [] }
        let parts: [String] = rawChunks.dropFirst().compactMap { chunk in
            guard let endOfHeader = chunk.range(of: "===\n") else { return nil }
            return String(chunk[endOfHeader.upperBound...])
        }

        var ports: [ProbePortBlock] = []
        for raw in parts {
            let body: String
            if let endRange = raw.range(of: "\n=== ") {
                body = String(raw[..<endRange.lowerBound])
            } else {
                body = raw
            }
            guard body.contains("PortTypeDescription") else { continue }

            let portType = parseQuoted(body, key: "PortTypeDescription")
            let serviceName = parseQuoted(body, key: "Description") ?? "Port-Unknown@0"
            let portNumber = parseInt(body, key: "PortNumber") ?? 0
            let supp = parseList(body, key: "TransportsSupported")
            let act = parseList(body, key: "TransportsActive")
            let conn = body.contains("ConnectionActive = true")
            let pinRaw = parsePinAssignment(body)

            ports.append(ProbePortBlock(
                serviceName: serviceName,
                portTypeDescription: portType,
                portNumber: portNumber,
                transportsSupported: supp,
                transportsActive: act,
                connectionActive: conn,
                rawPinAssignment: pinRaw
            ))
        }
        return ports
    }

    private static func parseQuoted(_ block: String, key: String) -> String? {
        let prefix = "    \(key) = \""
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(prefix) {
                let after = line.dropFirst(prefix.count)
                guard let closing = after.firstIndex(of: "\"") else { return nil }
                return String(after[..<closing])
            }
        }
        return nil
    }

    private static func parseInt(_ block: String, key: String) -> Int? {
        let prefix = "    \(key) = "
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(prefix) {
                let after = line.dropFirst(prefix.count)
                let digits = after.prefix { $0.isNumber }
                return Int(digits)
            }
        }
        return nil
    }

    private static func parseList(_ block: String, key: String) -> [String] {
        let opener = "    \(key) = ["
        guard let openRange = block.range(of: opener) else { return [] }
        let afterOpen = block[openRange.upperBound...]
        guard let close = afterOpen.range(of: "\n    ]") else { return [] }
        let inside = afterOpen[..<close.lowerBound]
        return inside.split(separator: "\n").compactMap { line -> String? in
            guard let q1 = line.firstIndex(of: "\""),
                  let q2 = line.lastIndex(of: "\""), q1 != q2 else { return nil }
            return String(line[line.index(after: q1)..<q2])
        }
    }

    private static func parsePinAssignment(_ block: String) -> Int {
        let prefix = "    DisplayPortPinAssignment = "
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix(prefix) else { continue }
            let after = line.dropFirst(prefix.count)
            let digits = after.prefix { $0.isNumber }
            if let v = Int(digits) { return v }
            return 0 // boolean-shaped value ("true"/"false"); see ProbePortBlock doc.
        }
        return 0
    }

    // MARK: - Probe 01: SOP identities
    // Copied from CableTrustProbeSweepTests.identities (same target).

    private static func identities(folder: String) -> [USBPDSOP] {
        guard let text = loadProbeText(folder: folder, probe: "01_walk_pd_tree") else { return [] }

        var result: [USBPDSOP] = []
        let blocks = text.components(separatedBy: "=== ").dropFirst()
        for block in blocks {
            guard block.contains("CCUSBPDSOP") else { continue }

            let endpoint: USBPDSOP.Endpoint
            if let name = firstMatch(#"Name:\s+(\S+)"#, in: block) {
                switch name {
                case "SOP": endpoint = .sop
                case "SOP'": endpoint = .sopPrime
                case "SOP''": endpoint = .sopDoublePrime
                default: endpoint = .unknown
                }
            } else {
                continue
            }

            let portNumber = firstMatch(#"Description = "Port-USB-C@(\d+)/CC"#, in: block)
                .flatMap { Int($0) } ?? 0

            result.append(USBPDSOP(
                id: UInt64(result.count),
                endpoint: endpoint,
                parentPortType: 0,
                parentPortNumber: portNumber,
                vendorID: 0,
                productID: 0,
                bcdDevice: 0,
                vdos: [],
                specRevision: 3
            ))
        }
        return result
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard
            let re = try? NSRegularExpression(pattern: pattern),
            let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            m.numberOfRanges > 1,
            let r = Range(m.range(at: 1), in: text)
        else { return nil }
        return String(text[r])
    }

    // MARK: - isPortLive corpus cases (USB-C ports only; see type doc)

    private struct LivenessCase {
        let folder: String
        let port: AppleHPMInterface
        let matchedIdentities: [USBPDSOP]
    }

    private static let livenessCases: [LivenessCase] = {
        var result: [LivenessCase] = []
        for folder in allFolders() {
            let ports = loadPorts(folder: folder)
            guard !ports.isEmpty else { continue }
            let ids = identities(folder: folder)
            for port in ports where port.portTypeDescription == "USB-C" {
                let matched = ids.filter { $0.parentPortNumber == port.portNumber }
                result.append(LivenessCase(folder: folder, port: port.asAppleHPMInterface, matchedIdentities: matched))
            }
        }
        return result
    }()

    // MARK: - DisplayPortLaneConfig corpus cases: every USB-C port block
    // anywhere in the corpus whose TransportsActive includes "DisplayPort".

    private struct LaneConfigCase {
        let folder: String
        let usb3Active: Bool
        let rawPinAssignment: Int
    }

    private static let laneConfigCases: [LaneConfigCase] = {
        var result: [LaneConfigCase] = []
        for folder in allFolders() {
            for port in loadPorts(folder: folder) where port.transportsActive.contains("DisplayPort") {
                result.append(LaneConfigCase(
                    folder: folder,
                    usb3Active: port.transportsActive.contains("USB3"),
                    rawPinAssignment: port.rawPinAssignment
                ))
            }
        }
        return result
    }()

    // MARK: - Coverage floors
    //
    // Measured directly against the corpus snapshot at the time this sweep
    // was written (410 folders, full raw corpus hard-linked into this
    // worktree):
    //   - 1115 USB-C `isPortLive` cases (every USB-C port block in the
    //     corpus, connected or not -- unlike PortSummaryCorpusSweepTests,
    //     which counts only connected ports). Floor = 85% of 1115, rounded
    //     down: 1115 * 0.85 = 947.75 -> 947.
    //   - 153 DisplayPort-active port blocks. Floor = 85% of 153, rounded
    //     down: 153 * 0.85 = 130.05 -> 130.
    private static let livenessFloor = 947
    private static let laneConfigFloor = 130

    // MARK: - Tests: isPortLive

    @Test("Coverage: enough USB-C ports to exercise isPortLive")
    func livenessCoverageFloorHolds() {
        #expect(Self.livenessCases.count >= Self.livenessFloor,
            "Expected at least \(Self.livenessFloor) USB-C isPortLive cases (85% of 1115 counted when this sweep was written); found \(Self.livenessCases.count).")
    }

    @Test("Invariant: a decoded SOP/SOP'/SOP'' identity on this port always reads live")
    func identityImpliesLive() {
        // Source: `if !identities.isEmpty { return true }` -- the very first
        // check in isPortLive, unconditional on connectionActive.
        var examined = 0
        var violations: [String] = []
        for c in Self.livenessCases where !c.matchedIdentities.isEmpty {
            examined += 1
            let live = isPortLive(
                port: c.port, powerSources: [], identities: c.matchedIdentities,
                matchingDevices: [], chargerAttached: false
            )
            if !live { violations.append("\(c.folder) port \(c.port.serviceName)") }
        }
        if examined == 0 {
            Issue.record("No corpus port had a matched SOP identity; this invariant is untested by this sweep")
        }
        #expect(violations.isEmpty,
            "\(violations.count) port(s) with a decoded identity read as not-live: \(violations.prefix(5))")
    }

    @Test("Invariant: connectionActive == true on a non-MagSafe port always reads live")
    func connectionActiveImpliesLive() {
        // Source: `if !isMagSafe && port.connectionActive == true { return true }`.
        // Every case here is already USB-C (never MagSafe, see type doc).
        var examined = 0
        var violations: [String] = []
        for c in Self.livenessCases where c.port.connectionActive == true {
            examined += 1
            let live = isPortLive(
                port: c.port, powerSources: [], identities: [],
                matchingDevices: [], chargerAttached: false
            )
            if !live { violations.append("\(c.folder) port \(c.port.serviceName)") }
        }
        if examined == 0 {
            Issue.record("No corpus port had connectionActive == true; this invariant is untested by this sweep")
        }
        #expect(violations.isEmpty,
            "\(violations.count) connected port(s) read as not-live: \(violations.prefix(5))")
    }

    @Test("Invariant: no signal at all (disconnected, no identity, no power source) reads not-live")
    func noSignalReadsNotLive() {
        // Negative-space check: with matchingDevices/powerSources forced
        // empty by this sweep's scope (see type doc), a disconnected port
        // with no matched identity has nothing left in isPortLive's guard
        // chain to return true from.
        var examined = 0
        var violations: [String] = []
        for c in Self.livenessCases where c.port.connectionActive != true && c.matchedIdentities.isEmpty {
            examined += 1
            let live = isPortLive(
                port: c.port, powerSources: [], identities: [],
                matchingDevices: [], chargerAttached: false
            )
            if live { violations.append("\(c.folder) port \(c.port.serviceName)") }
        }
        if examined == 0 {
            Issue.record("No corpus port was disconnected with no identity; this invariant is untested by this sweep")
        }
        #expect(violations.isEmpty,
            "\(violations.count) port(s) with no live signal at all still read as live: \(violations.prefix(5))")
    }

    // MARK: - Tests: DisplayPortLaneConfig

    @Test("Coverage: enough DisplayPort-active port blocks to exercise DisplayPortLaneConfig")
    func laneConfigCoverageFloorHolds() {
        #expect(Self.laneConfigCases.count >= Self.laneConfigFloor,
            "Expected at least \(Self.laneConfigFloor) DisplayPort-active port blocks (85% of 153 counted when this sweep was written); found \(Self.laneConfigCases.count).")
    }

    @Test("Invariant: lane assignment is always 2 or 4 lanes and matches usb3Active")
    func laneConfigMatchesUSB3Active() {
        var sawTwoLane = false
        var sawFourLane = false
        for c in Self.laneConfigCases {
            let config = DisplayPortLaneConfig(usb3Active: c.usb3Active, rawPinAssignment: c.rawPinAssignment)
            switch config.assignment {
            case .twoLane:
                sawTwoLane = true
                #expect(c.usb3Active, "\(c.folder): twoLane config but usb3Active was false")
            case .fourLane:
                sawFourLane = true
                #expect(!c.usb3Active, "\(c.folder): fourLane config but usb3Active was true")
            }
        }
        // Not a vacuous sweep: the real corpus contains both shapes (a dock
        // running DP-alongside-USB3 and a display-only DP link), so both
        // branches of the ternary are actually exercised by real data.
        #expect(sawTwoLane, "Expected at least one real corpus case with usb3Active alongside DisplayPort")
        #expect(sawFourLane, "Expected at least one real corpus case with DisplayPort alone (no USB3)")
    }
}
