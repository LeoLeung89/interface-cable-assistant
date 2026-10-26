import Foundation

public struct PowerSample: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let systemVoltageIn: Int
    public let systemCurrentIn: Int
    public let systemPowerIn: Int

    public init(timestamp: Date, systemVoltageIn: Int, systemCurrentIn: Int, systemPowerIn: Int) {
        self.timestamp = timestamp
        self.systemVoltageIn = systemVoltageIn
        self.systemCurrentIn = systemCurrentIn
        self.systemPowerIn = systemPowerIn
    }
}

public struct PortPowerSample: Codable, Sendable, Equatable {
    public let portIndex: Int
    public let portKey: String
    public let current: Int
    /// Measured power out of the port (mW). AppleSmartBattery's `Watts` is
    /// milliwatts, not centiwatts: swept over every PowerOutDetails entry in
    /// the customer-probe corpus (620 entries over 413 capture folders, 567 of
    /// them with a nonzero current, from 386 folders), it tracks
    /// AdapterVoltage (mV) x Current (mA) / 1000 with a median ratio of 1.001.
    /// The tail runs high on small draws, because the integer milliamp field
    /// truncates away part of the current (p95 1.064, max 1.160, all the worst
    /// rows at 5 mA), but no entry is anywhere near the 10x a centiwatt
    /// reading would give, on any chip or any macOS version.
    public let watts: Int
    public let configuredVoltage: Int
    public let configuredCurrent: Int
    public let adapterVoltage: Int
    public let vconnCurrent: Int
    /// Cable-electronics power draw (mW).
    public let vconnPower: Int
    /// Smoothed power reading (mW).
    public let filteredPower: Int
    /// PD contract negotiated power (mW).
    public let pdPowerMW: Int
    /// Maximum VConn current the cable claimed (mA).
    public let vconnMaxCurrent: Int
    /// Lifetime accumulated energy through this port.
    public let accumulatedPower: Int
    /// Number of energy measurement samples taken.
    public let accumulatorCount: Int
    /// Number of energy measurement errors.
    public let accumulatorErrorCount: Int
    /// Lifetime VConn energy accumulated.
    public let vconnAccumulatedPower: Int
    /// VConn energy sample count.
    public let vconnAccumulatorCount: Int
    /// VConn energy measurement errors.
    public let vconnAccumulatorErrorCount: Int
    /// Number of liquid detection collision events on this port.
    public let numLDCMCollisions: Int
    /// Reserved sleep power for USB devices (mW).
    public let usbSleepPoolPowerMW: Int
    /// Reserved wake power for USB devices (mW).
    public let usbWakePoolPowerMW: Int
    /// Power delivery state.
    public let powerState: Int
    /// Port type identifier.
    public let portType: Int
    // True when the sample came from PortControllerInfo (contracted/port-max
    // only, no live per-port metering). Voltage is unrecoverable in this
    // path, so configuredVoltage stays 0 and the UI shows the honest
    // contracted-max card instead of a synthesized live reading.
    public let isContractedFallback: Bool
    // True when the sample came from the SMC per-port channels (desktop Macs,
    // which have no battery controller and so no PortControllerInfo /
    // PowerOutDetails). This is a live measured reading tied to the port by
    // controller UUID, so it is trusted as proof the port is live.
    public let isSMCMeasured: Bool

