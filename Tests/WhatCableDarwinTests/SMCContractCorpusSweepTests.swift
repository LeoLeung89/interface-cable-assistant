import Foundation
import Testing
@testable import WhatCableCore
@testable import WhatCableDarwinBackend

// MARK: - Does the issue-491 fix fire where it should, and stay quiet elsewhere?
//
// The unit tests pin the gates on hand-built inputs. This replays real machines
// through the same function, because the two questions that actually decide
// whether this fix is safe to ship cannot be answered by fixtures:
//
//   1. Does it produce a contract on the silicon that needs it, or is the whole
//      thing an elaborate no-op?
//   2. Does it stay silent on every machine where macOS already answers, which
//      is the fail-open risk?
//
// Inputs are real: probe 34 for the SMC contract keys, probe 35 for the port
// and controller-UUID map, probe 17 for the power-source nodes macOS publishes.
// The function under test is the shipping one.
//
// WHAT THIS SWEEP CANNOT SHOW, and it is the important part.
//
// It cannot demonstrate the fix on M1 Pro / Max / Ultra, which is the silicon
// the fix exists for. Probe 17 is the only probe carrying a port's connection
// state, and its C source enumerates only `AppleHPMInterfaceType10` and
// `Type11` as root classes. Those machines publish neither, so their probe-17
// dumps contain no port blocks at all: `m1max_macos26.5.2` is 9747 bytes with
// zero `AppleHPMInterfaceType` blocks and no `ConnectionActive` anywhere.
//
// So every M1 Pro/Max machine is skipped here for want of replayable ports,
// and the skip is COUNTED rather than hidden behind a bare `continue`, because
// the first version of this file dropped them silently and reported a
// confident "0 synthesized" that looked like a broken fix.
//
// What this sweep therefore does prove: the fix stays quiet on every machine
// where macOS already answers (the fail-open risk), and it is not an inert
// no-op, since it does fire on the A18 Pro machines that share the
// no-power-source-node shape. What it does NOT prove is that it fires on the
// reporter's hardware. Only his machine can show that, and the plan said so:
// his own submission predates probe 35 entirely.
//
// CORPUS REALITY: none of these three probes has git-tracked fixtures, so this
// skips entirely on a fresh clone rather than pretending to have run.
@Suite("SMC charging contract - corpus sweep (probes 17/34/35)")
struct SMCContractCorpusSweepTests {

    private static let presenceThreshold = 50

    /// Parses the contract keys out of probe 34, the same three the reader
    /// takes, decoded the same big-endian way.
    private static func contracts(in text: String) -> [SMCPortContract] {
        var uuid: [Int: String] = [:]
        var power: [Int: Int] = [:]
        var volts: [Int: Int] = [:]
        var amps: [Int: Int] = [:]
        var label: [Int: String] = [:]

        for rawLine in text.split(separator: "\n") {
            let tokens = rawLine.split(separator: " ", omittingEmptySubsequences: true)
            guard let key = tokens.first, key.count == 4, key.hasPrefix("D"),
                  let index = key.dropFirst().first?.wholeNumberValue, (1...4).contains(index)
            else { continue }
            let field = String(key.suffix(2))
            guard let raw = tokens.first(where: { $0.hasPrefix("raw=") }).map({ String($0.dropFirst(4)) }) else { continue }
            var bytes: [UInt8] = []
            var idx = raw.startIndex
            while let next = raw.index(idx, offsetBy: 2, limitedBy: raw.endIndex) {
                guard let byte = UInt8(raw[idx..<next], radix: 16) else { bytes = []; break }
                bytes.append(byte)
                idx = next
            }
            switch field {
            case "UI": uuid[index] = HPMPortUUIDMap.normalise(raw)
            case "MP": power[index] = SMCPowerReader.decodeBigEndianInt(bytes) ?? 0
            case "MV": volts[index] = SMCPowerReader.decodeBigEndianInt(bytes) ?? 0
            case "MI": amps[index] = SMCPowerReader.decodeBigEndianInt(bytes) ?? 0
            case "DE":
                let trimmed = Array(bytes.prefix { $0 != 0 })
                label[index] = trimmed.isEmpty ? "" : String(decoding: trimmed, as: UTF8.self)
            default: break
            }
        }

        return (1...4).compactMap { index in
            guard let u = uuid[index], !u.isEmpty, let p = power[index], p > 0 else { return nil }
            return SMCPortContract(
                channel: index, uuid: u, powerMW: p,
                voltageMV: volts[index] ?? 0, currentMA: amps[index] ?? 0,
                label: label[index] ?? ""
            )
        }
    }

