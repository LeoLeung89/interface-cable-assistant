import Foundation
import Testing
@testable import WhatCableCore

/// Corpus-replay sweep for the "macOS is withholding data on this port" wording
/// in `PortSummary` (`Sources/WhatCableCore/Output/PortSummary.swift`).
///
/// The bug this guards: macOS keeps a withheld transport listed in
/// `TransportsActive` and marks its node `Active = Yes` while refusing
/// authorisation, so the card claimed a live data link on a port where nothing
/// was flowing. Confirmed on hardware 2026-07-30 by denying an accessory at the
/// macOS prompt.
///
/// This file deliberately carries its OWN parsers rather than reusing
/// `PortSummaryCorpusSweepTests`'s. A check that reads its inputs through the
/// same code as the thing it checks is not a check, which this repo has already
/// paid for once (the CIO 87-vs-123 undercount, where the cross-check agreed
/// with the bug for weeks because both sides read probe 17).
///
/// Probe sources, unioned on purpose: probe 01 (git-tracked for every folder,
/// so a fresh clone keeps coverage) and probe 17. Probe 19 is deliberately NOT
/// used: it is the "usb3_watch" probe and captures no `Port-USB-C@N/USB2`
/// transport nodes at all, and every corpus machine with a withheld transport
/// is a USB2 case, so reading probe 19 alone would find nothing and pass
/// vacuously.
@Suite("Blocked data: corpus sweep")
struct BlockedDataCorpusSweepTests {

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

    private static func probeText(folder: String, probe: String) -> String? {
        let url = probeRoot.appendingPathComponent(folder).appendingPathComponent(probe)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = json["output"] as? String else { return nil }
        return output
    }

    // MARK: - Parsing (own implementation, see the note above)