    public init(
        portIndex: Int,
        portKey: String = "",
        current: Int,
        watts: Int,
        configuredVoltage: Int,
        configuredCurrent: Int,
        adapterVoltage: Int,
        vconnCurrent: Int,
        vconnPower: Int,
        filteredPower: Int = 0,
        pdPowerMW: Int = 0,
        vconnMaxCurrent: Int = 0,
        accumulatedPower: Int = 0,
        accumulatorCount: Int = 0,
        accumulatorErrorCount: Int = 0,
        vconnAccumulatedPower: Int = 0,
        vconnAccumulatorCount: Int = 0,
        vconnAccumulatorErrorCount: Int = 0,
        numLDCMCollisions: Int = 0,
        usbSleepPoolPowerMW: Int = 0,
        usbWakePoolPowerMW: Int = 0,
        powerState: Int = 0,
        portType: Int = 0,
        isContractedFallback: Bool = false,
        isSMCMeasured: Bool = false
    ) {
        self.portIndex = portIndex
        self.portKey = portKey
        self.current = current
        self.watts = watts
        self.configuredVoltage = configuredVoltage
        self.configuredCurrent = configuredCurrent
        self.adapterVoltage = adapterVoltage
        self.vconnCurrent = vconnCurrent
        self.vconnPower = vconnPower
        self.filteredPower = filteredPower
        self.pdPowerMW = pdPowerMW
        self.vconnMaxCurrent = vconnMaxCurrent
        self.accumulatedPower = accumulatedPower
        self.accumulatorCount = accumulatorCount
        self.accumulatorErrorCount = accumulatorErrorCount
        self.vconnAccumulatedPower = vconnAccumulatedPower
        self.vconnAccumulatorCount = vconnAccumulatorCount
        self.vconnAccumulatorErrorCount = vconnAccumulatorErrorCount
        self.numLDCMCollisions = numLDCMCollisions
        self.usbSleepPoolPowerMW = usbSleepPoolPowerMW
        self.usbWakePoolPowerMW = usbWakePoolPowerMW
        self.powerState = powerState
        self.portType = portType
        self.isContractedFallback = isContractedFallback
        self.isSMCMeasured = isSMCMeasured
    }

    private enum CodingKeys: String, CodingKey {
        case portIndex, portKey, current, watts, configuredVoltage
        case configuredCurrent, adapterVoltage, vconnCurrent, vconnPower
        case filteredPower, pdPowerMW, vconnMaxCurrent
        case accumulatedPower, accumulatorCount, accumulatorErrorCount
        case vconnAccumulatedPower, vconnAccumulatorCount, vconnAccumulatorErrorCount
        case numLDCMCollisions, usbSleepPoolPowerMW, usbWakePoolPowerMW
        case powerState, portType
        case isContractedFallback
        case isSMCMeasured
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        portIndex = try c.decode(Int.self, forKey: .portIndex)
        portKey = try c.decode(String.self, forKey: .portKey)
        current = try c.decode(Int.self, forKey: .current)
        watts = try c.decode(Int.self, forKey: .watts)
        configuredVoltage = try c.decode(Int.self, forKey: .configuredVoltage)
        configuredCurrent = try c.decode(Int.self, forKey: .configuredCurrent)
        adapterVoltage = try c.decode(Int.self, forKey: .adapterVoltage)
        vconnCurrent = try c.decode(Int.self, forKey: .vconnCurrent)
        vconnPower = try c.decode(Int.self, forKey: .vconnPower)
        filteredPower = try c.decodeIfPresent(Int.self, forKey: .filteredPower) ?? 0
        pdPowerMW = try c.decodeIfPresent(Int.self, forKey: .pdPowerMW) ?? 0
        vconnMaxCurrent = try c.decodeIfPresent(Int.self, forKey: .vconnMaxCurrent) ?? 0
        accumulatedPower = try c.decodeIfPresent(Int.self, forKey: .accumulatedPower) ?? 0
        accumulatorCount = try c.decodeIfPresent(Int.self, forKey: .accumulatorCount) ?? 0
        accumulatorErrorCount = try c.decodeIfPresent(Int.self, forKey: .accumulatorErrorCount) ?? 0
        vconnAccumulatedPower = try c.decodeIfPresent(Int.self, forKey: .vconnAccumulatedPower) ?? 0
        vconnAccumulatorCount = try c.decodeIfPresent(Int.self, forKey: .vconnAccumulatorCount) ?? 0
        vconnAccumulatorErrorCount = try c.decodeIfPresent(Int.self, forKey: .vconnAccumulatorErrorCount) ?? 0
        numLDCMCollisions = try c.decodeIfPresent(Int.self, forKey: .numLDCMCollisions) ?? 0
        usbSleepPoolPowerMW = try c.decodeIfPresent(Int.self, forKey: .usbSleepPoolPowerMW) ?? 0
        usbWakePoolPowerMW = try c.decodeIfPresent(Int.self, forKey: .usbWakePoolPowerMW) ?? 0
        powerState = try c.decodeIfPresent(Int.self, forKey: .powerState) ?? 0
        portType = try c.decodeIfPresent(Int.self, forKey: .portType) ?? 0
        isContractedFallback = try c.decodeIfPresent(Bool.self, forKey: .isContractedFallback) ?? false
        isSMCMeasured = try c.decodeIfPresent(Bool.self, forKey: .isSMCMeasured) ?? false
    }
}

