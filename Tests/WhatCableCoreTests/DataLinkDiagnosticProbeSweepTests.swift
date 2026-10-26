import Foundation
import Testing
@testable import WhatCableCore

/// Property-style sweep over every customer probe under
/// `research/customer-probes/`. Validates the issue #195 fix against the
/// real-world IORegistry shapes we already have on file rather than
/// against a single hand-built fixture. Catches the within-controller
/// socket-ID collision class that the #159 verification pass missed.
@Suite("Data Link Diagnostic — customer probe sweep")
struct DataLinkDiagnosticProbeSweepTests {

    // MARK: - Probe loader

    /// Repo root, located via `#filePath` the same way LocalisationTests
    /// does. Tests read from the source tree so a new probe just needs
    /// to be dropped under `research/customer-probes/` to be picked up.
    private static let probeRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WhatCableCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("research/customer-probes")
    }()

    /// One IOAccessoryManager entry extracted from a probe's PD-tree walk.
    /// Only the fields the diagnostic actually reads are populated; the
    /// rest stay nil/empty.
    private struct ProbePort {
        let probe: String
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

    /// Parse a single probe directory's 01_walk_pd_tree.json output.
    /// Returns every IOAccessoryManager block as a ProbePort. Robust to
    /// both `AppleTCControllerType*` (M1/M2) and `AppleHPMInterfaceType*`
    /// (M3+) naming.
    private static func loadPorts(probe: String) throws -> [ProbePort] {
        let url = probeRoot
            .appendingPathComponent(probe)
            .appendingPathComponent("01_walk_pd_tree.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = root["output"] as? String
        else { return [] }

        // Split the text on the IOAccessoryManager block header. Each
        // resulting chunk runs until the next `=== ` section header.
        // The block index varies (`[0]`, `[1]`, ...); split on the prefix
        // and trim the index/closing-bracket off the leading line of
        // each chunk.
        let rawChunks = text.components(separatedBy: "=== IOAccessoryManager[")
        guard rawChunks.count > 1 else { return [] }
        // Drop the prefix-only first chunk; for each remaining chunk,
        // strip everything up to the closing "===\n" of its own header.
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
            let serviceName = parseQuoted(body, key: "Description")
                ?? "Port-Unknown@0"
            let portNumber = parseInt(body, key: "PortNumber") ?? 0
            let supp = parseList(body, key: "TransportsSupported")
            let act = parseList(body, key: "TransportsActive")
            let conn = body.contains("ConnectionActive = true")

            ports.append(ProbePort(
                probe: probe,
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

    /// Returns [] when the corpus root itself is absent (e.g. a worktree that
    /// hasn't hard-linked the corpus in), the same guard shape
    /// TransportWatcherSweepTests.allProbeFolders() uses. Note this does NOT
    /// make this file's tests skip gracefully like that sibling's do: the
    /// three callers below still assert hard count floors (`probes.count >
    /// 20`, `rows >= 100`, etc.) that fail when the corpus is absent. The
    /// guard's only effect is turning what would otherwise be an uncaught
    /// thrown NSError (from `contentsOfDirectory` on a missing path) into a
    /// clean, readable failed #expect instead -- arguably clearer, but still
    /// a failure, not a skip.
    private static func allProbes() -> [String] {
        guard FileManager.default.fileExists(atPath: probeRoot.path) else { return [] }
        guard let entries = try? FileManager.default
            .contentsOfDirectory(atPath: probeRoot.path) else { return [] }
        return entries.filter { entry in
            var isDir: ObjCBool = false
            let path = probeRoot.appendingPathComponent(entry).path
            FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            return isDir.boolValue
        }.sorted()
    }

    // MARK: - Field parsers (mirror the offline catalogue extractor)

    /// Line-based field parsers. The probe text uses a fixed
    /// `    KEY = VALUE` indentation; we walk lines looking for an exact
    /// `    \(key) = ` prefix. This avoids cross-field bleed where a
    /// non-anchored regex would pick up `PortDescription` for `Description`
    /// or `ParentBuiltInPortTypeDescription` for `PortTypeDescription`.
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

    // MARK: - Switch fixture

    /// A minimal host TB switch with one active lane port at the given
    /// socket suffix and the given supportedSpeed mask. Mirrors what the
    /// catch-22 case in #195 actually looked like on the real M2 MBA:
    /// MagSafe @1 colliding with USB-C @1, both finding a 40 Gbps lane
    /// on the same host root.
    private static func makeHostSwitch(socketID: String, supportedRaw: UInt8) -> IOThunderboltSwitch {
        let lane = IOThunderboltPort(
            portNumber: 1,
            socketID: socketID,
            adapterType: .lane,
            currentSpeed: .usb4Tb4,
            currentWidth: LinkWidth(rawValue: 0x2),
            targetWidth: nil,
            rawTargetSpeed: nil,
            linkBandwidthRaw: nil
        )
        return IOThunderboltSwitch(
            id: 100,
            className: "IOThunderboltSwitchType5",
            vendorID: 1452,
            vendorName: "Apple Inc.",
            modelName: "Mac",
            routerID: 0,
            depth: 0,
            routeString: 0,
            upstreamPortNumber: 0,
            maxPortNumber: 8,
            supportedSpeed: SupportedSpeedMask(rawValue: supportedRaw),
            ports: [lane],
            parentSwitchUID: nil
        )
    }

    // MARK: - Tests

    @Test("Every customer-probe MagSafe row returns nil (issue #195)")
    func everyMagSafeReturnsNil() throws {
        let probes = Self.allProbes()
        #expect(probes.count > 20, "Expected many customer probes; found \(probes.count)")

        var magSafeRowsExamined = 0
        var collisions = 0
        for probe in probes {
            let ports = try Self.loadPorts(probe: probe)
            let magSafePorts = ports.filter { $0.portTypeDescription == "MagSafe 3" }
            if magSafePorts.isEmpty { continue }

            for ms in magSafePorts {
                magSafeRowsExamined += 1

                // Suffix collision: every customer-probe MagSafe in the
                // dataset shares its @N with the first USB-C port.
                let suffix = String(ms.serviceName.split(separator: "@").last ?? "")
                let sharedSuffix = ports.contains { p in
                    p.portTypeDescription == "USB-C"
                        && p.serviceName.hasSuffix("@" + suffix)
                }
                if sharedSuffix { collisions += 1 }

                // Build the exact adversarial setup the old diagnostic
                // would have leaked through: a host TB switch for the
                // colliding socket suffix, with a 40 Gbps lane.
                let host = Self.makeHostSwitch(socketID: suffix, supportedRaw: 0xC)
                let diag = DataLinkDiagnostic(
                    port: ms.asAppleHPMInterface,
                    identities: [],
                    devices: [],
                    usb3Transports: [],
                    cio: nil,
                    thunderboltSwitches: [host]
                )
                #expect(diag == nil,
                    "Probe \(probe): MagSafe port \(ms.serviceName) should not produce a data-link verdict (carriesData gate)")
            }
        }

        #expect(magSafeRowsExamined >= 50,
            "Expected at least 50 MagSafe rows in the customer-probe set; found \(magSafeRowsExamined)")
        #expect(collisions == magSafeRowsExamined,
            "Every MagSafe row in the dataset shares an @N suffix with a USB-C port (\(magSafeRowsExamined) total); only \(collisions) collisions were observed, which would indicate the catalogue or the dataset has changed shape")
    }

    @Test("Every USB-C row in the probe set has carriesData true")
    func everyUSBCCarriesData() throws {
        // Symmetry check for the carriesData gate: every real USB-C port
        // in the dataset advertises at least one data transport in
        // TransportsSupported. If this ever fires, the gate would
        // over-refuse legitimate ports.
        let probes = Self.allProbes()
        var rows = 0
        for probe in probes {
            let ports = try Self.loadPorts(probe: probe)
            for p in ports where p.portTypeDescription == "USB-C" {
                rows += 1
                #expect(p.asAppleHPMInterface.carriesData,
                    "Probe \(probe): USB-C port \(p.serviceName) reports TransportsSupported=\(p.transportsSupported), which the carriesData gate would refuse")
            }
        }
        #expect(rows >= 100, "Expected at least 100 USB-C rows in the customer-probe set; found \(rows)")
    }

    @Test("Connected USB-C ports without USB3 or CIO transport do not produce a TB verdict")
    func usbOnlyPortsAbstainFromTBVerdict() throws {
        // Real-world coverage for the bigskookum-shape: a USB-C port
        // that's connected, has data capability, but isn't running USB3
        // or TB right now. The new activeTBGbps gate (requires
        // transportsActive.contains("CIO")) keeps the always-up internal
        // root lane from being attributed to the user's cable. Without
        // an honest active rate, the diagnostic should abstain.
        let probes = Self.allProbes()
        var examined = 0
        for probe in probes {
            let ports = try Self.loadPorts(probe: probe)
            for p in ports where p.portTypeDescription == "USB-C"
                              && p.connectionActive
                              && !p.transportsActive.contains("USB3")
                              && !p.transportsActive.contains("CIO") {
                examined += 1

                let suffix = String(p.serviceName.split(separator: "@").last ?? "")
                let host = Self.makeHostSwitch(socketID: suffix, supportedRaw: 0xC)
                let diag = DataLinkDiagnostic(
                    port: p.asAppleHPMInterface,
                    identities: [],
                    devices: [],
                    usb3Transports: [],
                    cio: nil,
                    thunderboltSwitches: [host]
                )
                #expect(diag == nil,
                    "Probe \(probe): USB-C port \(p.serviceName) is connected with TransportsActive=\(p.transportsActive) but no USB3/CIO; the diagnostic should not pick up a TB lane rate from the internal root lane")
            }
        }
        // Most probe captures will have at least one such port; if none
        // are present, the new gate is untested by this sweep but other
        // tests still cover it.
        if examined == 0 {
            Issue.record("No connected USB-C ports without USB3/CIO found in the probe set; the activeTBGbps gate is not exercised by this sweep")
        }
    }

    // MARK: - Host-to-host replay: probe loader

    private static func loadProbeText(folder: String, probe: String) -> String? {
        let url = probeRoot.appendingPathComponent(folder).appendingPathComponent("\(probe).json")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let text = root["output"] as? String
        else { return nil }
        return text
    }

    // MARK: - Host-to-host replay: probe 01 SOP identities (duplicated from DataLinkDiagnosticVerdictReplayTests)

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

    // MARK: - Host-to-host replay: probes 17/19 CIO blocks (duplicated from DataLinkDiagnosticVerdictReplayTests, plus Metadata and TunneledTransportsProvisioned)

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
                // A capture chopped at the 64KB cap can end mid-block.
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

    /// Scalar lines at exactly `indent`, plus two shapes the copied parser
    /// skipped: `Key: {` (a dictionary, read as its nested `key: value`
    /// lines) and `Key: [` (a list of quoted strings). Both stop at the
    /// closing bracket at `indent`. Reading stops at the first nested
    /// `=== ` header so a child transport's own `Metadata` is never read
    /// as the row's.
    private static func parseProperties(body: String, indent: String) -> [String: Any] {
        var props: [String: Any] = [:]
        let deeper = indent + " "
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < lines.count {
            let s = lines[i]
            i += 1
            if s.trimmingCharacters(in: .whitespaces).hasPrefix("=== ") { break }
            guard s.hasPrefix(indent), !s.hasPrefix(deeper) else { continue }
            let stripped = String(s.dropFirst(indent.count))
            guard let colonRange = stripped.range(of: ": ") else { continue }
            let key = String(stripped[..<colonRange.lowerBound])
            let valStr = String(stripped[colonRange.upperBound...])
            if valStr == "{" || valStr == "[" {
                let closer = indent + (valStr == "{" ? "}" : "]")
                var inner: [String] = []
                while i < lines.count, lines[i] != closer {
                    inner.append(lines[i])
                    i += 1
                }
                i += 1
                if valStr == "{" {
                    var dict: [String: String] = [:]
                    for line in inner where line.hasPrefix(deeper + " ") && !line.hasPrefix(deeper + "   ") {
                        let entry = line.dropFirst(indent.count + 2)
                        if let colon = entry.range(of: ": ") {
                            dict[String(entry[..<colon.lowerBound])] = String(entry[colon.upperBound...])
                        }
                    }
                    props[key] = dict
                } else {
                    props[key] = inner.compactMap { line -> String? in
                        guard let q1 = line.firstIndex(of: "\""),
                              let q2 = line.lastIndex(of: "\""), q1 != q2 else { return nil }
                        return String(line[line.index(after: q1)..<q2])
                    }
                }
            } else if valStr == "true" {
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
        parseEqualsBlocks(text: text, className: "IOPortTransportStateCIO")
            + parseDashBlocks(text: text, classPrefix: "IOPortTransportStateCIO")
    }

    /// Same portKey derivation as `TRMTransportWatcher.parentPortIdentity`.
    /// `hasPeerMetadata` reads the way the watcher does: a dictionary that
    /// was read maps to whether it has keys; a missing key stays nil.
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
            linkTrainingMode: (props["LinkTrainingMode"] as? NSNumber)?.intValue,
            hasPeerMetadata: (props["Metadata"] as? [String: String]).map { !$0.isEmpty },
            tunneledTransportsProvisioned: props["TunneledTransportsProvisioned"] as? [String]
        )
    }

    // MARK: - Host-to-host replay: probe 29 parsing (duplicated from DataLinkDeviceCapCorpusReplayTests)

    private static func parseInstanceBlocks(_ text: String, className: String) -> [String] {
        var results: [String] = []
        var open = false
        var current: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("--- \(className)") && trimmed.hasSuffix("---") {
                if open { results.append(current.joined(separator: "\n")) }
                open = true
                current = []
            } else if trimmed.hasPrefix("=== ") && trimmed.hasSuffix(" ===") {
                if open { results.append(current.joined(separator: "\n")) }
                open = false
                current = []
            } else if open {
                current.append(line)
            }
        }
        if open { results.append(current.joined(separator: "\n")) }
        return results
    }

    private static func valuePart(_ line: String, key: String) -> Substring? {
        let needle = "\(key) = "
        var searchStart = line.startIndex
        while let range = line.range(of: needle, range: searchStart..<line.endIndex) {
            searchStart = min(line.index(after: range.lowerBound), line.endIndex)
            var spaces = 0
            var cursor = range.lowerBound
            while cursor > line.startIndex {
                let previous = line.index(before: cursor)
                guard line[previous] == " " else { break }
                spaces += 1
                cursor = previous
            }
            guard cursor == line.startIndex || spaces >= 2 else { continue }
            return line[range.upperBound...]
        }
        return nil
    }

    private static func parseIntLine(_ body: String, key: String) -> Int? {
        for line in body.components(separatedBy: "\n") {
            guard let after = valuePart(line, key: key)?.drop(while: { $0 == " " }) else { continue }
            if let v = Int(after.prefix { $0.isNumber || $0 == "-" }) { return v }
        }
        return nil
    }

    private static func parseStringLine(_ body: String, key: String) -> String? {
        for line in body.components(separatedBy: "\n") {
            guard let after = valuePart(line, key: key)?.drop(while: { $0 == " " }),
                  after.hasPrefix("\"") else { continue }
            let inner = after.dropFirst()
            if let close = inner.firstIndex(of: "\"") { return String(inner[..<close]) }
        }
        return nil
    }

    private static func makeReadClosure(body: String) -> (String) -> Any? {
        { key in
            if let s = parseStringLine(body, key: key) { return s as Any }
            if let n = parseIntLine(body, key: key) { return NSNumber(value: n) }
            return nil
        }
    }

    // MARK: - Host-to-host replay: fabric rebuild (duplicated from DataLinkDeviceCapCorpusReplayTests)

    /// Every switch the folder's fabric resolves to, or `nil` when the
    /// folder publishes no socket-bearing root lane at all. A downstream
    /// chain whose owning socket cannot be told apart from another's is
    /// left out rather than guessed at.
    private static func fabric(folder: String) -> [IOThunderboltSwitch]? {
        guard let text = loadProbeText(folder: folder, probe: "29_usb4_router_interfaces") else { return nil }

        // Only lane adapters carry `Micro Route String`. Non-lane adapters
        // are attributed by position: the port section is printed grouped by
        // owning switch, every block in a group carries that switch's
        // silicon `Vendor ID` and `Device ID`, and the run's own lanes name
        // the route it belongs to.
        var rootLanesBySocket: [String: [IOThunderboltPort]] = [:]
        var portsByRoute: [Int: [IOThunderboltPort]] = [:]

        struct RawPort {
            let port: IOThunderboltPort
            let micro: Int?
            let silicon: String
        }
        var rawPorts: [RawPort] = []
        for body in parseInstanceBlocks(text, className: "IOThunderboltPort") {
            guard let port = IOThunderboltPort.from(read: makeReadClosure(body: body)) else { continue }
            let vendor = parseIntLine(body, key: "Vendor ID") ?? -1
            let device = parseIntLine(body, key: "Device ID") ?? -1
            rawPorts.append(RawPort(
                port: port,
                micro: parseIntLine(body, key: "Micro Route String"),
                silicon: "\(vendor)/\(device)"
            ))
        }

        var runStart = 0
        while runStart < rawPorts.count {
            var runEnd = runStart + 1
            while runEnd < rawPorts.count, rawPorts[runEnd].silicon == rawPorts[runStart].silicon {
                runEnd += 1
            }
            let run = rawPorts[runStart..<runEnd]
            let routes = Set(run.compactMap { $0.port.adapterType.isLane ? $0.micro : nil }.filter { $0 != 0 })
            for raw in run {
                if let socketID = raw.port.socketID, !socketID.isEmpty,
                   raw.port.adapterType.isLane, raw.micro ?? 0 == 0 {
                    rootLanesBySocket[socketID, default: []].append(raw.port)
                } else if let micro = raw.micro, micro != 0 {
                    portsByRoute[micro, default: []].append(raw.port)
                } else if !raw.port.adapterType.isLane, routes.count == 1, let route = routes.first {
                    portsByRoute[route, default: []].append(raw.port)
                }
            }
            runStart = runEnd
        }
        guard !rootLanesBySocket.isEmpty else { return nil }

        // One synthetic host root per socket, ports in ascending port-number
        // order as production supplies them. The UID is a join key inside
        // this test only.
        var syntheticUID: Int64 = -1
        var roots: [IOThunderboltSwitch] = []
        for lanes in rootLanesBySocket.sorted(by: { $0.key < $1.key })
            .map({ $0.value.sorted { $0.portNumber < $1.portNumber } }) {
            let mask = lanes.reduce(UInt8(0)) { $0 | ($1.supportedSpeed?.rawValue ?? 0) }
            roots.append(IOThunderboltSwitch(
                id: syntheticUID,
                className: "IOThunderboltSwitch",
                vendorID: 1452,
                vendorName: "Apple Inc.",
                modelName: "Mac",
                routerID: 0,
                depth: 0,
                routeString: 0,
                upstreamPortNumber: 0,
                maxPortNumber: lanes.map(\.portNumber).max() ?? 0,
                supportedSpeed: SupportedSpeedMask(rawValue: mask),
                ports: lanes,
                parentSwitchUID: nil
            ))
            syntheticUID -= 1
        }

        struct RawDownstream {
            let uid: Int64
            let depth: Int
            let routeString: Int64
            let read: (String) -> Any?
            let ports: [IOThunderboltPort]
        }
        var downstream: [RawDownstream] = []
        for body in parseInstanceBlocks(text, className: "IOThunderboltSwitch") {
            guard let depth = parseIntLine(body, key: "Depth"), depth >= 1,
                  let uid = parseIntLine(body, key: "UID").map(Int64.init) else { continue }
            let route = Int64(parseIntLine(body, key: "Route String") ?? 0)
            downstream.append(RawDownstream(
                uid: uid, depth: depth, routeString: route,
                read: makeReadClosure(body: body),
                ports: (portsByRoute[Int(route)] ?? []).sorted { $0.portNumber < $1.portNumber }
            ))
        }

        // A route string repeated across two roots names no single parent.
        var routeCounts: [Int64: Int] = [:]
        for raw in downstream { routeCounts[raw.routeString, default: 0] += 1 }
        let resolvable = downstream.filter { routeCounts[$0.routeString] == 1 }

        var switches = roots
        var attachedUIDByRoute: [Int64: Int64] = [:]
        for raw in resolvable.sorted(by: { $0.depth < $1.depth }) {
            let parentUID: Int64
            if raw.depth == 1 {
                let hopByte = Int(raw.routeString & 0xFF)
                var owners = roots.filter { root in
                    root.ports.contains { $0.adapterType.isLane && $0.portNumber == hopByte }
                }
                if owners.count > 1 {
                    // Two controllers can both number a socket's lane the
                    // same. A trained lane is the one carrying a chain.
                    owners = owners.filter { root in
                        root.ports.contains {
                            $0.adapterType.isLane && $0.portNumber == hopByte && $0.hasTrainedLanes
                        }
                    }
                }
                guard owners.count == 1, let owner = owners.first else { continue }
                parentUID = owner.id
            } else {
                let parentRoute = raw.routeString & ~(Int64(0xFF) << (8 * Int64(raw.depth - 1)))
                guard let parent = attachedUIDByRoute[parentRoute] else { continue }
                parentUID = parent
            }
            guard let sw = IOThunderboltSwitch.from(
                uid: raw.uid,
                read: raw.read,
                className: "IOThunderboltSwitch",
                ports: raw.ports,
                parentSwitchUID: parentUID
            ) else { continue }
            attachedUIDByRoute[raw.routeString] = raw.uid
            switches.append(sw)
        }
        return switches
    }

    // MARK: - Host-to-host replay: probe 38 devices (shape from ChainAttributionProbeSweepTests.usbDevices)

    /// Probe 38 writes `--- Device[N] ---` blocks with single-spaced
    /// `key = value` lines, then the ancestor walk. `controllerPortName` is
    /// the tail of the first ancestor's `UsbIOPort=` path, the way
    /// `USBWatcher` reads it live; an `AppleUSBXHCITR` ancestor marks the
    /// device as tunnelled.
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
            var portName: String?
            var tunnelled = false
            for line in body {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("[") else { continue }
                if t.contains("class=AppleUSBXHCITR") { tunnelled = true }
                if portName == nil, let r = t.range(of: "UsbIOPort=") {
                    let path = t[r.upperBound...].prefix { !$0.isWhitespace }
                    portName = path.split(separator: "/").last.map(String.init)
                }
            }
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
                controllerPortName: portName,
                isThunderboltTunnelled: tunnelled,
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

    // MARK: - Host-to-host replay

    /// One active-CIO port replayed with its own device list: the diagnostic,
    /// the port card's measured lines, the Connected devices rows and the
    /// predicate, all from the same inputs.
    private struct HostToHostReplay {
        let folder: String
        let portName: String
        let devices: [USBDevice]
        let isHostToHost: Bool
        let diagnostic: DataLinkDiagnostic?
        let measuredLines: [String]
        let treeRows: [ConnectedDeviceTree.Row]

        var key: String { "\(folder)\t\(portName)" }
        var deviceList: String {
            devices.map { "\($0.productName ?? "?") 0x\(String($0.productID, radix: 16)) speed \($0.speedRaw.map(String.init) ?? "-")" }
                .joined(separator: "; ")
        }
    }

    /// The five folders the ticket names plus one control, with the port each
    /// case sits on.
    private static let namedPorts: [(folder: String, port: String)] = [
        ("m4pro_macos26.6.2_d", "Port-USB-C@3"),
        ("m5pro_macos27.0_d", "Port-USB-C@1"),
        ("m4_macos26.5.2_g", "Port-USB-C@1"),
        ("m1pro_macos26.5.2_q", "Port-USB-C@1"),
        ("m5pro_macos26.5.2_b", "Port-USB-C@3"),
        ("m4_macos27.0_k", "Port-USB-C@1")
    ]

    private static func replayPort(
        folder: String,
        port: ProbePort,
        allIdentities: [USBPDSOP],
        allDevices: [USBDevice],
        cio: CIOCableCapability,
        switches: [IOThunderboltSwitch],
        tbActiveGbps: Double? = nil
    ) -> HostToHostReplay {
        let hpm = port.asAppleHPMInterface
        // The production join: the port picks its own devices from the
        // folder's whole list.
        let devices = hpm.matchingDevices(from: allDevices)
        let portIdentities = allIdentities.filter { $0.parentPortNumber == port.portNumber }
        // The diagnostic reads the cable only, as the golden replay fed it.
        let cableIdentities = portIdentities.filter { $0.endpoint == .sopPrime || $0.endpoint == .sopDoublePrime }
        let diag = DataLinkDiagnostic(
            port: hpm,
            identities: cableIdentities,
            devices: devices,
            usb3Transports: [],
            cio: cio,
            thunderboltSwitches: switches,
            tbActiveGbps: tbActiveGbps
        )
        let summary = PortSummary(
            port: hpm,
            identities: portIdentities,
            devices: devices,
            thunderboltSwitches: switches,
            cioCapability: cio
        )
        let rows = ConnectedDeviceTree.rows(
            devices: devices,
            port: hpm,
            thunderboltSwitches: switches,
            displayPorts: [],
            cioCapability: cio
        )
        return HostToHostReplay(
            folder: folder,
            portName: port.serviceName,
            devices: devices,
            isHostToHost: HostToHostLink.isHostToHost(
                port: hpm, devices: devices, cio: cio, thunderboltSwitches: switches),
            diagnostic: diag,
            measuredLines: summary.group(.measured)?.lines ?? [],
            treeRows: rows
        )
    }

    /// Every active-CIO port on a connected USB-C port carrying CIO, one row
    /// per port (the first active block wins, as the golden replay dedups),
    /// replayed against the folder's rebuilt fabric. Folders with no fabric
    /// are dropped, except the Vision Pro folder, which has no probe 29 on
    /// disk and is driven through `tbActiveGbps` and a synthetic host root.
    private static func computeHostToHostReplay() -> (rows: [HostToHostReplay], foldersSwept: Int, viaFabric: Int) {
        var rows: [HostToHostReplay] = []
        var viaFabric = 0
        let folders = allProbes()
        for folder in folders {
            let ports = (try? loadPorts(probe: folder)) ?? []
            guard !ports.isEmpty else { continue }
            let text17 = loadProbeText(folder: folder, probe: "17_deep_property_dump") ?? ""
            let text19 = loadProbeText(folder: folder, probe: "19_pdo_decode_and_usb3_watch") ?? ""
            let cioProps = extractCIOBlocks(text: text17) + extractCIOBlocks(text: text19)
            guard !cioProps.isEmpty else { continue }

            let switches = fabric(folder: folder)
            let ids = identities(folder: folder)
            let devices = loadProbeText(folder: folder, probe: "38_usb_device_tree").map(usbDevices) ?? []

            var seenPortNumbers = Set<Int>()
            for (i, props) in cioProps.enumerated() {
                guard (props["Active"] as? NSNumber)?.boolValue == true else { continue }
                let cio = cioCapability(entryID: UInt64(1000 + i), props: props)
                guard let portNumber = cio.portKey.split(separator: "/").last.flatMap({ Int($0) }),
                      !seenPortNumbers.contains(portNumber) else { continue }
                guard let port = ports.first(where: {
                    $0.portTypeDescription == "USB-C"
                        && $0.portNumber == portNumber
                        && $0.connectionActive
                        && $0.transportsActive.contains("CIO")
                }) else { continue }
                seenPortNumbers.insert(portNumber)

                if let switches {
                    viaFabric += 1
                    rows.append(replayPort(
                        folder: folder, port: port, allIdentities: ids, allDevices: devices,
                        cio: cio, switches: switches))
                } else if namedPorts.contains(where: { $0.folder == folder && $0.port == port.serviceName }) {
                    // No probe 29 on disk (m5pro_macos26.5.2_b): a 40 Gbps
                    // active rate and a bare host root stand in for the
                    // fabric, so the predicate's fabric guard has a root to
                    // find and no partner to refuse on.
                    let suffix = String(port.serviceName.split(separator: "@").last ?? "")
                    rows.append(replayPort(
                        folder: folder, port: port, allIdentities: ids, allDevices: devices,
                        cio: cio, switches: [makeHostSwitch(socketID: suffix, supportedRaw: 0xC)],
                        tbActiveGbps: 40))
                }
            }
        }
        rows.sort { ($0.folder, $0.portName) < ($1.folder, $1.portName) }
        return (rows, folders.count, viaFabric)
    }

    private static func verdictName(_ diag: DataLinkDiagnostic?) -> String {
        guard let diag else { return "" }
        switch diag.bottleneck {
        case .fine: return "fine"
        case .cableLimit: return "cableLimit"
        case .hostLimit: return "hostLimit"
        case .deviceLimit: return "deviceLimit"
        case .degraded: return "degraded"
        case .unknownCable: return "unknownCable"
        case .cableContradictsActive: return "cableContradictsActive"
        case .blockedBySecurity: return "blockedBySecurity"
        }
    }

    private static func isDeviceLimit(_ diag: DataLinkDiagnostic?) -> Bool {
        if case .deviceLimit = diag?.bottleneck { return true }
        return false
    }

    /// `folder\tport` -> verdict case, from the golden the verdict replay
    /// keeps (produced with `devices: []`).
    private static func goldenCases() -> [String: String]? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/golden/data-link-verdict-replay-cases.tsv")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var map: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            map["\(fields[0])\t\(fields[1])"] = String(fields[2])
        }
        return map
    }

    /// Replays the peer-Mac and Vision Pro folders with their real probe-38
    /// device lists joined to the port by `matchingDevices`, then holds every
    /// other active-CIO port to the golden verdict case: with devices fed in,
    /// only the named ports may move, and only off `deviceLimit`.
    @Test("Host-to-host replay: peer-Mac and Vision Pro folders with real device lists")
    func hostToHostReplayWithRealDevices() throws {
        let probes = Self.allProbes()
        guard !probes.isEmpty else {
            Issue.record("Corpus root absent at \(Self.probeRoot.path); the host-to-host replay tested nothing")
            return
        }
        let (rows, foldersSwept, viaFabric) = Self.computeHostToHostReplay()
        let byKey = Dictionary(rows.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })

        // 1. Every named port was actually replayed.
        var namedReplayed = 0
        for (folder, port) in Self.namedPorts {
            guard let row = byKey["\(folder)\t\(port)"], row.diagnostic != nil else {
                Issue.record("\(folder) \(port) was not replayed or produced no diagnostic")
                continue
            }
            namedReplayed += 1
            print("Host-to-host named: \(folder) \(port) -> \(Self.verdictName(row.diagnostic)), predicate \(row.isHostToHost), summary \"\(row.diagnostic?.summary ?? "")\", devices [\(row.deviceList)]")
        }
        #expect(namedReplayed == 6, "only \(namedReplayed) of 6 named ports replayed")

        // 2. Per-port expectations.
        let macLine = "Connected device: another Mac"
        let peerSuffix = "\u{00B7} USB link only"
        for (folder, port) in [("m4pro_macos26.6.2_d", "Port-USB-C@3"), ("m5pro_macos27.0_d", "Port-USB-C@1"), ("m4_macos26.5.2_g", "Port-USB-C@1")] {
            guard let row = byKey["\(folder)\t\(port)"] else { continue }
            #expect(row.isHostToHost, "\(folder) \(port): predicate should be true")
            #expect(!Self.isDeviceLimit(row.diagnostic), "\(folder) \(port): verdict is \(Self.verdictName(row.diagnostic)), devices [\(row.deviceList)]")
            #expect(row.diagnostic?.summary.hasPrefix("Linked to another Mac at") == true,
                "\(folder) \(port): summary \"\(row.diagnostic?.summary ?? "")\"")
            #expect(row.measuredLines.contains(macLine), "\(folder) \(port): measured lines \(row.measuredLines)")
        }
        if let row = byKey["m4pro_macos26.6.2_d\tPort-USB-C@3"] {
            if case .fine = row.diagnostic?.bottleneck {} else {
                Issue.record("m4pro_macos26.6.2_d Port-USB-C@3: verdict \(Self.verdictName(row.diagnostic)), expected fine")
            }
            let peerRows = row.treeRows.filter { $0.device?.device.productName == "Mac" }
            #expect(!peerRows.isEmpty, "m4pro_macos26.6.2_d Port-USB-C@3: no tree row for the Mac; rows \(row.treeRows.map(\.label))")
            for peerRow in peerRows {
                #expect(peerRow.label.hasSuffix(peerSuffix), "tree row \"\(peerRow.label)\" lacks the link-only suffix")
            }
        }
        if let row = byKey["m1pro_macos26.5.2_q\tPort-USB-C@1"] {
            #expect(row.isHostToHost, "m1pro_macos26.5.2_q Port-USB-C@1: predicate should be true")
            #expect(!Self.isDeviceLimit(row.diagnostic), "m1pro_macos26.5.2_q Port-USB-C@1: verdict is \(Self.verdictName(row.diagnostic))")
            if case .cableLimit = row.diagnostic?.bottleneck {
                Issue.record("m1pro_macos26.5.2_q Port-USB-C@1: a peer link must not read as a cable limit")
            }
            #expect(row.diagnostic?.summary.hasPrefix("Linked to another Mac at") == true,
                "m1pro_macos26.5.2_q Port-USB-C@1: summary \"\(row.diagnostic?.summary ?? "")\"")
        }
        if let row = byKey["m5pro_macos27.0_d\tPort-USB-C@1"] {
            // 80 Gbps e-marker, lane at 40: the claim is uncarried, so the
            // case is the non-confirming one and the golden (unknownCable)
            // is kept.
            #expect(row.diagnostic?.bottleneck == .unknownCable(activeGbps: 40),
                "m5pro_macos27.0_d Port-USB-C@1: verdict \(Self.verdictName(row.diagnostic))")
            #expect(row.diagnostic?.summary == "Linked to another Mac at 40 Gbps",
                "m5pro_macos27.0_d Port-USB-C@1: summary \"\(row.diagnostic?.summary ?? "")\"")
        }
        if let row = byKey["m5pro_macos26.5.2_b\tPort-USB-C@3"] {
            #expect(!row.isHostToHost, "Vision Pro is not a Mac: predicate should be false; devices [\(row.deviceList)]")
            #expect(!Self.isDeviceLimit(row.diagnostic), "Vision Pro port: verdict is \(Self.verdictName(row.diagnostic))")
            #expect(row.diagnostic?.summary.contains("another Mac") == false,
                "Vision Pro port: summary \"\(row.diagnostic?.summary ?? "")\"")
        }
        if let row = byKey["m4_macos27.0_k\tPort-USB-C@1"] {
            #expect(!row.isHostToHost, "m4_macos27.0_k Port-USB-C@1: no USB device, predicate should be false; devices [\(row.deviceList)]")
            #expect(Self.verdictName(row.diagnostic) == "fine", "m4_macos27.0_k Port-USB-C@1: verdict \(Self.verdictName(row.diagnostic)), golden fine")
        }

        // 3. Everything else holds to the golden case. The golden was
        // produced with `devices: []`, so a port may move only where its
        // real devices reach the diagnostic, which is the named set.
        guard let golden = Self.goldenCases() else {
            Issue.record("Missing golden data-link-verdict-replay-cases.tsv; nothing to compare against")
            return
        }
        var compared = 0
        var differing: [HostToHostReplay] = []
        for row in rows {
            guard let goldenCase = golden[row.key] else { continue }
            compared += 1
            if goldenCase != Self.verdictName(row.diagnostic) { differing.append(row) }
        }
        let namedKeys = Set(Self.namedPorts.map { "\($0.folder)\t\($0.port)" })
        for row in differing {
            print("Host-to-host golden diff: \(row.folder) \(row.portName): golden \(golden[row.key] ?? "") -> replayed \(Self.verdictName(row.diagnostic)), devices [\(row.deviceList)]")
        }
        let unexpected = differing.filter { !namedKeys.contains($0.key) }
        #expect(unexpected.isEmpty,
            "\(unexpected.count) port(s) outside the named set moved off the golden case with real devices: \(unexpected.map { "\($0.folder) \($0.portName)" })")
        #expect(compared >= 300, "only \(compared) ports compared to the golden")

        // 4. Counts.
        print("Host-to-host replay: \(foldersSwept) folders swept, \(viaFabric) active-CIO ports resolved, \(compared) ports compared to golden, \(namedReplayed) named ports replayed, \(differing.count) golden diffs")
    }
}
