import Foundation
import Testing

/// Corpus-replay sweep behind the hint on USB-only port cards. A USB-C port
/// with no "CC" transport (no Power Delivery) tells the user to "plug the cable
/// into a Thunderbolt port to see its details". The app does not check at run
/// time that the Mac has a Thunderbolt port, so the sentence assumes every Mac
/// with a plain USB-C socket also has one. This sweep holds that premise: it
/// fails if any capture shows a Mac with a plain built-in USB-C port and no
/// built-in USB-C port that lists "CIO" in its `TransportsSupported`.
///
/// Only the Mac's own ports count. A dock's or tunnelled device's port can
/// list CIO too, and must never stand in for the Mac's. The anchors, checked
/// against the corpus:
/// - a port node is the Mac's when it has `BuiltIn = true` and a
///   `PortDescription` of `Port-USB-C@N`;
/// - a transport-state node is the Mac's when it has `ParentPortBuiltIn = true`;
///   its `TransportDescription` (`Port-USB-C@5/USB3`) names the port and the
///   transport.
///
/// A port is plain when its `TransportsSupported` lacks CC, which is the test
/// the app itself makes. Older text probes print no list for the non-HPM
/// ports a desktop has, so a port with no list falls back to its transport
/// states: plain when it has some and none is CC.
///
/// Capability is read from `TransportsSupported`, never from a `/CIO`
/// transport string: that only exists while something is linked over
/// Thunderbolt, so it is absent on idle machines.
///
/// Two passes: the old text-format folders in `research/customer-probes`, and
/// the format 1 runs in `research-data/runs` (private), where new submissions land. Raw
/// probes are on-disk only, so each not-empty guard only arms when its corpus
/// is present, same convention as the other corpus sweeps. A machine with a
/// plain port but no built-in port list at all is an incomplete capture and is
/// skipped rather than asserted on.
@Suite("Plain USB-C port: Thunderbolt corpus sweep")
struct PlainUSBCThunderboltCorpusTests {

