import Foundation

/// Which source, if any, gets to speak for a port this tick, and why not when
/// nothing does.
///
/// This is the "reason code" half of the split: the precedence decision is data
/// and lives here where it can be tested; turning a reason into words stays in
/// the view, where the localised strings already are and where the l10n gate
/// already covers them.
public enum PortPowerOutcome: Equatable, Sendable {
    /// Nothing is plugged in. No source may speak for this port, including a
    /// cached contract that outlived the unplug.
    case notInUse
    /// A live per-port reading: an SMC channel, or `PowerOutDetails`
    /// throughput. The most trustworthy thing available.
    case live(PortPowerSample)
    /// The negotiated contract from the `IOPortFeaturePowerSource` tree. Not a
    /// measurement: what the charger and the Mac agreed to.
    case contracted(PortPowerSample)
    /// A contracted sample that arrived keyed by array offset rather than by
    /// the port tree, on machines that publish no `IOPortFeaturePowerSource`.
    /// Kept separate from `contracted` because its attribution is weaker and a
    /// future phase may want to treat it differently.
    case legacyContracted(PortPowerSample)
    /// Power is coming into this port and no contract was ever negotiated for
    /// it, so there is no per-port figure to wait for. Two real shapes land
    /// here: a third-party brick on MagSafe, whose port publishes only a
    /// contract-less "Brick ID" identity node, and a dumb 5V source on USB-C
    /// (a PC's port), which on M1 Pro/Max/Ultra publishes no source node at
    /// all. Separate from `awaitingData` because the answer is permanent, not
    /// late, and the card should say so rather than spin (#592).
    case noContract
    /// The port is in use but nothing has reported a figure for it. The view
    /// decides what to say, which is where the "a charger on another port won"
    /// and "this port is driving a display" explanations get added.
    case awaitingData

    /// The sample to show, or nil when there is nothing to show.
    public var sample: PortPowerSample? {
        switch self {
        case .live(let s), .contracted(let s), .legacyContracted(let s): return s
        case .notInUse, .noContract, .awaitingData: return nil
        }
    }

    /// Whether the port has something plugged into it, regardless of whether
    /// any figure arrived.
    public var portInUse: Bool {
        if case .notInUse = self { return false }
        return true
    }
}

/// The per-port precedence ladder, lifted out of the Power Monitor's view layer.
///
/// It lived inside `PortPowerDisplay.resolve` in a SwiftUI file, which is why
/// the app and the CLI could only share it by both calling into the Pro plugin,
/// and why nothing could unit-test the ordering directly. The ordering itself
/// is unchanged; see `PortPowerResolveCharacterisationTests`, which recorded
/// every port's decision across 396 real machines before this moved and
/// compares against that recording after.
public enum PortPowerPrecedence {

    /// One port's decision, with the port kept alongside so the view can reach
    /// its native labels without a second lookup.
    /// Not Sendable: it holds an `AppleHPMInterface`, which is not. Marking it
    /// so would be a promise the compiler cannot keep, and nothing here crosses
    /// an isolation boundary: the resolve call and its result both stay on the
    /// main actor with the view that asked for them.
    public struct Resolution: Equatable {
        public let identity: PortIdentity
        public let port: AppleHPMInterface
        public let outcome: PortPowerOutcome

        public init(identity: PortIdentity, port: AppleHPMInterface, outcome: PortPowerOutcome) {
            self.identity = identity
            self.port = port
            self.outcome = outcome
        }
    }

