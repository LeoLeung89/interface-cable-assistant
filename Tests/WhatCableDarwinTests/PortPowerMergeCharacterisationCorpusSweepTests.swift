import Foundation
import Testing
@testable import WhatCableCore
@testable import WhatCableDarwinBackend

// MARK: - Characterisation harness for the per-port power merge
//
// WHAT THIS IS FOR. The power slice is being consolidated across several PRs.
// Every one of them except the last is supposed to change no behaviour at all.
// "No behaviour change" is easy to claim and hard to show, because the thing
// being moved is a precedence rule: a refactor can keep every wattage identical
// while quietly changing WHICH SOURCE produced it, and no watts-only comparison
// would notice.
//
// So this file records, per machine and per port, the decision rather than the
// number: which reader won, the two provenance booleans the UI branches on, and
// the machine-level `perPortMeteringSupported` / `hasContract` flags. Those
// records are compared against a committed baseline. A phase that reorders the
// merge fails here even if the watts are unchanged.
//
// WHERE GROUND TRUTH COMES FROM. Nothing here re-derives what the merge should
// have said. The inputs are real probe data run through the real production
// factories (`AppleHPMInterface.from`, `PowerSourceWatcher.makeSource`,
// `SMCPowerReader.decodeFloat`, `HPMPortUUIDMap.from`), and the baseline is the
// recorded output of the code as it stood when the seam was extracted. That
// makes this a characterisation test: it pins current behaviour, including any
// current bug, which is exactly what a refactor needs. It is NOT a correctness
// oracle, and the assertions that DO claim correctness (below) are stated as
// physical bounds and cross-checks against independently-printed values, never
// against the merge's own opinion.
//
// PROVED ABLE TO FAIL, AND PROVED BLIND IN ONE PLACE. Four deliberate breaks
// were applied to `PortPowerMerge.merge` and this suite run against each. The
// results are recorded here because two of them are the interesting ones:
//
//   caught, 302 of 715 rows changed  `matchedChannels` counted only powered
//                                    channels, so an idle-but-metered Mac
//                                    reported no per-port metering
//   caught,  88 of 715 rows changed  the cable-resistance feed built
//                                    contract-first instead of
//                                    PowerOutDetails-first
//   NOT caught, 0 rows changed       the contract filled ahead of the SMC
//   NOT caught, 0 rows changed       the contract filled ahead of PowerOutDetails
//
// The probe-32 section-bounding guard was break-tested the same way: removing
// the bounding in `CorpusPowerProbes.probe32Properties` produces 2340 failures
// (585 dumps x 4 Manager-only keys). Removing the bounding does NOT move a
// single baseline row, which is the useful part: it proves the one real
// collision in the corpus is on a key nothing in the power path reads.
//
// The two misses are not a gap in the corpus, and no amount of extra
// submissions would close them. An SMC channel reports power the Mac is
// sourcing OUT of a port; a contract is what a charger negotiated to push power
// IN. A port doing one is not doing the other, so on real machines the two
// never land on the same port key: the whole 715-row baseline is 256 SMC rows,
// 128 contract rows and 3 PowerOutDetails rows, with no port appearing twice.
//
// So the precedence ORDER is pinned by unit tests instead
// (`PortPowerMergeTests` in WhatCableCoreTests, which put both sources on one
// port deliberately; the same "contract ahead of SMC" break fails 7 of its 12
// tests). What this file pins is everything the order alone does not: which
// source actually won on each real machine, the machine-level metering and
// contract flags, and the exact composition of the resistance feed. Neither
// suite is sufficient alone.
//
// CORPUS REALITY. Probes 32, 34 and 35 have ZERO git-tracked fixtures, so on a
// fresh clone there is nothing to replay and every test here skips rather than
// failing. Run it after fetching the raw corpus from KV. Probe 17 and probe 32
// are also truncated at the 64 KB pipe cap on real machines (166 of 751
// probe-32 dumps), and those are dropped rather than read as "key absent".
@Suite("Port power merge - characterisation sweep (probes 17/32/34/35)")
struct PortPowerMergeCharacterisationCorpusSweepTests {

    /// Below this many replayable machines we are on a fresh clone (or a
    /// partial fetch) and the baseline cannot be meaningfully compared. Well
    /// above zero so a broken parser cannot quietly turn the whole suite into a
    /// skip.
    private static let corpusPresenceThreshold = 50