    private static let probeRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WhatCableCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("research/customer-probes")
    }()

    /// What one machine publishes about its own built-in USB-C ports, keyed by
    /// port number.
    struct BuiltInPorts: Equatable {
        /// `TransportsSupported` items, from built-in port nodes.
        var supported: [String: Set<String>] = [:]
        /// Transport types, from built-in transport-state nodes.
        var transports: [String: Set<String>] = [:]

        var portCount: Int { Set(supported.keys).union(transports.keys).count }

        /// Ports with a non-empty `TransportsSupported` list: what the
        /// Thunderbolt verdict reads.
        var listedPortCount: Int { supported.values.filter { !$0.isEmpty }.count }
    }

    enum Verdict: Equatable {
        case noPlainPort
        /// A plain port, but no built-in port list to judge Thunderbolt by.
        case incomplete(plain: [String])
        case checked(plain: [String], hasThunderbolt: Bool)
    }

    static func verdict(_ ports: BuiltInPorts) -> Verdict {
        let numbers = Set(ports.supported.keys).union(ports.transports.keys)
        let plain = numbers.filter { n in
            // An empty list still lacks CC, so the app shows the hint for it.
            if let list = ports.supported[n] { return !list.contains("CC") }
            let states = ports.transports[n] ?? []
            return !states.isEmpty && !states.contains("CC")
        }.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
        guard !plain.isEmpty else { return .noPlainPort }
        guard ports.supported.values.contains(where: { !$0.isEmpty }) else { return .incomplete(plain: plain) }
        return .checked(plain: plain, hasThunderbolt: ports.supported.values.contains { $0.contains("CIO") })
    }

    // MARK: Text format

    // Key must not be the tail of a longer name (e.g. "...EnabledTransportsSupported",
    // "ParentPortBuiltIn"), whichever way the probe printed it: `Key = v`,
    // `"Key": v`, `Key: v`, or `Class.Key = v`.
    private static let listStartRegex = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])"?TransportsSupported"?\s*[=:]\s*(\[|\()(.*)$"#)
    private static let quotedRegex = try! NSRegularExpression(pattern: #""([^"]*)""#)
    private static let builtInRegex = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])"?BuiltIn"?\s*[=:]\s*true\b"#)
    private static let portDescriptionRegex = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])"?PortDescription"?\s*[=:]\s*"Port-USB-C@(\d+)""#)
    private static let parentBuiltInRegex = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])"?ParentPortBuiltIn"?\s*[=:]\s*true\b"#)
    // Port-USB-C@5/USB3, Port-USB-C@4/CIO/USB3@0: the first path segment
    // after the port number is the transport.
    private static let transportDescriptionRegex = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])"?TransportDescription"?\s*[=:]\s*"Port-USB-C@(\d+)/([A-Za-z0-9]+)"#)
    // One registry entry's properties end at a blank line or at the next
    // entry's heading: `=== X ===`, `--- X ---`, a `====` rule, or probe
    // 43's `- class=X` tree line.
    private static let blockBoundaryRegex = try! NSRegularExpression(
        pattern: #"^\s*($|-\s+class=|=== |--- |====)"#)

    /// The text split into one property block per registry entry.
    static func propertyBlocks(in text: String) -> [String] {
        var blocks: [String] = []
        var current: [String] = []
        for line in text.components(separatedBy: "\n") {
            let ns = line as NSString
            if blockBoundaryRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil {
                if !current.isEmpty { blocks.append(current.joined(separator: "\n")) }
                current = line.trimmingCharacters(in: .whitespaces).isEmpty ? [] : [line]
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { blocks.append(current.joined(separator: "\n")) }
        return blocks
    }

    /// The Mac's own USB-C ports, from every property block in the text.
    static func builtInPorts(in text: String) -> BuiltInPorts {
        var ports = BuiltInPorts()
        for block in propertyBlocks(in: text) {
            let ns = block as NSString
            let all = NSRange(location: 0, length: ns.length)
            if builtInRegex.firstMatch(in: block, range: all) != nil {
                let numbers = Set(portDescriptionRegex.matches(in: block, range: all)
                    .map { ns.substring(with: $0.range(at: 1)) })
                let lists = supportedLists(in: block)
                // One port per block; anything else is a mis-split, not evidence.
                if numbers.count == 1, let n = numbers.first, !lists.isEmpty {
                    ports.supported[n, default: []].formUnion(lists.joined())
                }
            }
            if parentBuiltInRegex.firstMatch(in: block, range: all) != nil {
                for m in transportDescriptionRegex.matches(in: block, range: all) {
                    ports.transports[ns.substring(with: m.range(at: 1)), default: []]
                        .insert(ns.substring(with: m.range(at: 2)))
                }
            }
        }
        return ports
    }

    /// Every `TransportsSupported` list in the text, as its quoted items.
    /// Handles the multi-line `[ ... ]` form and the one-line `("a","b")` tuple.
    static func supportedLists(in text: String) -> [[String]] {
        var lists: [[String]] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            i += 1
            let ns = line as NSString
            guard let m = listStartRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length))
            else { continue }
            let opener = ns.substring(with: m.range(at: 1))
            let rest = ns.substring(with: m.range(at: 2))
            if opener == "(" {
                // One-line tuple; everything up to the closing paren.
                let body = rest.split(separator: ")", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rest
                lists.append(quoted(body))
                continue
            }
            // Multi-line: items until a line that is just "]".
            var items: [String] = []
            while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != "]" {
                items.append(contentsOf: quoted(lines[i]))
                i += 1
            }
            i += 1  // step past the closing bracket
            lists.append(items)
        }
        return lists
    }

    private static func quoted(_ s: String) -> [String] {
        let ns = s as NSString
        return quotedRegex.matches(in: s, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }

    // MARK: Format 1

    private static let portNumberRegex = try! NSRegularExpression(pattern: #"^Port-USB-C@(\d+)$"#)
    private static let transportPathRegex = try! NSRegularExpression(pattern: #"^Port-USB-C@(\d+)/([A-Za-z0-9]+)"#)

    /// The Mac's own USB-C ports, from a format 1 registry snapshot. Same
    /// anchors as the text format, read as typed values.
    static func builtInPorts(in snapshot: RegistrySnapshot) -> BuiltInPorts {
        var ports = BuiltInPorts()
        for entry in snapshot.entries.values {
            let props = entry.properties
            if props["BuiltIn"] == .bool(true),
               case let .string(description)? = props["PortDescription"],
               let n = capture(portNumberRegex, in: description)?.first,
               case let .array(items)? = props["TransportsSupported"] {
                ports.supported[n, default: []].formUnion(items.compactMap {
                    if case let .string(s) = $0 { return s }
                    return nil
                })
            }
            if props["ParentPortBuiltIn"] == .bool(true),
               case let .string(path)? = props["TransportDescription"],
               let groups = capture(transportPathRegex, in: path) {
                ports.transports[groups[0], default: []].insert(groups[1])
            }
        }
        return ports
    }

    private static func capture(_ regex: NSRegularExpression, in s: String) -> [String]? {
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { ns.substring(with: m.range(at: $0)) }
    }

    // MARK: Parser tests

    @Test("Parsers read both printed list forms")
    func parsersReadBothForms() {
        let text = """
          "TransportsSupported": [
            [0] "CC"
            [3] "CIO"
          ]
          TransportsSupported = ("USB2","USB3")
          IOAccessoryEnabledTransportsSupported: [
            [0] "CIO"
          ]
        """
        #expect(Self.supportedLists(in: text) == [["CC", "CIO"], ["USB2", "USB3"]])
    }

    /// A Mac whose only CIO list belongs to a dock's port: the dock must not
    /// stand in for the Mac, and the dock's plain port must not count as the
    /// Mac's. Port 1 is numbered the same on both on purpose.
    private static let dockOnlyThunderboltText = """
    === IOAccessoryManager[0] ===
      Class: AppleHPMInterfaceType10
      Properties:
        PortDescription = "Port-USB-C@1"
        BuiltIn = true
        TransportsSupported = [
          [0] "CC"
          [1] "USB2"
          [2] "USB3"
        ]

    === IOPortTransportStateUSB3[0] ===
      Properties:
        ParentPortBuiltIn = true
        TransportDescription = "Port-USB-C@5/USB3"

    === IOPort[3] ===
      Properties:
        PortDescription = "Port-USB-C@1"
        BuiltIn = false
        TransportsSupported = [
          [0] "CC"
          [1] "CIO"
        ]

    === IOPortTransportStateUSB3[1] ===
      Properties:
        ParentPortBuiltIn = false
        TransportDescription = "Port-USB-C@7/USB3"
    """

    @Test("Text: only the Mac's own ports count")
    func textCountsOnlyBuiltInPorts() {
        let ports = Self.builtInPorts(in: Self.dockOnlyThunderboltText)
        #expect(ports.supported == ["1": ["CC", "USB2", "USB3"]])
        #expect(ports.transports == ["5": ["USB3"]])
        #expect(Self.verdict(ports) == .checked(plain: ["5"], hasThunderbolt: false))
    }

    @Test("Text: blocks split at every heading style, including probe 43's tree lines")
    func textBlocksSplitAtHeadings() {
        let text = """
        - class=IOPort name=Port-USB-C id=0x1 loc=6 [depth 0]
          "TransportsSupported": [
            [0] "USB2"
          ]
          "BuiltIn": true
          "PortDescription": "Port-USB-C@6"
          - class=IOPortTransportStateUSB2 name=USB2 id=0x2 loc=(none) [depth 1]
            "ParentPortBuiltIn": true
            "TransportDescription": "Port-USB-C@6/USB2"
        --- AppleHPMInterfaceType10[0] ---
          BuiltIn: true
          PortDescription: "Port-USB-C@1"
          TransportsSupported: [
            [0] "CC"
            [1] "CIO"
          ]
        """
        let ports = Self.builtInPorts(in: text)
        #expect(Self.propertyBlocks(in: text).count == 3)
        #expect(ports.supported == ["6": ["USB2"], "1": ["CC", "CIO"]])
        #expect(ports.transports == ["6": ["USB2"]])
        #expect(Self.verdict(ports) == .checked(plain: ["6"], hasThunderbolt: true))
    }

    @Test("A built-in USB-C port with an empty list is plain, as the app treats it")
    func emptyListIsPlain() {
        let ports = BuiltInPorts(supported: ["1": [], "2": ["CC", "USB2", "CIO"]])
        #expect(Self.verdict(ports) == .checked(plain: ["1"], hasThunderbolt: true))
    }

    @Test("Format 1: only the Mac's own ports count")
    func formatOneCountsOnlyBuiltInPorts() throws {
        func str(_ s: String) -> String { #"{"t":"str","v":"\#(s)"}"# }
        func bool(_ b: Bool) -> String { #"{"t":"bool","v":\#(b)}"# }
        func array(_ items: [String]) -> String { #"{"t":"array","v":[\#(items.map(str).joined(separator: ","))]}"# }
        func entry(_ id: Int, _ props: [(String, String)]) -> String {
            let pairs = props.map { #"["\#($0.0)",\#($0.1)]"# }.joined(separator: ",")
            return #"{"record":"entry","id":"0x\#(id)","class":"X","props":{"t":"dict","v":[\#(pairs)]}}"#
        }
        let lines = [
            #"{"record":"header","format":1,"probe":"50_registry_snapshot"}"#,
            // The Mac's HPM port: PD, no Thunderbolt.
            entry(1, [("BuiltIn", bool(true)), ("PortDescription", str("Port-USB-C@1")),
                      ("TransportsSupported", array(["CC", "USB2", "USB3", "DisplayPort"]))]),
            // The Mac's plain port.
            entry(2, [("BuiltIn", bool(true)), ("PortDescription", str("Port-USB-C@5")),
                      ("TransportsSupported", array(["USB2", "USB3"]))]),
            // A dock's Thunderbolt port and its plain port's transport state.
            entry(3, [("BuiltIn", bool(false)), ("PortDescription", str("Port-USB-C@1")),
                      ("TransportsSupported", array(["CC", "CIO"]))]),
            entry(4, [("ParentPortBuiltIn", bool(false)), ("TransportDescription", str("Port-USB-C@7/USB3"))]),
            // The Mac's own Thunderbolt link state on port 1 is a transport, not a capability.
            entry(5, [("ParentPortBuiltIn", bool(true)), ("TransportDescription", str("Port-USB-C@1/CIO/USB3@0"))]),
            #"{"record":"footer","status":"complete"}"#,
        ]
        let file = try FormatOneFile(data: Data(lines.joined(separator: "\n").utf8))
        let ports = Self.builtInPorts(in: try RegistrySnapshot(file))
        #expect(ports.supported == ["1": ["CC", "USB2", "USB3", "DisplayPort"], "5": ["USB2", "USB3"]])
        #expect(ports.transports == ["1": ["CIO"]])
        #expect(Self.verdict(ports) == .checked(plain: ["5"], hasThunderbolt: false))
    }

    // MARK: Sweeps

    @Test("Every Mac with a plain USB-C port lists a Thunderbolt-capable port")
    func plainUSBCMacsHaveThunderbolt() throws {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(atPath: Self.probeRoot.path))?.sorted() ?? []

        var filesOnDisk = 0
        var filesDecoded = 0
        var scanned = 0
        var checked = 0
        var skippedIncomplete = 0

        for folder in folders {
            let dir = Self.probeRoot.appendingPathComponent(folder)
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            scanned += 1

            var text = ""
            for name in names.sorted() where name.hasSuffix(".json") {
                // Existence and decodability counted separately so a decode
                // regression cannot quietly disarm the guard.
                filesOnDisk += 1
                guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                      let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let output = root["output"] as? String
                else { continue }
                filesDecoded += 1
                // Blank line so the last block of one file never runs into the next.
                text += output + "\n\n"
            }

            switch Self.verdict(Self.builtInPorts(in: text)) {
            case .noPlainPort:
                continue
            case .incomplete:
                skippedIncomplete += 1
            case let .checked(plain, hasThunderbolt):
                checked += 1
                #expect(hasThunderbolt,
                    "\(folder): plain built-in USB-C port(s) \(plain) but no built-in port lists CIO")
            }
        }

        print("[PlainUSBCThunderboltSweep] \(scanned) folders scanned, \(checked) checked, "
            + "\(skippedIncomplete) skipped as incomplete (plain port, no built-in TransportsSupported list), "
            + "\(filesOnDisk) probe files (\(filesDecoded) decoded)")

        // Only armed when the corpus is on disk; an empty corpus checks nothing.
        if filesOnDisk > 0 {
            #expect(filesDecoded > 0, "corpus present but no probe file decoded; loader regression?")
            #expect(checked > 0, "corpus present but no folder was checked")
        }
    }

    @Test("Every format 1 run with a plain USB-C port lists a Thunderbolt-capable port")
    func formatOnePlainUSBCMacsHaveThunderbolt() throws {
        let runs = SnapshotCorpus.allRuns()

        var snapshotsDecoded = 0
        var skippedCutOff = 0
        var portsRead = 0
        var listsRead = 0
        var checked = 0
        var skippedIncomplete = 0

        for run in runs {
            guard let file = try SnapshotCorpus.load(run: run, probe: "50_registry_snapshot") else { continue }
            // A cut-off snapshot may be missing the very port that lists CIO.
            guard file.isComplete else { skippedCutOff += 1; continue }
            let ports = Self.builtInPorts(in: try RegistrySnapshot(file))
            snapshotsDecoded += 1
            portsRead += ports.portCount
            listsRead += ports.listedPortCount

            switch Self.verdict(ports) {
            case .noPlainPort:
                continue
            case .incomplete:
                skippedIncomplete += 1
            case let .checked(plain, hasThunderbolt):
                checked += 1
                #expect(hasThunderbolt,
                    "\(run.lastPathComponent): plain built-in USB-C port(s) \(plain) but no built-in port lists CIO")
            }
        }

        print("[PlainUSBCThunderboltSweep format 1] \(runs.count) runs, \(snapshotsDecoded) snapshots read, "
            + "\(skippedCutOff) skipped as cut off, \(portsRead) built-in USB-C ports read (\(listsRead) with a TransportsSupported list), \(checked) checked, "
            + "\(skippedIncomplete) skipped as incomplete")

        // Armed only when runs are on disk. No run today has a plain port, so
        // the guard is on ports read, not on machines checked.
        if !runs.isEmpty {
            #expect(snapshotsDecoded > 0, "runs present but no complete registry snapshot read")
            #expect(portsRead > 0, "runs present but no built-in USB-C port read; reader regression?")
            // Transport states alone would satisfy the line above; the verdict
            // reads the lists, so they must be seen too.
            #expect(listsRead > 0, "runs present but no built-in TransportsSupported list read; reader regression?")
        }
    }
}
