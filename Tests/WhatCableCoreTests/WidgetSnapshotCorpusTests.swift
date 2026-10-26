import Foundation
import Testing
@testable import WhatCableCore

/// Corpus-replay sweep for `WidgetSnapshot.init(from cable: CableSnapshot)`
/// (`Sources/WhatCableCore/Snapshot/WidgetSnapshot.swift`), the conversion the
/// widget extension's live-read timeline provider uses to turn a `CableSnapshot`
/// into the small, pre-computed shape the widget decodes without touching IOKit.
///
/// Builds a `CableSnapshot` per corpus folder from probe 01 (`AppleHPMInterface`
/// ports + `USBPDSOP` identities), reusing the same parsing approach as the
/// other probe-01 sweeps in this target (a deliberate copy per file; see
/// `DataLinkDiagnosticCIOCorpusTests`'s doc comment for why `private` helpers
/// aren't shared across files). Every other `CableSnapshot` field
/// (`usbDevices`, `thunderboltSwitches`, `displayPorts`, etc.) is left at its
/// default empty/nil value: this sweep is only reconstructing enough of a
/// snapshot to drive the conversion function itself, not every downstream
/// signal it can optionally use (the same documented scope as
/// `PortSummaryCorpusSweepTests`, which this file's per-port assertions
/// cross-check against directly).
@Suite("WidgetSnapshot(from: CableSnapshot): corpus sweep")
struct WidgetSnapshotCorpusTests {

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

    // MARK: - Probe 01: ports
    // Copied from DataLinkDiagnosticCIOCorpusTests.ProbePort / loadPorts (same
    // target).

    private struct ProbePort {
        let serviceName: String
        let portTypeDescription: String?
        let portNumber: Int
        let transportsSupported: [String]
        let transportsActive: [String]
        let connectionActive: Bool

        var asAppleHPMInterface: AppleHPMInterface {
            AppleHPMInterface(
                id: UInt64(portNumber),
                serviceName: serviceName,
                className: portTypeDescription == "MagSafe 3"
                    ? "AppleTCControllerType11"
                    : "AppleTCControllerType10",
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
                powerCurrentLimits: [],
                firmwareVersion: nil,
                bootFlagsHex: nil,
                rawProperties: [:]
            )
        }
    }

