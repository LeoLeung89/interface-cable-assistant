import Foundation
import Testing
@testable import WhatCableCore

/// Corpus-replay sweep for issue #393: the Thunderbolt controller's CIO
/// negotiated-link-speed reading is a FLOOR on cable capability, never a cap.
/// A genuine 80 Gbps cable between two 40 Gbps endpoints negotiates 40, but
/// it is still an 80 Gbps cable; `DataLinkDiagnostic` must never report the
/// cable as capable of less than its own e-marker claims just because the
/// live link happened to run slower.
///
/// The #393 logic is already unit-tested against synthetic fixtures in
/// `DataLinkDiagnosticTests.swift`. This file feeds it real e-marker
/// identities (from probe 01's SOP'/SOP'' Discover Identity blocks) and real
/// CIO cable-capability data (from probes 17/19's `IOPortTransportStateCIO`
/// blocks) for every port in the corpus where both are present, and asserts
/// the #393 invariants against the diagnostic's OUTPUT rather than
/// hand-built inputs.
///
/// ## Parsing-reuse note (duplication is intentional)
///
/// Swift `private` is file-scoped, so a `private` helper in one file is not
/// visible from another even inside the same target, and some of the
/// originals live in a *different* test target altogether. Rather than make
/// those helpers `internal` (which would widen their API for one caller),
/// this file copies the parsing approach from three existing corpus sweeps
/// so it feeds `DataLinkDiagnostic` the same shapes production does:
///
/// - Probe-01 port loading: copied from `DataLinkDiagnosticProbeSweepTests`
///   (this target, `Tests/WhatCableCoreTests`) and `CIOAndDataLinkCorpusTests`
///   (`Tests/WhatCableDarwinTests`), which both parse the same
///   `01_walk_pd_tree.json` shape identically.
/// - Probe-01 SOP identity parsing (vendor ID, raw VDO bytes, endpoint,
///   parent port number): copied from `CableTrustProbeSweepTests` (this
///   target), which already decodes real VDO bytes into `USBPDSOP`.
/// - CIO block extraction (`=== ClassName ===` deep-dive style and
///   `--- ClassName[N] ---` flat-services style): copied from
///   `CIOAndDataLinkCorpusTests` (`Tests/WhatCableDarwinTests`). That file
///   then turns a block into a `CIOCableCapability` via
///   `TRMTransportWatcher.makeCIOCapability`, which lives in
///   `WhatCableDarwinBackend`. This target (`WhatCableCoreTests`) only
///   depends on `WhatCableCore` (see `Package.swift`), so that conversion is
///   reimplemented here directly against `CIOCableCapability`'s public
///   initializer, replicating `TRMTransportWatcher.parentPortIdentity`'s
///   portKey derivation (`ParentBuiltInPortType`/`Number`, falling back to
///   `ParentPortType`/`Number`) so the portKey shape matches production.
///
/// ## Truncation-awareness
///
/// Probe 17 is captured with a 64KB cap and is truncated mid-dump in roughly
/// 10% of folders (`corpus.jsonl`'s per-folder `truncated` field is the
/// authoritative record of which). A truncated capture can cut a block off
/// before its closing `=== ` / `--- ` marker. `parseEqualsBlocks` handles
/// this the same defensive way the original does: when no closing section
/// marker is found, it caps the block body at a generous fixed window
/// instead of reading to the literal end of the (possibly garbage-tailed)
/// string, so a chopped-off final block still yields whatever complete
/// key/value lines it captured before the cut, rather than misreading
/// whatever partial bytes follow it.
@Suite("DataLinkDiagnostic — CIO / e-marker corpus sweep (issue #393)")
struct DataLinkDiagnosticCIOCorpusTests {

    // MARK: - Probe root