    /// One recorded decision. Deliberately a flat string: a diff of these lines
    /// is the useful output when a phase changes something, and a structured
    /// type would need its own Equatable-and-print plumbing to say the same
    /// thing.
    private struct Record {
        let folder: String
        let line: String
    }

    // MARK: - Replay

    private struct MachineInputs {
        let folder: String
        let ports: [AppleHPMInterface]
        let uuidMap: [String: String]
        let smcChannels: [SMCPortPowerChannel]
        let batteryProperties: [String: Any]
        let powerSources: [PowerSource]
    }

    /// Everything the merge needs for one machine, or nil when that machine
    /// does not carry all four probes.
    private static func inputs(for folder: String) -> MachineInputs? {
        guard let probe35 = CorpusPowerProbes.text(folder: folder, probe: "35_hpm_port_uuid"),
              let probe34 = CorpusPowerProbes.text(folder: folder, probe: "34_smc_power_keys"),
              let probe32 = CorpusPowerProbes.text(folder: folder, probe: "32_smart_battery_full_keys"),
              let probe17 = CorpusPowerProbes.text(folder: folder, probe: "17_deep_property_dump")
        else { return nil }

        let records = CorpusPowerProbes.probe35Records(probe35)
        let ports = CorpusPowerProbes.hpmPorts(from: records)
        guard !ports.isEmpty else { return nil }

        return MachineInputs(
            folder: folder,
            ports: ports,
            // The production map, not a re-derivation: the same call the live
            // watcher makes from published HPM ports.
            uuidMap: HPMPortUUIDMap.from(ports: ports),
            smcChannels: CorpusPowerProbes.probe34RawChannels(probe34).map(CorpusPowerProbes.smcChannel(from:)),
            batteryProperties: CorpusPowerProbes.probe32Properties(probe32),
            powerSources: CorpusPowerProbes.powerSources(from: probe17)
        )
    }

    /// Runs the real merge over one machine's inputs and renders its decisions.
    private static func replay(_ machine: MachineInputs) -> [Record] {
        let portKeys = machine.ports.compactMap(\.portKey)
        let podSamples = PowerService.portPowerSamples(
            from: machine.batteryProperties["PowerOutDetails"],
            portKeys: portKeys
        )
        let contractedSamples = PowerService.portPowerSamplesFromControllerInfo(
            machine.batteryProperties["PortControllerInfo"],
            sources: machine.powerSources
        )
        let merged = PortPowerMerge.merge(
            smcChannels: machine.smcChannels,
            uuidMap: machine.uuidMap,
            powerOutDetailSamples: podSamples,
            contractedSamples: contractedSamples
        )

        // FINDING, recorded here because it bit this file first. The contracted
        // samples come out of a `Dictionary(grouping:)` in
        // `portPowerSamplesFromControllerInfo`, and Swift seeds its hashing per
        // process, so their order differs between test RUNS. Within one process
        // it is stable, so the live app cannot see a port flip source between
        // ticks. The keys below are therefore sorted before recording: an
        // unsorted record made this suite pass alone and fail inside the full
        // run, which is a flaky test rather than a found bug. Giving that
        // ordering a deterministic source belongs in the phase that
        // consolidates the parser, not in a no-behaviour-change phase.
        //
        // The two machine-level flags the Power Monitor branches on, computed
        // the same way `PowerService.refresh()` computes them.
        let externalConnected = machine.batteryProperties["ExternalConnected"].map(wcBool) ?? true
        let batteryInstalled = wcBool(machine.batteryProperties["BatteryInstalled"])
        let hasContract = externalConnected && machine.powerSources.contains { $0.winning != nil }

        var records: [Record] = [
            Record(
                folder: machine.folder,
                line: "\(machine.folder)|@machine"
                    + "|metering=\(merged.perPortMeteringSupported)"
                    + "|contract=\(hasContract)"
                    + "|external=\(externalConnected)"
                    + "|battery=\(batteryInstalled)"
                    + "|ports=\(machine.ports.count)"
                // The `resistanceFeed=` component recorded the removed
                // `meteredSamples` feed (charging-path resistance rework, 2026-08); the baseline was
                // regenerated without it in the same change.
            )
        ]

        for sample in merged.displaySamples.sorted(by: { $0.portKey < $1.portKey }) {
            let provenance = merged.provenance[sample.portKey]?.rawValue ?? "none"
            records.append(Record(
                folder: machine.folder,
                line: "\(machine.folder)|\(sample.portKey)"
                    + "|from=\(provenance)"
                    + "|smc=\(sample.isSMCMeasured)"
                    + "|contracted=\(sample.isContractedFallback)"
                    + "|mW=\(sample.watts)"
                    + "|mV=\(sample.configuredVoltage)"
                    + "|mA=\(sample.current)"
            ))
        }
        return records
    }

