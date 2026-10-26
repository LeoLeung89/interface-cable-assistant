import Foundation

/// Which reader produced the per-port figure the Power Monitor ends up showing.
///
/// Before this existed, "where did this number come from" was carried as two
/// booleans on `PortPowerSample` (`isSMCMeasured`, `isContractedFallback`) plus
/// an implicit third state: neither flag set meant `PowerOutDetails`. That is
/// only readable if you already know the merge order, which is exactly the kind
/// of knowledge that was spread across three files. Naming the source directly
/// makes the merge assertable in tests rather than inferable.
///
/// The two booleans are still emitted on the samples themselves, unchanged, so
/// nothing downstream had to move for this to land.
public enum PortPowerProvenance: String, Sendable, Codable, CaseIterable {
    /// A live SMC channel (`DxJV` / `DxJI`), tied to the port by controller
    /// UUID. The only genuinely live per-port source.
    case smc
    /// `AppleSmartBattery`'s `PowerOutDetails` array. Correct, but frozen under
    /// load on Apple Silicon, so it only fills ports the SMC did not resolve.
    case powerOutDetails
    /// The negotiated contract, from the `IOPortFeaturePowerSource` tree
    /// enriched by `PortControllerInfo`. Not a measurement.
    case contracted
}

/// The result of merging every per-port power reader for one tick.
public struct PortPowerMergeResult: Sendable, Equatable {
    /// What the Power Monitor shows, one sample per covered port, SMC first.
    public let displaySamples: [PortPowerSample]

    /// True when at least one SMC channel resolved to a known port through the
    /// controller-UUID map. False means M1/M2, a Mac Pro, or a machine whose
    /// UUID map and SMC channel set do not overlap: the UI must then not wait
    /// for per-port metering that will never arrive.
    ///
    /// Note this counts *resolvable* channels, not channels carrying power: an
    /// idle port still proves the machine can meter per-port.
    public let perPortMeteringSupported: Bool

    /// Which reader won each port, keyed the same way as the samples. Purely
    /// descriptive: nothing in the app branches on it yet, and the
    /// characterisation harness asserts on it so a later phase cannot silently
    /// change which source wins while keeping the same watts.
    public let provenance: [String: PortPowerProvenance]

    public init(
        displaySamples: [PortPowerSample],
        perPortMeteringSupported: Bool,
        provenance: [String: PortPowerProvenance]
    ) {
        self.displaySamples = displaySamples
        self.perPortMeteringSupported = perPortMeteringSupported
        self.provenance = provenance
    }
}

/// The pure per-port power merge: given every reader's output for one tick,
/// decide what each port shows.
///
/// This is the seam the Power slice refactor is built on. It used to be inline
/// in `PowerService.refresh()`, interleaved with the IOKit reads that
/// produce its inputs, so there was no way to feed it recorded data and no way
/// to assert on its decisions. Nothing about the ordering changed when it moved
/// here, and that is pinned two ways because neither alone is enough:
/// `PortPowerMergeCharacterisationCorpusSweepTests` records what won on 328
/// real machines, and `PortPowerMergeTests` pins the precedence order itself.
/// The corpus cannot do the second job: an SMC reading is power flowing out of
/// a port and a contract is power flowing in, so on real hardware the two never
/// appear on the same port and reordering them changes nothing there.
public enum PortPowerMerge {

    /// Builds a per-port sample from one SMC power channel, already tied to its
    /// physical port key by controller UUID.
    ///
    /// Marked `isSMCMeasured` so the UI trusts it as proof the port is live:
    /// desktops have no power-source tree to corroborate it with, and a dead
    /// port reads 0 V / 0 A rather than being emitted at all.
    ///
    /// `adapterVoltage` is 0 because the SMC has no equivalent field. That is
    /// load-bearing, not an omission: it is what keeps SMC samples out of the
    /// cable-resistance regression (see `PortPowerMergeResult.meteredSamples`).
    public static func smcSample(channel: SMCPortPowerChannel, portKey: String) -> PortPowerSample {
        let portNumber = Int(portKey.split(separator: "/").last.map(String.init) ?? "") ?? 0
        let voltageMV = Int((channel.volts * 1000).rounded())
        let currentMA = Int((channel.amps * 1000).rounded())
        let wattsMW = Int((channel.watts * 1000).rounded())
        return PortPowerSample(
            portIndex: portNumber,
            portKey: portKey,
            current: currentMA,
            watts: wattsMW,
            configuredVoltage: voltageMV,
            configuredCurrent: currentMA,
            adapterVoltage: 0,
            vconnCurrent: 0,
            vconnPower: 0,
            isSMCMeasured: true
        )
    }