    private static let probeRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WhatCableCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("research/customer-probes")
    }()

    private static func allProbeFolders() -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: probeRoot.path) else { return [] }
        return entries.filter { entry in
            var isDir: ObjCBool = false
            let path = probeRoot.appendingPathComponent(entry).path
            FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            return isDir.boolValue
        }.sorted()
    }

    /// True when the corpus's raw (gitignored) probe files are present on
    /// disk. A fresh clone only carries the committed `01_walk_pd_tree.json`
    /// per folder; probes 17/19 are gitignored raw data that must be
    /// re-fetched from the KV store. Mirrors
    /// `TransportWatcherSweepTests.hasTransportProbeFiles()`'s convention:
    /// tests below skip their minimum-count assertions (but not their
    /// per-case invariants, which simply have nothing to iterate over) when
    /// this is false.
    private static func hasCIOProbeFiles() -> Bool {
        for folder in allProbeFolders().prefix(10) {
            for probe in ["17_deep_property_dump", "19_pdo_decode_and_usb3_watch"] {
                let url = probeRoot.appendingPathComponent(folder).appendingPathComponent("\(probe).json")
                if FileManager.default.fileExists(atPath: url.path) { return true }
            }
        }
        return false
    }

    // MARK: - Probe text loader

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
    // Copied from DataLinkDiagnosticProbeSweepTests.ProbePort / loadPorts
    // (same target) -- see the type-level doc comment for why this is a
    // copy rather than a shared internal helper.

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
    // Copied from CableTrustProbeSweepTests.identities (same target) -- the
    // one existing corpus parser that already decodes real VDO bytes into
    // USBPDSOP, which is exactly what DataLinkDiagnostic's `identities:`
    // parameter needs.

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
                    // Little-endian: "01 2b e0 05" -> 0x05e02b01
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

    // MARK: - Probes 17/19: CIO block extraction
    // Copied from CIOAndDataLinkCorpusTests (Tests/WhatCableDarwinTests) --
    // see the type-level doc comment for why (different test target, no
    // WhatCableDarwinBackend dependency here).

    private static func parseEqualsBlocks(text: String, className: String) -> [[String: Any]] {
        let header = "=== \(className) ==="
        var blocks: [[String: Any]] = []
        var searchFrom = text.startIndex
        while let range = text.range(of: header, range: searchFrom..<text.endIndex) {
            let bodyStart = range.upperBound
            let rest = String(text[bodyStart...])
            let body: String
            if let nextSection = rest.range(of: "\n=== ") ?? rest.range(of: "\n--- ") {
                body = String(rest[..<nextSection.lowerBound])
            } else {
                // Truncation-awareness: a probe-17 capture chopped off at the
                // 64KB cap can end mid-block, with no closing section marker
                // to find. Cap the scan at a generous fixed window rather
                // than reading to the literal end of string, so a truncated
                // final block still yields whatever complete key/value
                // lines it captured before the cut.
                body = String(rest.prefix(2000))
            }
            blocks.append(parseProperties(body: body, indent: "    "))
            searchFrom = range.upperBound
        }
        return blocks
    }

    private static func parseDashBlocks(text: String, classPrefix: String) -> [[String: Any]] {
        let escapedPrefix = NSRegularExpression.escapedPattern(for: classPrefix)
        guard let regex = try? NSRegularExpression(
            pattern: "--- \(escapedPrefix)\\[\\d+\\] ---")
        else { return [] }
        let nsText = text as NSString
        let headerMatches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var blocks: [[String: Any]] = []
        for (i, match) in headerMatches.enumerated() {
            let bodyStart = match.range.upperBound
            let bodyEnd = i + 1 < headerMatches.count
                ? headerMatches[i + 1].range.lowerBound
                : nsText.length
            var body = nsText.substring(with: NSRange(location: bodyStart, length: bodyEnd - bodyStart))
            for sep in ["\n---", "\n==="] {
                if let r = body.range(of: sep) { body = String(body[..<r.lowerBound]) }
            }
            blocks.append(parseProperties(body: body, indent: "  "))
        }
        return blocks
    }

    private static func parseProperties(body: String, indent: String) -> [String: Any] {
        var props: [String: Any] = [:]
        let deeper = indent + " "
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            guard s.hasPrefix(indent), !s.hasPrefix(deeper) else { continue }
            let stripped = String(s.dropFirst(indent.count))
            guard let colonRange = stripped.range(of: ": ") else { continue }
            let key = String(stripped[..<colonRange.lowerBound])
            let valStr = String(stripped[colonRange.upperBound...])
            if valStr == "true" {
                props[key] = NSNumber(value: true)
            } else if valStr == "false" {
                props[key] = NSNumber(value: false)
            } else if valStr.hasPrefix("\""), valStr.hasSuffix("\""), valStr.count >= 2 {
                props[key] = String(valStr.dropFirst().dropLast())
            } else if let m = parseIntLiteral(valStr) {
                props[key] = NSNumber(value: m)
            }
        }
        return props
    }

    private static func parseIntLiteral(_ s: String) -> Int? {
        if let spaceIdx = s.firstIndex(of: " ") {
            if let v = Int(s[..<spaceIdx]) { return v }
        }
        return Int(s)
    }

    private static func extractCIOBlocks(text: String) -> [[String: Any]] {
        var blocks = parseEqualsBlocks(text: text, className: "IOPortTransportStateCIO")
        blocks += parseDashBlocks(text: text, classPrefix: "IOPortTransportStateCIO")
        return blocks
    }

    /// Turn a parsed CIO property dict into a `CIOCableCapability`.
    ///
    /// Not copied from `TRMTransportWatcher.makeCIOCapability` (it lives in
    /// `WhatCableDarwinBackend`, which this target does not depend on).
    /// Reimplemented directly against `CIOCableCapability`'s public
    /// initializer, replicating `TRMTransportWatcher.parentPortIdentity`'s
    /// portKey derivation exactly: prefer `ParentBuiltInPortType`/`Number`,
    /// fall back to `ParentPortType`/`Number`, then a `Priority`-low-byte
    /// fallback for the port number, so the portKey shape (`"2/1"` etc.)
    /// matches what production joins against.
    private static func cioCapability(entryID: UInt64, props: [String: Any]) -> CIOCableCapability {
        let type = (props["ParentBuiltInPortType"] as? NSNumber)?.intValue
            ?? (props["ParentPortType"] as? NSNumber)?.intValue
            ?? 0
        let number = (props["ParentBuiltInPortNumber"] as? NSNumber)?.intValue
            ?? (props["ParentPortNumber"] as? NSNumber)?.intValue
            ?? Int(((props["Priority"] as? NSNumber)?.uint64Value ?? 0) & 0xFF)

        return CIOCableCapability(
            id: entryID,
            portKey: "\(type)/\(number)",
            cableGeneration: (props["CableGeneration"] as? NSNumber)?.intValue,
            negotiatedLinkSpeed: (props["CableSpeed"] as? NSNumber)?.intValue,
            generation: (props["Generation"] as? NSNumber)?.intValue,
            asymmetricModeSupported: (props["AsymmetricModeSupported"] as? NSNumber)?.boolValue,
            legacyAdapter: (props["LegacyAdapter"] as? NSNumber)?.boolValue,
            linkTrainingMode: (props["LinkTrainingMode"] as? NSNumber)?.intValue
        )
    }

    // MARK: - Matched (port, e-marker, CIO) cases

    /// One real-world case where a physical USB-C port has BOTH a decodable
    /// SOP'/SOP'' e-marker (Cable VDO present, `vdos.count > 3`) AND an
    /// active CIO capability reading for that same port. This overlap is
    /// exactly what #393 is about: what the diagnostic does when both
    /// signals are present and may disagree.
    private struct MatchedCase {
        let folder: String
        let portKey: String
        let hpm: AppleHPMInterface
        let identity: USBPDSOP
        let cio: CIOCableCapability
    }

    /// Computed once (cached in a `static let`, safe under this package's
    /// Swift 5.9 language mode) rather than per-test, since every test below
    /// walks the same ~410-folder corpus and re-parsing per test would
    /// multiply the I/O for no benefit.
    private static let matchedCases: [MatchedCase] = computeMatchedCases()

    private static func computeMatchedCases() -> [MatchedCase] {
        var cases: [MatchedCase] = []
        for folder in allProbeFolders() {
            let ports = loadPorts(folder: folder)
            guard !ports.isEmpty else { continue }

            let text17 = loadProbeText(folder: folder, probe: "17_deep_property_dump") ?? ""
            let text19 = loadProbeText(folder: folder, probe: "19_pdo_decode_and_usb3_watch") ?? ""
            let cioProps = extractCIOBlocks(text: text17) + extractCIOBlocks(text: text19)
            guard !cioProps.isEmpty else { continue }

            let ids = identities(folder: folder)

            for (i, props) in cioProps.enumerated() {
                // Only a CIO block whose "Active" flag is true describes a
                // live link at capture time; a stale/inactive block isn't a
                // real reading to attribute to the port. Mirrors the
                // production `activeTBGbps` gate's intent (a live TB link
                // must actually be up), just read directly off the probe
                // instead of via switch-topology correlation (not available
                // to this corpus sweep -- see the tbActiveGbps test seam
                // used below).
                guard (props["Active"] as? NSNumber)?.boolValue == true else { continue }

                let cio = cioCapability(entryID: UInt64(1000 + i), props: props)
                let parts = cio.portKey.split(separator: "/")
                guard let portNumber = parts.last.flatMap({ Int($0) }) else { continue }

                guard let port = ports.first(where: {
                    $0.portTypeDescription == "USB-C"
                        && $0.portNumber == portNumber
                        && $0.connectionActive
                        && $0.transportsActive.contains("CIO")
                }) else { continue }

                guard let emarker = ids.first(where: {
                    ($0.endpoint == .sopPrime || $0.endpoint == .sopDoublePrime)
                        && $0.parentPortNumber == portNumber
                        && $0.vdos.count > 3
                }) else { continue }

                cases.append(MatchedCase(
                    folder: folder,
                    portKey: cio.portKey,
                    hpm: port.asAppleHPMInterface,
                    identity: emarker,
                    cio: cio
                ))
            }
        }
        return cases
    }

    // MARK: - Coverage floor
    //
    // Measured directly from this Swift parser against the corpus snapshot
    // at the time this sweep was written (410 folders, full raw corpus
    // hard-linked into this worktree): 98 folders produce at least one
    // MatchedCase (an active CIO block whose port also has a decodable
    // SOP'/SOP'' e-marker), for 216 total MatchedCase instances across the
    // corpus. (A rougher Python prototype of the same matching logic, used
    // to sanity-check the approach before writing this file, counted 96
    // folders / 213 cases; the small difference is expected from parser
    // detail -- e.g. which of SOP'/SOP'' wins when both are decodable for a
    // port -- and the number actually asserted below is this file's own
    // Swift count, not the prototype's.)
    //
    // Floor = 85% of 216, rounded down: 216 * 0.85 = 183.6 -> 183.
    //
    // A worktree without the raw corpus (only 01_walk_pd_tree.json
    // committed) has 0 CIO-bearing folders; that case is handled by
    // `hasCIOProbeFiles()` skipping this assertion entirely, not by the
    // floor number itself.
    private static let coverageFloor = 183

    // MARK: - Tests

    @Test("Coverage: the corpus has enough matched e-marker+CIO cases to exercise #393")
    func coverageFloorHolds() {
        guard Self.hasCIOProbeFiles() else { return }
        let cases = Self.matchedCases
        #expect(cases.count >= Self.coverageFloor,
            "Expected at least \(Self.coverageFloor) matched e-marker+CIO cases (85% of the 213 counted when this sweep was written); found \(cases.count). A drop this large means the corpus shrank or the parsing regressed, not normal noise.")
    }

    @Test("#393 floor invariant: resolved cable capability is never below the e-marker's own claim")
    func cableCapabilityNeverBelowEmarkerClaim() {
        guard Self.hasCIOProbeFiles() else { return }
        let cases = Self.matchedCases
        guard !cases.isEmpty else {
            Issue.record("No matched e-marker+CIO cases found on disk; the #393 floor invariant is untested by this sweep (corpus likely not fetched into this worktree)")
            return
        }

        var examined = 0
        var violations: [(folder: String, portKey: String, emarkerGbps: Double, cableGbps: Double)] = []

        for c in cases {
            let diag = DataLinkDiagnostic(
                port: c.hpm,
                identities: [c.identity],
                devices: [],
                usb3Transports: [],
                cio: c.cio,
                thunderboltSwitches: [],
                // Test seam: this sweep has no real Thunderbolt switch
                // topology to resolve the live link rate from (that would
                // need a separate switch-graph parser). The active rate is
                // instead set to what CIO itself measured
                // (negotiatedLinkSpeed): both readings describe the same
                // underlying negotiated link, just via two different
                // registry paths in production. Using one to stand in for
                // the other here does not touch the #393 comparison under
                // test, which is the e-marker's claim vs
                // `cio.negotiatedLinkSpeed`, not vs `active`.
                tbActiveGbps: DataLinkDiagnostic.cioCableGbps(c.cio.negotiatedLinkSpeed)
            )
            guard let diag else { continue }
            examined += 1

            guard let emarkerGbps = diag.facts.cableEmarkerGbps else { continue }
            guard let cableGbps = diag.facts.cableGbps else {
                violations.append((c.folder, c.portKey, emarkerGbps, -1))
                continue
            }
            // The floor rule under test: a CIO reading below the e-marker's
            // claim must never pull the resolved cable figure down with it.
            // facts.cableGbps must always be at least the e-marker's own
            // (possibly ambiguity-corrected) claim.
            if cableGbps < emarkerGbps * 0.999 {
                violations.append((c.folder, c.portKey, emarkerGbps, cableGbps))
            }
        }

        if !violations.isEmpty {
            let detail = violations.map {
                $0.cableGbps < 0
                    ? "\($0.folder) port \($0.portKey): e-marker claims \($0.emarkerGbps) Gbps but facts.cableGbps is nil"
                    : "\($0.folder) port \($0.portKey): e-marker claims \($0.emarkerGbps) Gbps but resolved cableGbps is only \($0.cableGbps) Gbps"
            }.joined(separator: "\n")
            Issue.record("#393 FLOOR VIOLATION in \(violations.count) real corpus case(s) -- the CIO floor pulled the resolved cable capability below the e-marker's own claim:\n\(detail)")
        }
        #expect(violations.isEmpty,
            "\(violations.count) real corpus case(s) show the CIO floor capping cable capability below the e-marker's claim (issue #393 regression)")
        #expect(examined > 0, "No cases produced a non-nil DataLinkDiagnostic; the sweep exercised nothing")
    }

    @Test("#393 confirmation: when CIO measures at least the e-marker's claim, the diagnostic reflects agreement/confirmation")
    func cioConfirmsWhenMeasuredAtOrAboveClaim() {
        guard Self.hasCIOProbeFiles() else { return }
        let cases = Self.matchedCases

        var confirmedExamined = 0
        for c in cases {
            guard let cioGbps = DataLinkDiagnostic.cioCableGbps(c.cio.negotiatedLinkSpeed) else { continue }
            guard let rawEmarkerGbps = c.identity.cableVDO?.speed.maxGbps else { continue }
            // Only the "measured >= claimed" side of the tiebreak: same tier
            // (agreement) or CIO strictly higher (issue #111 direction).
            guard cioGbps >= rawEmarkerGbps || DataLinkDiagnostic.sameTier(cioGbps, rawEmarkerGbps) else { continue }

            let diag = DataLinkDiagnostic(
                port: c.hpm,
                identities: [c.identity],
                devices: [],
                usb3Transports: [],
                cio: c.cio,
                thunderboltSwitches: [],
                tbActiveGbps: cioGbps
            )
            guard let diag else { continue }
            confirmedExamined += 1

            #expect(diag.facts.cableControllerGbps == cioGbps,
                "\(c.folder) port \(c.portKey): facts.cableControllerGbps should pass the CIO reading through unchanged")
            guard let cableGbps = diag.facts.cableGbps else {
                Issue.record("\(c.folder) port \(c.portKey): CIO measured \(cioGbps) Gbps (>= the e-marker's \(rawEmarkerGbps) Gbps claim), but facts.cableGbps is nil instead of reflecting confirmation")
                continue
            }
            #expect(cableGbps >= rawEmarkerGbps * 0.999,
                "\(c.folder) port \(c.portKey): confirmed cableGbps (\(cableGbps)) should be at least the e-marker's claim (\(rawEmarkerGbps))")
        }
        if confirmedExamined == 0 {
            Issue.record("No corpus cases had CIO measuring at or above the e-marker's claim; the confirmation-side #393 invariant is untested by this sweep")
        }
    }

    @Test("No crash / nil-safety: DataLinkDiagnostic handles every real e-marker+CIO combination in the corpus")
    func noCrashAcrossAllCombinations() {
        guard Self.hasCIOProbeFiles() else { return }
        let cases = Self.matchedCases

        for c in cases {
            // Exercise both the no-override path (activeTBGbps resolves via
            // the empty switch array, i.e. nil -> the diagnostic abstains)
            // and the CIO-derived-active-rate path used by the two tests
            // above, covering the two code paths a real corpus reading
            // could reach through this sweep.
            _ = DataLinkDiagnostic(
                port: c.hpm, identities: [c.identity], devices: [], usb3Transports: [],
                cio: c.cio, thunderboltSwitches: []
            )
            let diag = DataLinkDiagnostic(
                port: c.hpm, identities: [c.identity], devices: [], usb3Transports: [],
                cio: c.cio, thunderboltSwitches: [],
                tbActiveGbps: DataLinkDiagnostic.cioCableGbps(c.cio.negotiatedLinkSpeed)
            )
            if let diag {
                #expect(diag.facts.activeGbps > 0,
                    "\(c.folder) port \(c.portKey): activeGbps should be positive when a diagnostic is produced")
            }
        }
        // Reaching this line for every case means none of them crashed.
        #expect(Bool(true))
    }
}