    private static func loadPorts(folder: String) -> [ProbePort] {
        guard let text = loadProbeText(folder: folder, probe: "01_walk_pd_tree") else { return [] }

        let rawChunks = text.components(separatedBy: "=== IOAccessoryManager[")
        guard rawChunks.count > 1 else { return [] }
        let parts: [String] = rawChunks.dropFirst().compactMap { chunk in
            guard let endOfHeader = chunk.range(of: "===\n") else { return nil }
            return String(chunk[endOfHeader.upperBound...])
        }

        var ports: [ProbePort] = []
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

            ports.append(ProbePort(
                serviceName: serviceName,
                portTypeDescription: portType,
                portNumber: portNumber,
                transportsSupported: supp,
                transportsActive: act,
                connectionActive: conn
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

            let vendorID = firstMatch(#"Vendor ID = \d+ \(0x([0-9a-fA-F]+)\)"#, in: block)
                .flatMap { Int($0, radix: 16) } ?? 0

            let vdos = allMatches(#"\[\d+\] <data 4 bytes: ([0-9a-fA-F ]+)>"#, in: block)
                .map { bytes -> UInt32 in
                    let parts = bytes.split(separator: " ").compactMap { UInt32($0, radix: 16) }
                    return parts.reversed().reduce(UInt32(0)) { ($0 << 8) | $1 }
                }

            result.append(USBPDSOP(
                id: UInt64(result.count),
                endpoint: endpoint,
                parentPortType: 0,
                parentPortNumber: portNumber,
                vendorID: vendorID,
                productID: 0,
                bcdDevice: 0,
                vdos: vdos,
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

    private static func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    // MARK: - One CableSnapshot per folder

    private struct SnapshotCase {
        let folder: String
        let cable: CableSnapshot
    }

    private static let snapshotCases: [SnapshotCase] = {
        var result: [SnapshotCase] = []
        for folder in allFolders() {
            let probePorts = loadPorts(folder: folder)
            guard !probePorts.isEmpty else { continue }
            let ports = probePorts.map(\.asAppleHPMInterface)
            let ids = identities(folder: folder)
            let cable = CableSnapshot(
                ports: ports,
                powerSources: [],
                identities: ids,
                usbDevices: [],
                adapter: nil
            )
            result.append(SnapshotCase(folder: folder, cable: cable))
        }
        return result
    }()

    // MARK: - Coverage floor
    //
    // Measured directly against the corpus snapshot at the time this sweep
    // was written (410 folders, full raw corpus hard-linked into this
    // worktree): 410 folders produce a non-empty CableSnapshot (every folder
    // in the corpus has at least one USB-C or MagSafe port in its probe-01
    // walk). Floor = 85% of 410, rounded down: 410 * 0.85 = 348.5 -> 348.
    //
    // Unlike the CIO-specific sweeps, this floor does NOT skip on a fresh
    // clone: probe 01 (`01_walk_pd_tree.json`) is the one distillation
    // committed to git for every folder, so `snapshotCases` is never empty.
    private static let coverageFloor = 348

    // MARK: - Tests

    @Test("Coverage: the corpus has enough folders to exercise WidgetSnapshot(from:)")
    func coverageFloorHolds() {
        #expect(Self.snapshotCases.count >= Self.coverageFloor,
            "Expected at least \(Self.coverageFloor) folders producing a CableSnapshot (85% of the 410 counted when this sweep was written); found \(Self.snapshotCases.count).")
    }

    @Test("No crash: WidgetSnapshot(from:) handles every real corpus CableSnapshot")
    func noCrashAcrossCorpus() {
        for c in Self.snapshotCases {
            _ = WidgetSnapshot(from: c.cable)
        }
        // Reaching this line for every case means none of them crashed.
        #expect(Bool(true))
    }

    @Test("Invariant: every port in the snapshot produces exactly one PortEntry")
    func onePortEntryPerPort() {
        // Source: `let entries: [PortEntry] = cable.ports.map { port in ... }`,
        // a 1:1 map with no filtering. `builtInDisplayEntries` is separate and
        // additive; with `displayPorts` empty in this sweep (see type doc),
        // `BuiltInDisplayPort.group(from: [])` must contribute nothing, so
        // the total should equal `cable.ports.count` exactly.
        for c in Self.snapshotCases {
            let widget = WidgetSnapshot(from: c.cable)
            #expect(widget.ports.count == c.cable.ports.count,
                "\(c.folder): expected \(c.cable.ports.count) PortEntry values (one per port, no built-in display entries expected with empty displayPorts), got \(widget.ports.count)")
        }
    }

    @Test("Invariant: status/headline/icon agree with an independently-built PortSummary for the same port")
    func statusAndHeadlineMatchPortSummary() {
        // Cross-checks the conversion itself: WidgetSnapshot.init(from:) is
        // documented to build a PortSummary per port with the same inputs
        // (isLive resolved via isPortLive, then PortSummary(port:sources:
        // identities:devices:...)). This test rebuilds that same PortSummary
        // independently (matching identities to the port the same way
        // PortSummaryCorpusSweepTests does) and asserts WidgetSnapshot's
        // per-entry headline/status did not diverge from it.
        var examined = 0
        for c in Self.snapshotCases {
            let widget = WidgetSnapshot(from: c.cable)
            for (port, entry) in zip(c.cable.ports, widget.ports) {
                examined += 1
                let matchedIDs = c.cable.identities.filter { $0.canonicallyMatches(port: port) }
                let isLive = isPortLive(
                    port: port, powerSources: [], identities: matchedIDs,
                    matchingDevices: [], chargerAttached: false
                )
                let summary = PortSummary(
                    port: port,
                    identities: matchedIDs,
                    isConnectedOverride: isLive
                )
                #expect(entry.headline == summary.headline,
                    "\(c.folder) port \(port.serviceName): WidgetSnapshot headline '\(entry.headline)' != PortSummary headline '\(summary.headline)'")
                #expect(entry.status == WidgetSnapshot.Status(from: summary.status),
                    "\(c.folder) port \(port.serviceName): WidgetSnapshot status \(entry.status) != mapped PortSummary status \(summary.status)")
            }
        }
        #expect(examined > 0, "No (port, entry) pairs were examined; the sweep exercised nothing")
    }

    @Test("Total status/icon mapping: every WidgetSnapshot.Status maps to a non-empty SF Symbol name")
    func everyStatusHasAnIcon() {
        // Not corpus-dependent (there are only 7 cases), but included here
        // rather than as a separate unit test file since it directly
        // supports this sweep's "status/icon mapping total" requirement:
        // every case of the enum this file exercises against real data must
        // also resolve to a usable icon.
        let all: [WidgetSnapshot.Status] = [.empty, .charging, .batteryFull, .dataDevice, .thunderboltCable, .displayCable, .unknown]
        for status in all {
            #expect(!status.iconName.isEmpty, "\(status) has no icon name")
        }
    }
}