    /// Builds the per-port sample that represents a negotiated contract.
    ///
    /// Written twice before this existed: once in `PowerMonitorWindow.resolve`
    /// from a winning `PowerSource`, and once in
    /// `portPowerSamplesFromControllerInfo` from the same source enriched by
    /// `PortControllerInfo`. Same six fields, same flag, two places to forget
    /// one of them.
    ///
    /// `adapterVoltage` is 0 and that is load-bearing, not laziness: a contract
    /// is a negotiated ceiling, not a measurement, so it carries no measured
    /// rail voltage and must never reach the cable-resistance regression, which
    /// needs the drop between configured and adapter voltage.
    ///
    /// - Parameter portKey: the port's canonical key, or nil for the caller
    ///   that deliberately leaves it empty. `resolve` returns its sample
    ///   straight to the view, which addresses ports by its own key, and
    ///   filling this in there would change the key a downstream consumer
    ///   derives for a MagSafe port from "2/N" to "17/N".
    public static func contractedSample(
        portNumber: Int,
        portKey: String? = nil,
        watts: Int,
        voltageMV: Int,
        currentMA: Int
    ) -> PortPowerSample {
        PortPowerSample(
            portIndex: portNumber,
            portKey: portKey ?? "",
            current: currentMA,
            watts: watts,
            configuredVoltage: voltageMV,
            configuredCurrent: currentMA,
            adapterVoltage: 0,
            vconnCurrent: 0,
            vconnPower: 0,
            isContractedFallback: true
        )
    }

    /// Merge one tick's readers into the per-port result.
    ///
    /// Order is live-first and has not changed: a resolved SMC channel beats
    /// `PowerOutDetails`, which beats the negotiated contract. `PowerOutDetails`
    /// is frozen under load on Apple Silicon (confirmed on an M5 Pro: an iPad
    /// charging on port 1 held it at 6098 mW across 16 samples at 1 Hz while the
    /// SMC channel tracked the real 6.6-7.5 W draw), so it must never outrank a
    /// live SMC reading. The contract is not a measurement at all and comes last.
    ///
    /// - Parameters:
    ///   - smcChannels: every SMC channel read this tick, resolved or not.
    ///   - uuidMap: controller UUID to port key. Empty on M1/M2 and Mac Pro,
    ///     which skips the SMC path entirely rather than guessing a positional
    ///     mapping.
    ///   - powerOutDetailSamples: parsed `PowerOutDetails`, already keyed to
    ///     real ports.
    ///   - contractedSamples: the contract per port, already attributed by the
    ///     self-keyed `IOPortFeaturePowerSource` tree.
    public static func merge(
        smcChannels: [SMCPortPowerChannel],
        uuidMap: [String: String],
        powerOutDetailSamples: [PortPowerSample],
        contractedSamples: [PortPowerSample]
    ) -> PortPowerMergeResult {
        var displaySamples: [PortPowerSample] = []
        var provenance: [String: PortPowerProvenance] = [:]
        var coveredKeys = Set<String>()

        // An empty UUID map means no channel can be tied to a port, so nothing
        // here can resolve. Checked explicitly rather than relying on the
        // lookup below failing, because the caller uses the same condition to
        // skip the SMC read altogether and the two must not drift apart.
        let channels = uuidMap.isEmpty ? [] : smcChannels
        var matchedChannels = 0
        for channel in channels {
            guard let key = uuidMap[channel.uuid] else { continue }
            // Counted before the power test: a channel that resolves to a port
            // proves the machine CAN meter per-port even while that port is
            // idle. Counting only powered channels would make an idle Mac look
            // like an M1, and the UI would show "no per-port metering" on a
            // machine that has it.
            matchedChannels += 1
            guard (channel.present || channel.watts > 0.001), !coveredKeys.contains(key) else { continue }
            displaySamples.append(smcSample(channel: channel, portKey: key))
            provenance[key] = .smc
            coveredKeys.insert(key)
        }
        let perPortMeteringSupported = matchedChannels > 0

        for sample in powerOutDetailSamples where !coveredKeys.contains(sample.portKey) {
            displaySamples.append(sample)
            provenance[sample.portKey] = .powerOutDetails
            coveredKeys.insert(sample.portKey)
        }
        for sample in contractedSamples where !coveredKeys.contains(sample.portKey) {
            displaySamples.append(sample)
            provenance[sample.portKey] = .contracted
            coveredKeys.insert(sample.portKey)
        }

        // The old `meteredSamples` resistance feed lived here. It was removed
        // in the 2026-08 charging-path rework: the corpus proved zero of its samples were ever accepted
        // by the regression (`PowerOutDetails` is 5 V power-out only, frozen,
        // and every active entry failed the old voltage-drop gate). The
        // regression now reads the live SMC DC-in pair in `PowerService`.
        return PortPowerMergeResult(
            displaySamples: displaySamples,
            perPortMeteringSupported: perPortMeteringSupported,
            provenance: provenance
        )
    }
}