public extension Array where Element == PortPowerSample {
    /// When no external power is coming in, drop samples derived from a
    /// (possibly stale) incoming charging contract. A USB-C controller can keep
    /// a winning PDO around after macOS stops drawing external power, so a
    /// contract-derived per-port wattage is then a lingering value, not a live
    /// draw (darrylmorley/whatcable#466).
    ///
    /// `externalPowerAbsent` is the caller's decision. The Power Monitor passes
    /// `onBattery || !chargerAttached`: either signal is enough, and
    /// `chargerAttached` (the live system adapter) clears immediately on unplug
    /// while `onBattery` (via ExternalConnected) can lag, so together they close
    /// the post-unplug race.
    ///
    /// Only `isContractedFallback` samples are dropped. SMC-measured readings
    /// and `PowerOutDetails` throughput both carry `isContractedFallback ==
    /// false` (the watcher builds them in separate paths and never tags them),
    /// so genuine power flowing OUT of a port, and any live SMC per-port
    /// reading, are always kept. When external power is present, nothing is
    /// dropped.
    func droppingStaleContracted(externalPowerAbsent: Bool) -> [PortPowerSample] {
        guard externalPowerAbsent else { return self }
        return filter { !$0.isContractedFallback }
    }
}

public struct CableResistanceEstimate: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case insufficient
        case converging
        case stable
        case unreliable
    }

    public let milliohms: Double
    public let sampleCount: Int
    public let rSquared: Double
    public let status: Status
    /// Spread between the smallest and largest charging current seen by the
    /// regression, in mA. Surfaced so the UI (and `--monitor-json` consumers)
    /// can tell "not converged because the load never varied" apart from "not
    /// converged because the data is noisy". 0 on estimates decoded from
    /// older builds.
    public let currentSpanMilliamps: Int

    public init(
        milliohms: Double,
        sampleCount: Int,
        rSquared: Double,
        status: Status,
        currentSpanMilliamps: Int = 0
    ) {
        self.milliohms = milliohms
        self.sampleCount = sampleCount
        self.rSquared = rSquared
        self.status = status
        self.currentSpanMilliamps = currentSpanMilliamps
    }

    private enum CodingKeys: String, CodingKey {
        case milliohms, sampleCount, rSquared, status, currentSpanMilliamps
    }

    // Custom decode (encode stays synthesised) so an estimate encoded by an
    // older build, missing the span key, decodes instead of throwing. Same
    // pattern as `PowerMonitorSnapshot`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        milliohms = try c.decode(Double.self, forKey: .milliohms)
        sampleCount = try c.decode(Int.self, forKey: .sampleCount)
        rSquared = try c.decode(Double.self, forKey: .rSquared)
        status = try c.decode(Status.self, forKey: .status)
        currentSpanMilliamps = try c.decodeIfPresent(Int.self, forKey: .currentSpanMilliamps) ?? 0
    }

    /// How a stable resistance reading rates against the USB-C spec budget.
    ///
    /// **Not surfaced anywhere as of the 2026-08 charging-path rework.** The estimate is a whole
    /// charging-path slope (cable loop + connectors + charger output
    /// impedance + Mac board path), so applying cable-only spec budgets to
    /// it mislabels healthy setups (a known-good dev-M5 setup measured
    /// 179.6 mOhm against the 150 mOhm 5 A cable budget). The tier stays
    /// compiled for the Cable History schema and for a future hardware
    /// calibration pass; nothing feeds it to the UI or the session monitor.
    public enum Tier: String, Sendable {
        /// Comfortably within the spec budget.
        case good
        /// Within the budget but approaching the ceiling.
        case marginal
        /// Over the spec budget: out of spec for this cable's rating.
        /// (A reading exactly at the budget is `.marginal`; only strictly
        /// over is `.high`.)
        case high
    }

    /// Classify the resistance against the USB Type-C IR-drop budget
    /// (spec §4.4.1), which the estimate measures as the VBUS+GND loop (the
    /// Mac can only sense VBUS relative to its own ground, so its reading
    /// includes the GND return drop). The budget is current-rated, so a 5 A
    /// cable's ceiling is tighter than a 3 A's:
    ///
    /// - 5 A loop budget ≈ 150 mΩ → Good < 100, Marginal 100–150, High > 150.
    /// - 3 A loop budget ≈ 250 mΩ → Good < 165, Marginal 165–250, High > 250.
    ///
    /// Full working: `research/cable-resistance-thresholds.md`.
    ///
    /// - Parameter ratedFiveA: whether the cable is a 5 A-class cable. Pass
    ///   `true` only when known (e.g. the negotiated contract exceeded 3 A,
    ///   which only a 5 A-rated cable allows). Default `false` applies the
    ///   looser 3 A budget so a lightly-loaded 5 A cable is never over-flagged.
    /// - Returns: the tier, or `nil` when the estimate isn't `stable` (no
    ///   trustworthy reading yet).
    public func tier(ratedFiveA: Bool) -> Tier? {
        guard status == .stable else { return nil }
        let goodBelow = ratedFiveA ? 100.0 : 165.0
        let budget = ratedFiveA ? 150.0 : 250.0
        if milliohms < goodBelow { return .good }
        if milliohms <= budget { return .marginal }
        return .high
    }
}