    /// Resolve every real physical port.
    ///
    /// - Parameters:
    ///   - ports: the HPM port enumeration. Ports with no number are dropped:
    ///     nothing can be keyed to them.
    ///   - samples: this tick's per-port samples, not yet stale-filtered.
    ///   - powerSources: the whole `IOPortFeaturePowerSource` set, filtered per
    ///     port here by canonical identity.
    ///   - chargerAttached: the live system adapter. See
    ///     `PowerMonitorSnapshot.chargerAttached`, and note it reads false on
    ///     every desktop.
    ///   - onBattery: a battery is installed and no external power is connected.
    ///   - batteryInstalled: whether this Mac has a battery at all. Without it
    ///     the stale-contract gate is permanently true on a desktop.
    public static func resolve(
        ports: [AppleHPMInterface],
        samples: [PortPowerSample],
        powerSources: [PowerSource],
        chargerAttached: Bool,
        onBattery: Bool,
        batteryInstalled: Bool
    ) -> [Resolution] {
        // One gate, matching `PowerMonitorSnapshot.externalPowerAbsent`. Drop
        // lingering incoming-contract samples up front so every branch below is
        // gated from one place rather than each remembering to check.
        let externalPowerAbsent = PowerMonitorSnapshot.externalPowerAbsent(
            onBattery: onBattery, chargerAttached: chargerAttached, batteryInstalled: batteryInstalled
        )
        let samples = samples.droppingStaleContracted(externalPowerAbsent: externalPowerAbsent)

        // Liveness first, for every port, because one branch below asks whether
        // this is the machine's ONLY live port and that cannot be answered from
        // inside a single port's pass.
        typealias Candidate = (
            port: AppleHPMInterface, number: Int, identity: PortIdentity,
            sources: [PowerSource], live: Bool
        )
        let candidates: [Candidate] = ports.compactMap { port -> Candidate? in
            guard let number = port.portNumber else { return nil }
            // Built from the description alone, with no reported type code,
            // because that is what this path has always done. `port.identity`
            // consults `PortType` as well and can differ on a connector neither
            // has seen; keeping them apart preserves the sample lookup below,
            // which matches on exactly this key.
            let identity = PortIdentity.from(
                typeDescription: port.portTypeDescription ?? "USB-C",
                reportedTypeCode: nil,
                number: number
            )
            let portSources = powerSources.filter { $0.canonicallyMatches(port: port) }

            // A live SMC reading is itself proof the port is in use: a dead
            // port reads 0 V / 0 A and is never emitted, and a desktop has no
            // power-source tree for `isPortLive` to corroborate with.
            let smcLive = samples.contains {
                $0.portKey == identity.key && $0.isSMCMeasured && ($0.watts > 0 || $0.current > 0)
            }
            let live = smcLive || isPortLive(
                port: port, powerSources: portSources,
                identities: [], matchingDevices: [], chargerAttached: chargerAttached
            )
            return (port, number, identity, portSources, live)
        }
        let liveCount = candidates.filter(\.live).count

        // Two machine-wide facts branch 4 needs. Both are about what ELSE on
        // this Mac could account for the incoming power, which is not a question
        // a single port's own data can answer.
        //
        // A winning contract anywhere names where the power actually went, so
        // no port may claim it by elimination. Deliberately machine-wide and
        // deliberately not gated on liveness: the contract can sit on a port
        // that has already gone dark, which is the just-unplugged shape
        // (charger out of port X, its source still cached and
        // `connectionActive` already false, something goes into port Y, the
        // system adapter has not cleared yet). `activeChargingPort` cannot see
        // that one, because it requires the winning port to be live.
        let winningContractSomewhere = powerSources.contains { ($0.winning?.maxPowerMW ?? 0) > 0 }

        // Live ports publishing a source node that carries no contract. A node
        // proves something is attached to that port, never that this port is
        // the input the Mac selected, so when two ports have one (two non-PD
        // chargers, or a MagSafe brick alongside a contract-less USB-C charger)
        // neither may speak for the incoming power.
        let contractLessSourcePorts = candidates.filter { candidate in
            candidate.live && candidate.sources.holdsNoContract
        }.count

        return candidates.map { candidate -> Resolution in
            let (port, number, identity, portSources, _) = candidate
            let key = identity.key

            guard candidate.live else {
                return Resolution(identity: identity, port: port, outcome: .notInUse)
            }

            // 1. A live per-port reading wins outright.
            if let liveSample = samples.first(where: { $0.portKey == key && !$0.isContractedFallback }) {
                return Resolution(identity: identity, port: port, outcome: .live(liveSample))
            }

            // 2. The negotiated contract, attributed by the port tree's own
            //    identity rather than by array position. Only the agreed
            //    (winning) option, never the advertised menu: showing what the
            //    charger offered as though it were struck describes a deal that
            //    never happened.
            if !externalPowerAbsent,
               let source = PowerSource.preferredChargingSource(in: portSources) ?? portSources.first,
               let contract = source.winning,
               contract.maxPowerMW > 0 {
                let sample = PortPowerMerge.contractedSample(
                    portNumber: number,
                    watts: contract.maxPowerMW,
                    voltageMV: contract.voltageMV,
                    currentMA: contract.maxCurrentMA
                )
                return Resolution(identity: identity, port: port, outcome: .contracted(sample))
            }

            // 3. An offset-keyed contracted sample, for machines with no port
            //    tree. No gate needed: the filter above already removed every
            //    contracted sample when external power is absent.
            if let legacy = samples.first(where: { $0.portKey == key && $0.isContractedFallback && $0.watts > 0 }) {
                return Resolution(identity: identity, port: port, outcome: .legacyContracted(legacy))
            }

            // 4. Power is coming in through THIS port, it negotiated nothing,
            //    and nothing ever will: the answer is permanent rather than
            //    late, so the card can say so instead of spinning (#592).
            //
            //    Two real shapes reach here, and each arm below is what makes
            //    its shape attributable to this port rather than merely
            //    consistent with it:
            //      - a source node exists on this port and holds no contract (a
            //        third-party brick on MagSafe publishes only a
            //        contract-less "Brick ID"), and it is the only such port,
            //      - or no node exists here at all and this is the machine's
            //        only live port, so the power has nowhere else it could have
            //        come from. Same reasoning as the #141 sole-active-port
            //        attribution, and it collapses the moment anything else
            //        could account for the power: a second live port, or a
            //        winning contract anywhere on the machine.
            //
            //    `batteryInstalled` is the first term because only a laptop
            //    takes power IN through a port. A desktop sources power OUT of
            //    one, and `externalPowerAbsent` is false on every desktop for
            //    the unrelated reason that a machine with no battery is by
            //    definition running off the mains. Without this term the card
            //    would tell a Mac mini that its peripheral port is a charge
            //    path, which is not a thing that happens.
            //
            //    Neither arm can be reached by a port whose own sources hold a
            //    contract, and that is worth keeping deliberate rather than
            //    leaning on branch 2 to have caught it: branch 2 falls back to
            //    `?? portSources.first` when no source carries a priority name,
            //    and `.first` can be the contract-less one while a sibling holds
            //    the contract.
            //
            //    A genuine PD charger mid-negotiation briefly looks exactly like
            //    the first arm. That is accepted here; the view holds the
            //    explanation back for a few seconds so it never flashes.
            let soleContractLessSource = portSources.holdsNoContract && contractLessSourcePorts == 1
            let soleLivePortWithNothingElseClaiming =
                portSources.isEmpty && liveCount == 1 && !winningContractSomewhere
            if batteryInstalled, !externalPowerAbsent,
               soleContractLessSource || soleLivePortWithNothingElseClaiming {
                return Resolution(identity: identity, port: port, outcome: .noContract)
            }

            return Resolution(identity: identity, port: port, outcome: .awaitingData)
        }
    }