    /// Split a probe dump into property blocks on its section headers, which
    /// look like `=== Class[0] ===` or `--- Class[0] ---` depending on probe.
    private static func blocks(_ text: String) -> [String] {
        var out: [String] = []
        var current: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isHeader = (trimmed.hasPrefix("===") || trimmed.hasPrefix("---"))
                && trimmed.contains("[")
                && (trimmed.hasSuffix("===") || trimmed.hasSuffix("---"))
            if isHeader {
                if let c = current { out.append(c) }
                current = ""
            } else if current != nil {
                current! += line + "\n"
            }
        }
        if let c = current { out.append(c) }
        return out
    }

    /// Read `Key = value` or `Key: value`, tolerating both probe styles.
    private static func value(_ block: String, _ key: String) -> String? {
        for line in block.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix(key) else { continue }
            let rest = t.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("=") || rest.hasPrefix(":") else { continue }
            var v = rest.dropFirst().trimmingCharacters(in: .whitespaces)
            if let paren = v.range(of: " (0x") { v = String(v[v.startIndex..<paren.lowerBound]) }
            return v.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    private static func bool(_ block: String, _ key: String) -> Bool? {
        guard let v = value(block, key) else { return nil }
        if v == "true" || v == "Yes" { return true }
        if v == "false" || v == "No" { return false }
        return nil
    }

    /// Nested list rendering:
    ///
    /// ```
    /// TransportsActive = [
    ///   [0] "CC"
    ///   [1] "USB2"
    /// ]
    /// ```
    ///
    /// Terminate on a line that is just `]`, NOT on the first `]` in the text:
    /// the first one belongs to the `[0]` index marker, so a naive scan returns
    /// an empty list for every populated list. That exact bug made the first
    /// version of this sweep find zero withheld ports and report "clean".
    private static func list(_ block: String, _ key: String) -> [String] {
        var collecting = false
        var items: [String] = []
        for line in block.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !collecting {
                if t.hasPrefix("\(key) = [") { collecting = true }
                continue
            }
            if t == "]" { break }
            guard let open = t.firstIndex(of: "\""), let close = t.lastIndex(of: "\""), open < close else { continue }
            items.append(String(t[t.index(after: open)..<close]))
        }
        return items
    }

    /// One physical USB-C port with the fields this sweep needs.
    private struct ProbePort {
        var folder: String
        var number: Int
        var active: [String]
        var unauthorized: [String]
        var supported: [String]
        /// transport type -> (restricted, tunnelled)
        var transports: [String: (restricted: Bool?, tunnelled: Bool?)]
    }

    private static func ports(folder: String) -> [ProbePort] {
        var found: [Int: ProbePort] = [:]
        for probe in ["01_walk_pd_tree.json", "17_deep_property_dump.json"] {
            guard let text = probeText(folder: folder, probe: probe) else { continue }
            for block in blocks(text) {
                // Port-level block.
                if let desc = value(block, "Description"), desc.hasPrefix("Port-USB-C@"),
                   !desc.contains("/"),
                   let n = Int(desc.dropFirst("Port-USB-C@".count)),
                   bool(block, "ConnectionActive") == true {
                    var p = found[n] ?? ProbePort(folder: folder, number: n, active: [], unauthorized: [], supported: [], transports: [:])
                    let a = list(block, "TransportsActive")
                    if !a.isEmpty { p.active = a }
                    let u = list(block, "TransportsUnauthorized")
                    if !u.isEmpty { p.unauthorized = u }
                    let s = list(block, "TransportsSupported")
                    if !s.isEmpty { p.supported = s }
                    found[n] = p
                }
                // Transport-level block, direct children only.
                if let td = value(block, "TransportDescription"),
                   td.hasPrefix("Port-USB-C@"),
                   td.components(separatedBy: "/").count == 2 {
                    let parts = td.components(separatedBy: "/")
                    guard let n = Int(parts[0].dropFirst("Port-USB-C@".count)) else { continue }
                    let type = parts[1]
                    guard type == "USB2" || type == "USB3" else { continue }
                    var p = found[n] ?? ProbePort(folder: folder, number: n, active: [], unauthorized: [], supported: [], transports: [:])
                    let restricted = bool(block, "TRM_TransportRestricted")
                    if p.transports[type]?.restricted == nil || restricted != nil {
                        p.transports[type] = (restricted, bool(block, "Tunneled"))
                    }
                    found[n] = p
                }
            }
        }
        return found.values.sorted { $0.number < $1.number }
    }

    // MARK: - Model construction

    private static func makeSummary(_ p: ProbePort) -> PortSummary {
        let port = AppleHPMInterface(
            id: UInt64(p.number),
            serviceName: "Port-USB-C@\(p.number)",
            className: "AppleHPMInterfaceType10",
            portDescription: "Port-USB-C@\(p.number)",
            portTypeDescription: "USB-C",
            portNumber: p.number,
            connectionActive: true,
            activeCable: nil, opticalCable: nil, usbActive: nil,
            superSpeedActive: p.active.contains("USB3"),
            usbModeType: nil, usbConnectString: nil,
            transportsSupported: p.supported,
            transportsActive: p.active,
            transportsProvisioned: [],
            plugOrientation: nil, plugEventCount: nil, connectionCount: nil,
            overcurrentCount: nil, pinConfiguration: [:], powerCurrentLimits: [],
            firmwareVersion: nil, bootFlagsHex: nil,
            rawProperties: ["PortType": "2"]
        )
        let key = "2/\(p.number)"
        let usb3 = p.transports["USB3"].map {
            [USB3Transport(
                id: UInt64(1000 + p.number), portKey: key, signaling: 2,
                signalingDescription: "Gen 2", dataRole: "host",
                transportRestricted: $0.restricted
            )]
        } ?? []
        let trm = p.transports.compactMap { type, flags -> TRMTransport? in
            TRMTransport(
                id: UInt64(2000 + p.number), portKey: key, transportType: type,
                state: 2, stateDescription: "Restricted",
                transportRestricted: flags.restricted, transportSupervised: true,
                identificationRestricted: false, deviceLocked: false,
                relaxedPeriod: nil, gracePeriodReason: nil,
                gracePeriodReasonDescription: nil,
                profile: nil, profileDescription: nil,
                cacheMiss: nil, tunnelled: flags.tunnelled
            )
        }
        return PortSummary(port: port, usb3Transports: usb3, trmTransports: trm)
    }

    private static let dataTransports: Set<String> = ["USB2", "USB3", "CIO"]

    /// True when the raw probes this sweep needs are actually on disk.
    ///
    /// A worktree is the case that matters. `.gitignore` tracks every folder's
    /// probe 01 plus `inspection.md`, but the raw probe 17 files are on disk
    /// only (28 are kept as fixtures). So a worktree has 743 folders, each with
    /// the port-level `TransportsUnauthorized` list, and almost none of the
    /// transport nodes needed to evaluate them. Reading that as "the card
    /// failed to report blocked" is wrong: the data simply is not there.
    ///
    /// This broke the private CI in a fresh worktree and blocked an unrelated
    /// push. `allFolders().isEmpty` was not enough of a guard, because the
    /// folders exist in a worktree; only their contents are thinner.
    private static func rawProbesAvailable() -> Bool {
        let withProbe17 = allFolders().filter { folder in
            FileManager.default.fileExists(
                atPath: probeRoot.appendingPathComponent(folder)
                    .appendingPathComponent("17_deep_property_dump.json").path
            )
        }
        // The fixture set is 28 folders. Anything near that means tracked
        // fixtures only, so this is a worktree or a fresh clone.
        return withProbe17.count > 100
    }

    /// Ports where EVERY active data transport is withheld: the shape where
    /// the card used to claim a live link with nothing behind it.
    ///
    /// "Every", not "any", and the corpus is why. `m5pro_macos27.0` port 1 has
    /// USB2 withheld while USB3 runs normally. That port really does have a
    /// working data link, so calling it blocked would be a new false claim in
    /// place of the old one. See `partiallyWithheldPortKeepsItsActiveLink`.
    private static func fullyWithheldCases() -> [ProbePort] {
        allFolders().flatMap { folder in
            ports(folder: folder).filter { p in
                // No parsed transport nodes means no evidence either way, not
                // evidence of a bug. Skip rather than assert.
                guard !p.transports.isEmpty else { return false }
                let activeData = Set(p.active).intersection(dataTransports)
                return !activeData.isEmpty && activeData.isSubset(of: Set(p.unauthorized))
            }
        }
    }

    /// Ports with something withheld but a healthy active transport alongside.
    private static func partiallyWithheldCases() -> [ProbePort] {
        allFolders().flatMap { folder in
            ports(folder: folder).filter { p in
                let activeData = Set(p.active).intersection(dataTransports)
                let withheld = activeData.intersection(Set(p.unauthorized))
                return !withheld.isEmpty && withheld != activeData
            }
        }
    }

    // MARK: - Tests

    @Test("Coverage: the corpus actually contains withheld-transport ports")
    func corpusContainsWithheldTransportPorts() {
        // Absent corpus directory = a worktree without raw probes, which is a
        // legitimate skip. A corpus directory that EXISTS but yields no
        // folders is a broken path or a broken enumerator, and must fail
        // rather than quietly certify everything below. Raised in review.
        var isDir: ObjCBool = false
        let rootExists = FileManager.default.fileExists(atPath: Self.probeRoot.path, isDirectory: &isDir) && isDir.boolValue
        guard rootExists else { return }
        #expect(!Self.allFolders().isEmpty, "corpus root exists at \(Self.probeRoot.path) but enumerated no folders")
        guard Self.rawProbesAvailable() else { return }   // worktree: tracked fixtures only
        let cases = Self.fullyWithheldCases()
        // Without this the sweep below passes vacuously the moment a parser
        // change stops finding anything, which is exactly how a "clean" result
        // has misled this repo before. The corpus holds 4 such machines; assert
        // a floor rather than the exact number so adding submissions is not a
        // test failure.
        #expect(
            cases.count >= 3,
            "expected the corpus to still contain fully-withheld ports, found \(cases.count). If this drops, the sweep below is proving nothing."
        )
    }

    @Test("No port with a withheld transport claims an active data link")
    func withheldTransportNeverClaimsAnActiveLink() {
        guard Self.rawProbesAvailable() else { return }   // worktree: tracked fixtures only
        for p in Self.fullyWithheldCases() {
            let summary = Self.makeSummary(p)
            #expect(
                !summary.subtitle.contains("is active"),
                "\(p.folder) port \(p.number): withheld \(p.unauthorized) while active \(p.active), but the card said: \(summary.subtitle)"
            )
            #expect(
                summary.headline.contains("data blocked"),
                "\(p.folder) port \(p.number): withheld \(p.unauthorized), expected a blocked headline, got: \(summary.headline)"
            )
        }
    }

    @Test("Ports with nothing withheld are untouched by the blocked wording")
    func unwithheldPortsKeepTheirWording() {
        guard Self.rawProbesAvailable() else { return }   // worktree: tracked fixtures only
        var checked = 0
        for folder in Self.allFolders() {
            for p in Self.ports(folder: folder) where p.unauthorized.isEmpty && !p.active.isEmpty {
                let summary = Self.makeSummary(p)
                checked += 1
                #expect(
                    !summary.headline.contains("data blocked"),
                    "\(folder) port \(p.number): nothing withheld (active \(p.active)) but the card said: \(summary.headline)"
                )
            }
        }
        #expect(checked >= 100, "expected a healthy population of unwithheld ports to compare against, got \(checked)")
    }

    @Test("A port with one withheld transport and one healthy one keeps its active link")
    func partiallyWithheldPortKeepsItsActiveLink() {
        guard Self.rawProbesAvailable() else { return }   // worktree: tracked fixtures only
        let cases = Self.partiallyWithheldCases()
        // m5pro_macos27.0 port 1: USB2 withheld, USB3 running. Real link, real
        // data. Calling that "blocked" would swap one false claim for another.
        #expect(cases.count >= 1, "expected at least one partially-withheld port in the corpus, got \(cases.count)")
        for p in cases {
            let summary = Self.makeSummary(p)
            #expect(
                !summary.headline.contains("data blocked"),
                "\(p.folder) port \(p.number): withheld \(p.unauthorized) but active \(p.active) still carries a link, got: \(summary.headline)"
            )
        }
    }
}