public struct PowerMonitorSnapshot: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let systemSample: PowerSample
    public let portSamples: [PortPowerSample]
    public let resistanceEstimate: CableResistanceEstimate?
    /// Display key ("type/number", e.g. "2/1") of the port whose charging
    /// cable the resistance estimate describes, or nil when no eligible
    /// charging input resolved this tick. Attribution happens where the
    /// estimate is built (the charging-input resolver), not guessed later
    /// from per-port draw, so every surface agrees on the port.
    public let resistancePortKey: String?
    /// True when an external power source (a charger) is connected. Drives the
    /// "Charger" vs "Battery" indicator and chart colour. Defaults to true so a
    /// desktop Mac (no battery) reads as plugged in.
    public let externalConnected: Bool
    /// True when a battery is present (a laptop). Desktops report false, so they
    /// never show "on battery".
    public let batteryInstalled: Bool

    /// Battery discharge, used when on battery so the card keeps tracking
    /// voltage/current/power instead of going blank (there is no power *in*
    /// from a charger then). All magnitudes (mV / mA / mW), already abs'd.
    public let batteryVoltageMV: Int
    public let batteryCurrentMA: Int
    public let batteryPowerMW: Int

    /// True when at least one port has a struck power contract (a winning
    /// `IOPortFeaturePowerSource`). Carried in the snapshot so the System Power
    /// card decides "negotiating vs waiting for live data" from one atomic
    /// source, not a second watcher on a different clock.
    public let hasContract: Bool

    /// True when this Mac can read per-port power from the SMC (a desktop with
    /// the M3+ controller UUID key and a readable SMC). Distinguishes "this Mac
    /// can meter but nothing is drawing" (idle ports show a clean no-data state)
    /// from "this Mac cannot meter per-port at all" (M1/M2, Mac Pro, SMC open
    /// refused), which the UI states plainly instead. Always false on laptops,
    /// where per-port comes from the battery controller, not the SMC.
    public let perPortMeteringSupported: Bool

    /// True when the Mac reports an external power adapter attached right now.
    ///
    /// Carried in the snapshot so every surface reads it from the same tick as
    /// the samples it qualifies, rather than each asking the system separately
    /// on its own clock. `PowerMonitorWindow` used to call
    /// `SystemPower.currentAdapter()` itself at render time and
    /// `PowerTelemetryContributor` had no equivalent at all, which is how the
    /// two ended up applying different rules to the same data.
    ///
    /// **This is the raw reported value and it reads false on every desktop
    /// Mac**, which are mains powered and have no adapter to report. Never test
    /// it alone; use ``externalPowerAbsent``, which accounts for that.
    ///
    /// Defaults to true, including on decode of an older snapshot, so
    /// `externalPowerAbsent` reduces to plain `onBattery` when the field is
    /// unknown. That is the behaviour that shipped before it existed.
    ///
    /// The decode default is conservatism, not compatibility with a real
    /// cache. An earlier version of this comment justified it as "the widget
    /// reads a cache an older build may have written", which is not true of
    /// this type: the widget's cache is `WidgetSnapshot`, and the only
    /// production encode of a `PowerMonitorSnapshot` is one-way, for
    /// `whatcable --monitor-json`. Nothing in the app decodes one. Reviewer's
    /// finding, and the rule it broke is the house rule about not stating a
    /// premise you have not checked.
    public let chargerAttached: Bool

    /// On battery means a battery is installed and no charger is connected.
    public var onBattery: Bool { batteryInstalled && !externalConnected }

    /// No external power is coming in, by either of two independent signals.
    ///
    /// This is THE stale-contract gate, in one place. A negotiated contract can
    /// linger for a moment after unplug, and it only ever meant anything while
    /// a charger was actually attached, so any surface showing an incoming
    /// contract must suppress it here.
    ///
    /// Two signals because they clear at different speeds and either is
    /// sufficient: `onBattery` comes from `ExternalConnected`, which can lag a
    /// few seconds after the plug comes out, while `chargerAttached` reflects
    /// the live system adapter and clears at once. Whichever flips first closes
    /// the window.
    ///
    /// Only the incoming contract is affected. SMC-measured readings and
    /// `PowerOutDetails` throughput are never suppressed, so a Mac delivering
    /// power OUT of a port on battery still shows it.
    ///
    /// **A machine with no battery is never in this state.** A desktop is
    /// running, so it is powered, and `IOPSCopyExternalPowerAdapterDetails`
    /// returns nil there regardless: `probes/test-kit/39_system_power_adapter.c`
    /// says so outright, "desktop Macs on AC also report nil". Without the
    /// `batteryInstalled` term this property would be permanently true on every
    /// Mac mini, Studio and Pro, and the first version of this commit shipped
    /// exactly that, which would have blanked per-port contract data on all of
    /// them. Caught by reading the probe's own header rather than by reasoning
    /// about what the API "probably" does.
    public var externalPowerAbsent: Bool {
        Self.externalPowerAbsent(
            onBattery: onBattery, chargerAttached: chargerAttached, batteryInstalled: batteryInstalled
        )
    }

    /// The gate as a free function, for the two callers that have the three
    /// signals but not a snapshot to read them off.
    ///
    /// This exists because "one gate" was not true when it was first claimed.
    /// The RULE was unified but the EXPRESSION was still typed out in three
    /// places (here, `PortPowerPrecedence.resolve`, and the Power Monitor's
    /// no-HPM fallback), which is the same failure in miniature: three copies
    /// that happen to agree today and nothing making them agree tomorrow.
    /// Found by counting the copies rather than by trusting the claim.
    public static func externalPowerAbsent(
        onBattery: Bool,
        chargerAttached: Bool,
        batteryInstalled: Bool
    ) -> Bool {
        // A machine with no battery is running, therefore it is powered. See
        // the instance property's doc comment for why that term is not
        // optional.
        batteryInstalled && (onBattery || !chargerAttached)
    }

    /// What the System Power card displays: the charger input when plugged in,
    /// the battery discharge when on battery. One set of numbers tracks the
    /// active source.
    public var activeVoltageMV: Int { onBattery ? batteryVoltageMV : systemSample.systemVoltageIn }
    public var activeCurrentMA: Int { onBattery ? batteryCurrentMA : systemSample.systemCurrentIn }
    public var activePowerMW: Int { onBattery ? batteryPowerMW : systemSample.systemPowerIn }

    public init(
        timestamp: Date,
        systemSample: PowerSample,
        portSamples: [PortPowerSample],
        resistanceEstimate: CableResistanceEstimate?,
        resistancePortKey: String? = nil,
        externalConnected: Bool = true,
        batteryInstalled: Bool = false,
        batteryVoltageMV: Int = 0,
        batteryCurrentMA: Int = 0,
        batteryPowerMW: Int = 0,
        hasContract: Bool = false,
        perPortMeteringSupported: Bool = false,
        chargerAttached: Bool = true
    ) {
        self.timestamp = timestamp
        self.systemSample = systemSample
        self.portSamples = portSamples
        self.resistanceEstimate = resistanceEstimate
        self.resistancePortKey = resistancePortKey
        self.externalConnected = externalConnected
        self.batteryInstalled = batteryInstalled
        self.batteryVoltageMV = batteryVoltageMV
        self.batteryCurrentMA = batteryCurrentMA
        self.batteryPowerMW = batteryPowerMW
        self.hasContract = hasContract
        self.perPortMeteringSupported = perPortMeteringSupported
        self.chargerAttached = chargerAttached
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp, systemSample, portSamples, resistanceEstimate, resistancePortKey
        case externalConnected, batteryInstalled
        case batteryVoltageMV, batteryCurrentMA, batteryPowerMW
        case hasContract, perPortMeteringSupported
        case chargerAttached
    }

    // Custom decode (encode stays synthesised) so a snapshot encoded by an
    // older build, missing newer keys, decodes with sensible defaults instead
    // of throwing. Same defensive pattern as `PortPowerSample`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        systemSample = try c.decode(PowerSample.self, forKey: .systemSample)
        portSamples = try c.decode([PortPowerSample].self, forKey: .portSamples)
        resistanceEstimate = try c.decodeIfPresent(CableResistanceEstimate.self, forKey: .resistanceEstimate)
        resistancePortKey = try c.decodeIfPresent(String.self, forKey: .resistancePortKey)
        externalConnected = try c.decodeIfPresent(Bool.self, forKey: .externalConnected) ?? true
        batteryInstalled = try c.decodeIfPresent(Bool.self, forKey: .batteryInstalled) ?? false
        batteryVoltageMV = try c.decodeIfPresent(Int.self, forKey: .batteryVoltageMV) ?? 0
        batteryCurrentMA = try c.decodeIfPresent(Int.self, forKey: .batteryCurrentMA) ?? 0
        batteryPowerMW = try c.decodeIfPresent(Int.self, forKey: .batteryPowerMW) ?? 0
        hasContract = try c.decodeIfPresent(Bool.self, forKey: .hasContract) ?? false
        perPortMeteringSupported = try c.decodeIfPresent(Bool.self, forKey: .perPortMeteringSupported) ?? false
        // True, not false: an older snapshot has no opinion, and treating "no
        // opinion" as "no charger" would suppress every contract card on a
        // machine that is plugged in.
        chargerAttached = try c.decodeIfPresent(Bool.self, forKey: .chargerAttached) ?? true
    }
}