    /// The one port the Mac is actually drawing through, or nil when that
    /// cannot be said without guessing.
    ///
    /// Requires EXACTLY ONE live port holding a positive winning contract. A
    /// charger handover can leave a second cached contract briefly present, and
    /// IOKit enumeration order is undefined, so a bare "first" could name the
    /// wrong port. With zero or several the answer is ambiguous and silence
    /// beats pointing somewhere wrong.
    ///
    /// Liveness here is deliberately `isPortLive` and not the SMC measured
    /// signal: a winning charge contract is a connection-negotiated fact, and
    /// gating on the connection also drops a stale cached contract on a port
    /// that was just unplugged.
    public static func activeChargingPort(
        ports: [AppleHPMInterface],
        powerSources: [PowerSource],
        chargerAttached: Bool
    ) -> AppleHPMInterface? {
        let winning = ports.filter { port in
            let portSources = powerSources.filter { $0.canonicallyMatches(port: port) }
            return portSources.contains { ($0.winning?.maxPowerMW ?? 0) > 0 }
                && isPortLive(port: port, powerSources: portSources,
                              identities: [], matchingDevices: [], chargerAttached: chargerAttached)
        }
        return winning.count == 1 ? winning.first : nil
    }
}

private extension Array where Element == PowerSource {
    /// True when a port publishes at least one source node and none of them
    /// carries a negotiated contract: the "a charger is attached here but it
    /// never negotiated" shape.
    ///
    /// Empty is deliberately false. No node at all is a different fact from a
    /// node that never negotiated, and branch 4 above treats them differently:
    /// the first needs the port to be the machine's only live one before
    /// anything can be attributed to it, the second does not.
    var holdsNoContract: Bool {
        !isEmpty && !contains { ($0.winning?.maxPowerMW ?? 0) > 0 }
    }
}
