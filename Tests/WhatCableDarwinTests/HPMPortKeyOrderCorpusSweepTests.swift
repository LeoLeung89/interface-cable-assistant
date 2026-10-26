import Foundation
import Testing
@testable import WhatCableDarwinBackend

// MARK: - HPMPortKeyOrderCorpusSweepTests
//
// Corpus evidence for the ordering rule `hpmPortKeys()` now applies:
// `AppleSmartBattery`'s `PortControllerInfo` array is ordered by the owning HPM
// controller's `RID`, ascending.
//
// WHY THIS MATTERS: `PortControllerInfo` entries carry no port identifier of any
// kind. Two shipped consumers (`PortDiagnosticsWatcher.portKeyMap`, which feeds
// the Pro "Port health" section, and `PowerSourceSynthesis`'s positional rung)
// tie entry N back to a physical port purely by index. So this array's order IS
// the join, and getting it wrong shows one port's attach/detach counters under
// another port's name (issue #460).
//
// GROUND TRUTH: which port currently holds the live charge contract. That is
// observable two ways, from two different probes, and they have to agree:
//
//   - probe 17 publishes `IOPortFeaturePowerSource` nodes; the one carrying a
//     `WinningPowerSourceOption` names the charging port and its wattage.
//   - probe 32 publishes `PortControllerInfo`; exactly one entry carries a
//     non-zero `PortControllerMaxPower`, and it is the same wattage.
//
// A folder is only tested when both agree on the wattage, which pins entry
// index <-> port name without going near the code under test. The RID for that
// port name comes from probe 35. The prediction is then a pure ordering claim:
// rank the ports by RID, and the charging port's rank must equal the charging
// entry's index.
//
// NOT CIRCULAR: the wattage join in `PowerControllerPortJoin` identifies only
// the LIVE entry, and says nothing about how idle entries are ordered. This
// sweep uses the live entry as an anchor to test the ordering rule that
// governs the idle ones, which is the case the shipped code cannot otherwise
// resolve.
//
// FRESH-CLONE BEHAVIOUR: probe 35 is not git-tracked, so on a fresh clone this
// sweep finds no testable folders and the coverage floor below is skipped
// rather than failed (the same two-tier arrangement the other corpus sweeps
// use). Re-fetch raw probes from KV to run it for real. The ordering mechanics
// themselves are covered unconditionally by `HPMPortKeyOrderTests`.
@Suite("hpmPortKeys RID ordering corpus sweep (probes 17 + 32 + 35)")
struct HPMPortKeyOrderCorpusSweepTests {

    // MARK: - Probe root (duplicated across sweep files by house convention)