    private static func replayWholeCorpus() -> (records: [Record], machines: Int) {
        var records: [Record] = []
        var machines = 0
        for folder in CorpusPowerProbes.folders() {
            guard let machine = inputs(for: folder) else { continue }
            machines += 1
            records.append(contentsOf: replay(machine))
        }
        return (records, machines)
    }

    // MARK: - Baseline file

    /// Lives under `research/`, not next to this file, for two reasons.
    ///
    /// It is derived from the customer-probe corpus and names 328 corpus
    /// folders, so it is the same class of private data the rest of
    /// `research/` holds and it must not reach the public mirror.
    /// `.public-exclude` already filters `research/`, so putting it there needs
    /// no new rule. A plain text file inside a test target's own directory is
    /// also an unhandled build input that SPM warns about on every build.
    ///
    /// The public mirror has no raw corpus either, so the presence gate above
    /// returns before this file is ever opened there.
    private static let baselineURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // WhatCableDarwinTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("research/corpus-baselines/port-power-merge.txt")

    /// folder -> its recorded lines, in file order.
    private static func loadBaseline() -> [String: [String]] {
        guard let text = try? String(contentsOf: baselineURL, encoding: .utf8) else { return [:] }
        var grouped: [String: [String]] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = String(line)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let folder = trimmed.split(separator: "|").first
            else { continue }
            grouped[String(folder), default: []].append(trimmed)
        }
        return grouped
    }

    // MARK: - Tests

    @Test("Merge decisions match the recorded baseline on every machine the baseline covers")
    func mergeDecisionsMatchBaseline() throws {
        let (records, machines) = Self.replayWholeCorpus()

        // Regeneration path, used deliberately and never in CI:
        //   WC_UPDATE_POWER_MERGE_BASELINE=1 swift test --filter PortPowerMerge
        // Writing the baseline from the current code is only ever correct when
        // the current code is the reference, i.e. right after the seam was
        // extracted, or after a phase whose behaviour change was reviewed line
        // by line.
        if ProcessInfo.processInfo.environment["WC_UPDATE_POWER_MERGE_BASELINE"] == "1" {
            let header = """
            # Recorded decisions of PortPowerMerge.merge across the customer-probe corpus.
            # Regenerate with WC_UPDATE_POWER_MERGE_BASELINE=1; see the suite doc comment
            # before you do. A diff here is a behaviour change, not a formatting change.
            """
            let body = records.map(\.line).sorted().joined(separator: "\n")
            try FileManager.default.createDirectory(
                at: Self.baselineURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try (header + "\n" + body + "\n").write(to: Self.baselineURL, atomically: true, encoding: .utf8)
            print("[PortPowerMergeCharacterisation] wrote \(records.count) baseline rows from \(machines) machines")
            return
        }

        guard machines >= Self.corpusPresenceThreshold else {
            print("[PortPowerMergeCharacterisation] only \(machines) replayable machines on disk "
                + "(need \(Self.corpusPresenceThreshold)); raw corpus not fetched, skipping")
            return
        }

        let baseline = Self.loadBaseline()
        #expect(!baseline.isEmpty, "baseline file missing or empty at \(Self.baselineURL.path)")

        var current: [String: [String]] = [:]
        for record in records { current[record.folder, default: []].append(record.line) }

        var matchedFolders = 0
        var matchedRows = 0
        var mismatches: [String] = []
        var missingFolders = 0

        for (folder, expectedLines) in baseline.sorted(by: { $0.key < $1.key }) {
            guard let actualLines = current[folder] else {
                missingFolders += 1
                continue
            }
            matchedFolders += 1
            let expected = expectedLines.sorted()
            let actual = actualLines.sorted()
            matchedRows += expected.count
            if expected != actual {
                let added = Set(actual).subtracting(expected).sorted()
                let removed = Set(expected).subtracting(actual).sorted()
                for line in removed { mismatches.append("- \(line)") }
                for line in added { mismatches.append("+ \(line)") }
            }
        }

        let newFolders = Set(current.keys).subtracting(baseline.keys).count

        print("[PortPowerMergeCharacterisation] \(machines) machines replayed, "
            + "\(matchedFolders) matched the baseline (\(matchedRows) rows), "
            + "\(newFolders) new machines not in the baseline, "
            + "\(missingFolders) baseline machines no longer on disk")

        if !mismatches.isEmpty {
            // Cap the printed diff: a genuine ordering regression changes
            // hundreds of rows and the first few say the same thing as all of
            // them.
            let shown = mismatches.prefix(40).joined(separator: "\n")
            Issue.record("""
            Merge decisions changed against the recorded baseline (\(mismatches.count) differing rows).
            This is a behaviour change. If it is intended, review every line, then regenerate with
            WC_UPDATE_POWER_MERGE_BASELINE=1.
            \(shown)
            """)
        }

        // Non-vacuity floor. The baseline was recorded from 328 machines and
        // 715 rows. A floor of 600 leaves room for the corpus being re-ingested
        // (folder suffix letters are positional and can move between machines)
        // while still failing loudly if the replay stopped producing rows.
        #expect(matchedRows >= 600,
            "only \(matchedRows) baseline rows were actually compared; the replay has gone vacuous")
    }

    @Test("Replayed merge inputs are physically sane and the SMC decode agrees with the probe's own")
    func replayedInputsAreSane() {
        var machines = 0
        var channelsChecked = 0
        var decodeMismatches = 0
        var samplesChecked = 0

        for folder in CorpusPowerProbes.folders() {
            guard let probe34 = CorpusPowerProbes.text(folder: folder, probe: "34_smc_power_keys") else { continue }
            let raws = CorpusPowerProbes.probe34RawChannels(probe34)
            guard !raws.isEmpty else { continue }
            machines += 1

            for raw in raws {
                channelsChecked += 1
                let channel = CorpusPowerProbes.smcChannel(from: raw)
                // Cross-check: the production float decoder against the value
                // the C probe printed independently. Two separate decodes of
                // the same bytes agreeing is real evidence; the production
                // decoder agreeing with itself would not be.
                if let printed = raw.printedVolts, abs(printed - channel.volts) > 0.001 {
                    decodeMismatches += 1
                    Issue.record("\(folder) D\(raw.index)JV: probe printed \(printed), production decode \(channel.volts)")
                }
                if let printed = raw.printedAmps, abs(printed - channel.amps) > 0.001 {
                    decodeMismatches += 1
                    Issue.record("\(folder) D\(raw.index)JI: probe printed \(printed), production decode \(channel.amps)")
                }
                #expect(channel.volts >= 0, "\(folder) D\(raw.index): negative volts")
                #expect(channel.volts <= 60, "\(folder) D\(raw.index): \(channel.volts) V exceeds the 48 V EPR ceiling plus headroom")
                #expect(channel.amps >= 0, "\(folder) D\(raw.index): negative amps")
            }

            guard let machine = Self.inputs(for: folder) else { continue }
            let merged = PortPowerMerge.merge(
                smcChannels: machine.smcChannels,
                uuidMap: machine.uuidMap,
                powerOutDetailSamples: PowerService.portPowerSamples(
                    from: machine.batteryProperties["PowerOutDetails"],
                    portKeys: machine.ports.compactMap(\.portKey)
                ),
                contractedSamples: PowerService.portPowerSamplesFromControllerInfo(
                    machine.batteryProperties["PortControllerInfo"],
                    sources: machine.powerSources
                )
            )
            for sample in merged.displaySamples {
                samplesChecked += 1
                // USB PD EPR tops out at 240 W (48 V / 5 A). A mV-vs-mW mix-up,
                // the historical bug class in this area, overshoots by 1000x.
                #expect(sample.watts >= 0 && sample.watts <= 240_000,
                    "\(folder) \(sample.portKey): watts \(sample.watts) outside 0..240000 mW")
                #expect(sample.configuredVoltage >= 0 && sample.configuredVoltage <= 48_000,
                    "\(folder) \(sample.portKey): voltage \(sample.configuredVoltage) outside 0..48000 mV")
                // Every displayed sample must carry a provenance: a port in the
                // display list with no recorded winner means the merge added it
                // by a path that forgot to say where it came from.
                #expect(merged.provenance[sample.portKey] != nil,
                    "\(folder) \(sample.portKey): displayed with no provenance recorded")
            }
        }

        print("[PortPowerMergeCharacterisation] sanity: \(machines) machines, \(channelsChecked) SMC channels "
            + "(\(decodeMismatches) decode mismatches), \(samplesChecked) merged samples")

        guard machines >= Self.corpusPresenceThreshold else { return }
        #expect(decodeMismatches == 0, "the production SMC float decode must agree with the probe's own decode")
        // Floors at roughly 85% of the counts measured when this landed
        // (1233 SMC channels, 385 merged samples), so a parser that silently
        // stops finding anything fails rather than passing clean.
        #expect(channelsChecked >= 1000, "only \(channelsChecked) SMC channels parsed; the probe-34 parser has gone quiet")
        #expect(samplesChecked >= 320, "only \(samplesChecked) merged samples produced; the replay has gone quiet")
    }

    @Test("The probe-32 parser recovers the nested containers the power path reads")
    func probe32ParserRecoversNestedContainers() {
        // Make the parser find things already known to be there, rather than
        // trusting a clean run. Both keys below are arrays of dictionaries, the
        // shape a flat key/value scan cannot represent at all.
        var foldersWithPowerOutDetails = 0
        var foldersWithControllerInfo = 0
        var entriesWithPDOs = 0
        var entriesWithMaxPower = 0
        var foldersWhereNoEntryHasMaxPower = 0
        var scanned = 0

        for folder in CorpusPowerProbes.folders() {
            guard let text = CorpusPowerProbes.text(folder: folder, probe: "32_smart_battery_full_keys") else { continue }
            scanned += 1
            let props = CorpusPowerProbes.probe32Properties(text)

            // The dump has three top-level sections and they print at the same
            // indent, so a parser that only strips the headers merges all three.
            // These four keys appear in all 585 dumps but ONLY under
            // `AppleSmartBatteryManager`, so finding any of them here means the
            // section bounding in `probe32Properties` has stopped working and
            // the replay inputs are contaminated. This guard fails on every
            // dump if the bounding is removed, which is how it was checked.
            for managerOnlyKey in ["IOClass", "IOProbeScore", "IOProviderClass", "CFBundleIdentifier"] {
                #expect(props[managerOnlyKey] == nil,
                    "\(folder): \(managerOnlyKey) belongs to AppleSmartBatteryManager, so the probe-32 parse has run past the battery section")
            }

            let powerOut = wcArray(props["PowerOutDetails"])
            if !powerOut.isEmpty {
                foldersWithPowerOutDetails += 1
                for entry in powerOut {
                    let dict = wcDictionary(entry)
                    #expect(!dict.isEmpty, "\(folder): PowerOutDetails entry parsed as an empty dict")
                    // Present on every real entry seen; its absence means the
                    // nested dict was flattened away.
                    #expect(dict["ConfiguredVoltage"] != nil || dict["Watts"] != nil,
                        "\(folder): PowerOutDetails entry carries neither ConfiguredVoltage nor Watts")
                }
            }

            let controllerInfo = wcArray(props["PortControllerInfo"])
            if !controllerInfo.isEmpty {
                foldersWithControllerInfo += 1
                var withMaxPowerHere = 0
                for entry in controllerInfo {
                    let dict = wcDictionary(entry)
                    if dict["PortControllerMaxPower"] != nil {
                        entriesWithMaxPower += 1
                        withMaxPowerHere += 1
                    }
                    if !wcArray(dict["PortControllerPortPDO"]).isEmpty { entriesWithPDOs += 1 }
                }
                // `PortControllerMaxPower` is missing on three real machines
                // (M1 Max on 14.8.2, M1 Pro on 14.8.3, M2 on 14.6), where every
                // entry is a one-key `Dict[1]` carrying only the
                // `PortControllerEvtBuffer` blob. That is a property of the OS
                // build, not of an individual entry, so the invariant worth
                // asserting is all-or-nothing per machine: a mixture would mean
                // the nested parse dropped entries at random, which is the
                // failure mode a flat "every entry has it" assertion was
                // conflating with the real thing.
                if withMaxPowerHere == 0 {
                    foldersWhereNoEntryHasMaxPower += 1
                } else {
                    let message = "\(folder): \(withMaxPowerHere) of \(controllerInfo.count) PortControllerInfo "
                        + "entries carry PortControllerMaxPower; a partial set means entries were dropped in parsing"
                    #expect(withMaxPowerHere == controllerInfo.count, "\(message)")
                }
            }
        }

        print("[PortPowerMergeCharacterisation] probe-32 parse: \(scanned) dumps, "
            + "\(foldersWithPowerOutDetails) with PowerOutDetails, \(foldersWithControllerInfo) with PortControllerInfo, "
            + "\(entriesWithMaxPower) entries with MaxPower across \(foldersWithControllerInfo - foldersWhereNoEntryHasMaxPower) machines "
            + "(\(foldersWhereNoEntryHasMaxPower) machines publish none), "
            + "\(entriesWithPDOs) entries with a PDO list")

        guard scanned >= Self.corpusPresenceThreshold else { return }
        // Floors set at roughly 85% of the counts measured when this landed
        // (585 dumps, 198 / 457 / 1329), the same headroom the sibling sweeps
        // use. These are the two containers the whole power path stands on, so
        // "found none" is a parser bug, never a fact about the data.
        #expect(foldersWithPowerOutDetails >= 165,
            "only \(foldersWithPowerOutDetails) dumps yielded a PowerOutDetails array; the nested parse has broken")
        #expect(foldersWithControllerInfo >= 380,
            "only \(foldersWithControllerInfo) dumps yielded a PortControllerInfo array; the nested parse has broken")
        #expect(entriesWithPDOs >= 1100,
            "only \(entriesWithPDOs) controller entries carried a PDO list; the nested array parse has broken")
    }

    @Test("AppleSmartBatteryReader's real parsers run over recorded probe data")
    func appleSmartBatteryReaderParsesCorpusData() {
        // This is the seam `AppleSmartBatteryReaderCorpusSweepTests` documented
        // as missing: until `parse(read:)` existed, that file could not call a
        // single line of the reader's own parsing and had to re-implement the
        // extraction it wanted to check. Now the real parsers run.
        var dumpsOnDisk = 0
        var parsed = 0
        var laptops = 0
        var withPortControllerEntries = 0

        for folder in CorpusPowerProbes.folders() {
            guard let text = CorpusPowerProbes.text(folder: folder, probe: "32_smart_battery_full_keys") else { continue }
            // Counted BEFORE the parse. Gating the whole test on `parsed` would
            // mean a parser that returned empty for every dump made this test
            // pass while exercising nothing, which is the vacuous-pass trap the
            // house rules call out. Codex review of the commit that added this
            // file caught exactly that. The presence gate now keys on the raw
            // files, so a dead parser fails the floor below instead of skipping.
            dumpsOnDisk += 1
            let props = CorpusPowerProbes.probe32Properties(text)
            guard !props.isEmpty else { continue }
            parsed += 1

            let result = AppleSmartBatteryReader.parse(read: { props[$0] })

            // The desktop gate is the reader's own first decision.
            let installed = wcBool(props["BatteryInstalled"])
            #expect(result.isDesktopMac == !installed,
                "\(folder): isDesktopMac \(result.isDesktopMac) disagrees with BatteryInstalled \(installed)")

            guard let battery = result.battery else { continue }
            laptops += 1

            // Values must survive the parse, checked against the raw dict this
            // test read separately rather than against the parser's own view.
            #expect(battery.voltage == wcInt(props["Voltage"]), "\(folder): Voltage did not survive parse")
            #expect(battery.cycleCount == wcInt(props["CycleCount"]), "\(folder): CycleCount did not survive parse")
            #expect(battery.externalConnected == wcBool(props["ExternalConnected"]),
                "\(folder): ExternalConnected did not survive parse")

            let rawEntries = wcArray(props["PortControllerInfo"])
            #expect(battery.portControllerInfo.count == rawEntries.count,
                "\(folder): parsed \(battery.portControllerInfo.count) PortControllerInfo entries from \(rawEntries.count) raw")
            if !battery.portControllerInfo.isEmpty { withPortControllerEntries += 1 }

            if let watts = battery.adapterDetails?.watts {
                #expect((0...300).contains(watts), "\(folder): adapter watts \(watts) outside 0-300 W")
            }
        }

        print("[PortPowerMergeCharacterisation] AppleSmartBatteryReader.parse: \(dumpsOnDisk) dumps on disk, "
            + "\(parsed) parsed, \(laptops) with a battery, \(withPortControllerEntries) with PortControllerInfo entries")

        guard dumpsOnDisk >= Self.corpusPresenceThreshold else { return }
        #expect(parsed >= 490,
            "\(parsed) of \(dumpsOnDisk) dumps parsed to a non-empty property dict; the probe-32 parser has broken")
        #expect(laptops >= 380, "only \(laptops) dumps produced a battery model; the seam or the parser has broken")
        #expect(withPortControllerEntries >= 380,
            "only \(withPortControllerEntries) dumps produced PortControllerInfo entries")
    }
}