    @Test("Fires on the silicon that needs it, and never where macOS already answers")
    func firesOnlyWhereNeeded() {
        var machines = 0
        var withContractKeys = 0
        var synthesized = 0
        var synthesizedChips: [String: Int] = [:]
        var firedDespiteRealContract = 0
        var firedOnMagSafe = 0
        var noUUIDMap = 0
        var realContractWins = 0
        var noChannelResolved = 0
        var portNotConnected = 0
        var skippedNoPorts = 0
        var skippedChips: [String: Int] = [:]

        for folder in CorpusPowerProbes.folders() {
            guard let probe34 = CorpusPowerProbes.text(folder: folder, probe: "34_smc_power_keys"),
                  let probe35 = CorpusPowerProbes.text(folder: folder, probe: "35_hpm_port_uuid"),
                  let probe17 = CorpusPowerProbes.text(folder: folder, probe: "17_deep_property_dump")
            else { continue }

            // Ports from probe 17, because it is the only one carrying
            // ConnectionActive, with the controller UUID joined in from probe
            // 35 on the port key both publish. Building them from probe 35
            // alone leaves connectionActive nil, closes the in-use gate on
            // every machine, and reports a confident zero.
            let records = CorpusPowerProbes.probe35Records(probe35)
            let uuidsByKey = CorpusPowerProbes.controllerUUIDsByPortKey(records)
            let ports = CorpusPowerProbes.probe17HPMPorts(probe17, controllerUUIDs: uuidsByKey)
            guard !ports.isEmpty else {
                // Counted, not silently dropped. This skip is where the whole
                // limitation lives, and a `continue` on its own hid it.
                skippedNoPorts += 1
                let chip = folder.split(separator: "_").first.map(String.init) ?? "?"
                skippedChips[chip, default: 0] += 1
                continue
            }
            machines += 1

            let contractChannels = Self.contracts(in: probe34)
            if !contractChannels.isEmpty { withContractKeys += 1 }

            let realSources = CorpusPowerProbes.powerSources(from: probe17)

            // Per-gate accounting. A sweep that reports "0 synthesized" without
            // saying WHY is indistinguishable from a broken parser, and the
            // first version of this file reported exactly that because its
            // ports came from a probe with no connection state. These counters
            // are what turned that from a mystery into a one-line fix.
            let map = HPMPortUUIDMap.from(ports: ports)
            if !contractChannels.isEmpty {
                if map.isEmpty { noUUIDMap += 1 }
                else if realSources.contains(where: { ($0.winning?.maxPowerMW ?? 0) > 0 }) { realContractWins += 1 }
                else if !contractChannels.contains(where: { map[$0.uuid] != nil }) { noChannelResolved += 1 }
                else if !contractChannels.contains(where: {
                    guard let key = map[$0.uuid] else { return false }
                    return ports.contains { $0.portKey == key && $0.connectionActive == true }
                }) { portNotConnected += 1 }
            }

            let source = SMCContractSynthesis.synthesizedSource(
                contracts: contractChannels,
                uuidMap: HPMPortUUIDMap.from(ports: ports),
                // ^ the production map, built from the ports above, so the
                //   join under test is the real one.
                ports: ports,
                realSources: realSources,
                externalConnected: true,
                enabled: true
            )

            guard let source else { continue }
            synthesized += 1
            let chip = folder.split(separator: "_").first.map(String.init) ?? "?"
            synthesizedChips[chip, default: 0] += 1

            // THE FAIL-OPEN CHECK. If macOS published a winning contract
            // anywhere on this machine, this must have stayed quiet.
            if realSources.contains(where: { ($0.winning?.maxPowerMW ?? 0) > 0 }) {
                firedDespiteRealContract += 1
                Issue.record("\(folder): synthesized a contract while a real winning source exists")
            }
            // And it must never claim MagSafe.
            if source.parentPortType == PortIdentity.magSafeTypeCode {
                firedOnMagSafe += 1
                Issue.record("\(folder): synthesized a MagSafe contract, which the SMC never reports")
            }
        }

        let chipSummary = synthesizedChips.sorted { $0.value > $1.value }
            .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print("[SMCContractSweep] \(machines) machines, \(withContractKeys) with contract keys, "
            + "\(synthesized) synthesized [\(chipSummary)]")
        print("[SMCContractSweep] not synthesized because: no UUID map \(noUUIDMap), "
            + "macOS already answered \(realContractWins), no channel resolved to a port \(noChannelResolved), "
            + "resolved port not connected \(portNotConnected)")

        let skippedSummary = skippedChips.sorted { $0.value > $1.value }
            .prefix(6).map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print("[SMCContractSweep] \(skippedNoPorts) machines skipped for having no replayable ports [\(skippedSummary)]")

        guard machines >= Self.presenceThreshold else {
            print("[SMCContractSweep] raw corpus not on disk, skipping the floors")
            return
        }

        // Non-negotiable: these are the fail-open modes.
        #expect(firedDespiteRealContract == 0)
        #expect(firedOnMagSafe == 0)

        // And non-negotiable the other way: if this fires nowhere, the fix is
        // an elaborate no-op and the reporter is still looking at a spinner.
        #expect(synthesized > 0,
            "the SMC contract fired on no machine at all; either the gates are wrong or the parse is")
    }
}