    private static let probeRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WhatCableDarwinTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("research/customer-probes")
    }()

    private static func allProbeFolders() -> [String] {
        (try? FileManager.default
            .contentsOfDirectory(atPath: probeRoot.path)
            .filter { entry in
                var isDir: ObjCBool = false
                FileManager.default.fileExists(
                    atPath: probeRoot.appendingPathComponent(entry).path,
                    isDirectory: &isDir
                )
                return isDir.boolValue
            }
            .sorted()
        ) ?? []
    }

    private static func loadProbeText(folder: String, fileName: String) -> String? {
        let url = probeRoot.appendingPathComponent(folder).appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let text = root["output"] as? String
        else { return nil }
        return text
    }

    // MARK: - Probe 35: port name -> controller RID
    //
    // Probe 35 prints two lines per controller:
    //
    //     [0] Port-USB-C@1        class=AppleHPMDeviceHALType3
    //           UUID=ED78...-...  RID=0  Address=12
    //
    // Controllers that own no port print "(no port child)" as the name and are
    // skipped: they are internal, are not ports, and do not get a slot in
    // PortControllerInfo.

    private static func parsePortRIDs(_ text: String) -> [(port: String, rid: Int)] {
        var result: [(port: String, rid: Int)] = []
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else { continue }
            let rest = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("Port-"), let classRange = rest.range(of: "class=") else { continue }
            let name = String(rest[..<classRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            guard i + 1 < lines.count, let rid = intAfter("RID=", in: lines[i + 1]) else { continue }
            result.append((port: name, rid: rid))
        }
        return result
    }

    private static func intAfter(_ marker: String, in line: String) -> Int? {
        guard let range = line.range(of: marker) else { return nil }
        let digits = line[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    // MARK: - Probe 32: PortControllerMaxPower per entry
    //
    // Duplicated (with light renaming) from
    // `PortDiagnosticsWatcherCorpusSweepTests`, per the house rule of copying
    // shared parsing helpers into each new sweep file rather than editing an
    // existing one.

    private static func parseFirstInt(from s: String) -> Int? {
        let trimmed = s.drop(while: { $0 == " " })
        let digits = trimmed.prefix { c in c.isNumber || c == "-" }
        return Int(digits)
    }

    private static func findArraySection(_ text: String, key: String) -> String? {
        let prefix = "  \(key) = "
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix(prefix) {
                let rest = line.dropFirst(prefix.count).drop(while: { $0 == " " })
                if rest.hasPrefix("Array[") {
                    if let range = text.range(of: line) {
                        let afterLine = text[range.upperBound...]
                        if afterLine.hasPrefix("\n") { return String(afterLine.dropFirst()) }
                        return String(afterLine)
                    }
                }
            }
        }
        return nil
    }

    private static func extractMaxPowers(_ text: String) -> [Int] {
        guard let after = findArraySection(text, key: "PortControllerInfo") else { return [] }
        var powers: [Int] = []
        var current: Int?
        var inItem = false

        for line in after.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.contains("Dict[") {
                if inItem { powers.append(current ?? 0) }
                current = nil
                inItem = true
            } else if inItem, trimmed.hasPrefix("PortControllerMaxPower = ") {
                current = parseFirstInt(from: String(trimmed.dropFirst("PortControllerMaxPower = ".count)))
            } else if inItem && !trimmed.hasPrefix(" ") && !trimmed.isEmpty && !trimmed.hasPrefix("[")
                        && !trimmed.hasPrefix("PortController") {
                break
            }
        }
        if inItem { powers.append(current ?? 0) }
        return powers
    }

    // MARK: - Probe 17: which port is charging, and at what wattage

    /// Every `IOPortFeaturePowerSource` block that carries a
    /// `WinningPowerSourceOption`, as (port name, winning max power in mW).
    private static func parseWinningSources(_ text: String) -> [(port: String, milliwatts: Int)] {
        var result: [(port: String, milliwatts: Int)] = []
        let blocks = text.components(separatedBy: "--- IOPortFeaturePowerSource[")
        for block in blocks.dropFirst() {
            var body = block
            for sep in ["\n---", "\n==="] {
                if let r = body.range(of: sep) { body = String(body[..<r.lowerBound]) }
            }
            guard let winRange = body.range(of: "WinningPowerSourceOption: {") else { continue }
            // Anchored to the start of its own line on purpose: an unanchored
            // search for "Description: \"" matches inside
            // `ParentPortTypeDescription: "MagSafe 3"`, which appears first in
            // every block and yields a garbage port name.
            guard let descRange = body.range(of: "\n  Description: \"") else { continue }
            let afterDesc = body[descRange.upperBound...]
            guard let slash = afterDesc.firstIndex(of: "/") else { continue }
            let port = String(afterDesc[..<slash])

            let afterWin = body[winRange.upperBound...]
            guard let mwRange = afterWin.range(of: "Max Power (mW): ") else { continue }
            guard let mw = parseFirstInt(from: String(afterWin[mwRange.upperBound...])) else { continue }
            result.append((port: port, milliwatts: mw))
        }
        return result
    }

    // MARK: - The sweep

    @Test("RID order reproduces PortControllerInfo's order on every corpus machine")
    func ridOrderMatchesPortControllerInfoOrder() {
        var tested = 0
        var magSafeTested = 0
        var agreed = 0
        var failures: [String] = []
        // Reasons a folder was not testable, printed so a change in corpus
        // shape shows up as a shift in these counts rather than silently
        // shrinking the sample.
        var skippedNoProbe = 0
        var skippedShape = 0
        var skippedNoGroundTruth = 0

        for folder in Self.allProbeFolders() {
            guard let probe32 = Self.loadProbeText(folder: folder, fileName: "32_smart_battery_full_keys.json"),
                  let probe35 = Self.loadProbeText(folder: folder, fileName: "35_hpm_port_uuid.json"),
                  let probe17 = Self.loadProbeText(folder: folder, fileName: "17_deep_property_dump.json")
            else { skippedNoProbe += 1; continue }

            let powers = Self.extractMaxPowers(probe32)
            let ports = Self.parsePortRIDs(probe35)
            guard !powers.isEmpty, !ports.isEmpty, powers.count == ports.count else {
                skippedShape += 1
                continue
            }

            // Exactly one live charge contract, or the anchor is ambiguous.
            let live = powers.enumerated().filter { $0.element > 0 }
            guard live.count == 1 else { skippedNoGroundTruth += 1; continue }
            let liveIndex = live[0].offset
            let liveMilliwatts = live[0].element

            // Probe 17 must independently name one charging port at the same
            // wattage. Probes 17 and 32 are separate captures seconds apart, so
            // a charger swapped between them shows up as a wattage mismatch and
            // is discarded rather than tested against stale ground truth.
            let names = Set(ports.map(\.port))
            let winners = Self.parseWinningSources(probe17)
                .filter { names.contains($0.port) && Self.wattsAgree($0.milliwatts, liveMilliwatts) }
            guard Set(winners.map(\.port)).count == 1, let chargingPort = winners.first?.port else {
                skippedNoGroundTruth += 1
                continue
            }

            // The claim under test, stated as an ordering: rank the ports by
            // controller RID and the charging port lands at the charging
            // entry's index.
            //
            // Deliberately runs the SHIPPED comparator,
            // `PowerService.orderedPortKeys`, rather than sorting
            // inline. An inline `sorted { $0.rid < $1.rid }` here would prove
            // the rule while testing none of the code, so flipping the shipped
            // comparator to `>` would leave this sweep passing 133/133. It is
            // fed port NAMES instead of port keys, which is fine: the function
            // orders opaque strings by their RID and never looks at them.
            let byRID = PowerService.orderedPortKeys(
                ports.map { (key: $0.port, rid: Optional($0.rid)) }
            )
            guard let predictedIndex = byRID.firstIndex(of: chargingPort) else {
                skippedShape += 1
                continue
            }

            tested += 1
            if chargingPort.hasPrefix("Port-MagSafe") { magSafeTested += 1 }
            if predictedIndex == liveIndex {
                agreed += 1
            } else {
                failures.append("\(folder): charging \(chargingPort) is PortControllerInfo entry "
                    + "[\(liveIndex)] but RID order puts it at [\(predictedIndex)] "
                    + "(RIDs: \(ports.map { "\($0.port)=\($0.rid)" }.joined(separator: ", ")))")
            }
        }

        print("[HPMPortKeyOrderSweep] \(tested) machines testable (\(magSafeTested) via MagSafe), "
            + "\(agreed) agree, \(failures.count) disagree. Skipped: "
            + "\(skippedNoProbe) missing a probe, \(skippedShape) shape mismatch, "
            + "\(skippedNoGroundTruth) no unambiguous charge anchor.")

        let failureReport = failures.prefix(10).joined(separator: "\n")
        #expect(failures.isEmpty, "RID order failed on \(failures.count) machines:\n\(failureReport)")

        // Coverage floor. Measured against the corpus as committed on `main`,
        // with its raw probes re-fetched: 133 machines testable, 51 of them via
        // MagSafe, all 133 agreeing. A working folder that also holds probe
        // batches not yet ingested reaches 246 / 86; the floor is pinned to the
        // smaller committed figure on purpose, so it does not depend on how
        // recently anyone ran the fetcher. Both floors sit meaningfully under
        // the measured values so ordinary corpus churn doesn't fail the build,
        // while a parser regression that silently stops finding folders does.
        //
        // Gated on having found any testable folder at all, because probe 35 is
        // not git-tracked: on a fresh clone `tested` is 0 and the floor is
        // skipped rather than failed. See the file header.
        if tested > 0 {
            #expect(tested >= 100,
                "only \(tested) machines testable; the committed corpus supports 133, so the parsers or the corpus shape have changed")
            #expect(magSafeTested >= 35,
                "only \(magSafeTested) MagSafe machines testable; the committed corpus supports 51, and MagSafe is the port issue #460 was reported against")
        }
    }

    /// Probes 17 and 32 report the same contract from two different subsystems,
    /// which round slightly differently (44850 vs 44800 mW is a real corpus
    /// pair). 5% is comfortably tighter than the gap between adjacent PD power
    /// tiers, so it cannot merge two different chargers.
    private static func wattsAgree(_ a: Int, _ b: Int) -> Bool {
        guard a > 0, b > 0 else { return false }
        return abs(a - b) * 20 <= max(a, b)
    }
}
