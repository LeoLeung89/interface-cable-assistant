import Foundation

// The two SMC reading models below are plain values with no platform
// dependency, so they live here in Core rather than beside the reader that
// produces them (`SMCPowerReader`, in the Darwin backend). That split is what
// lets the pure per-port merge (`PortPowerMerge`) take an SMC channel as input
// without Core gaining an IOKit import.

/// One USB-C / MagSafe power-OUT channel as the SMC reports it.
///
/// Desktops (Mac mini / Studio / Pro) have no battery controller, so the IOKit
/// per-port power paths the laptop pipeline uses are empty. The per-port
/// power-OUT figures still exist, they just live in the SMC (the System
/// Management Controller, a small always-on chip) on channels `D1..D4`.
///
/// `uuid` is the channel's `DxUI` key. It equals the port controller's
/// `AppleHPMDeviceHALType3.UUID`, which is how a channel is tied to a physical
/// port (see `HPMPortUUIDMap`). It is an internal join key only: never put it
/// in `--json` / `--raw` output or the UI.
public struct SMCPortPowerChannel: Sendable, Equatable {
    /// The SMC D-index (1..4). NOT the physical port number; map via ``uuid``.
    public let channel: Int
    /// The channel's `DxPR` flag: something is drawing on this channel.
    public let present: Bool
    /// Volts the Mac is putting out of the port (`DxJV`).
    public let volts: Double
    /// Amps the Mac is putting out of the port (`DxJI`).
    public let amps: Double
    /// Normalised 32-char lowercase hex of `DxUI`. Internal join key only.
    public let uuid: String

    public var watts: Double { volts * amps }

    public init(channel: Int, present: Bool, volts: Double, amps: Double, uuid: String) {
        self.channel = channel
        self.present = present
        self.volts = volts
        self.amps = amps
        self.uuid = uuid
    }
}

/// The Mac's overall power input, as the SMC reports it on the DC-in rail.
///
/// Desktops (Mac mini / Studio / Pro) have no battery controller, so the laptop
/// pipeline's `AppleSmartBattery.SystemPowerIn` is always 0 there. The figure
/// still exists: the internal PSU feeds the logic board on a DC rail the SMC
/// meters as `VD0R` / `ID0R` / `PDTR`. On a Mac mini M4 that reads ~12.5 V,
/// ~1.8 A, ~23 W.
///
/// This is the *total* the machine pulls from the wall, so it is larger than the
/// sum of the per-port power-OUT channels: the difference is the Mac itself.
public struct SMCSystemPowerInput: Sendable, Equatable {
    /// DC-in voltage (`VD0R`).
    public let volts: Double
    /// DC-in current (`ID0R`).
    public let amps: Double
    /// DC-in total power (`PDTR`), or `volts * amps` when `PDTR` is absent.
    public let watts: Double
    /// True when `watts` came from a real `PDTR` read; false when it is the
    /// computed fallback. The resistance regression's torn-read sanity gate
    /// (`PDTR ~= volts * amps`) is only meaningful against an independently
    /// read `PDTR`; against the fallback it compares a product with itself.
    /// Defaults true so existing constructions keep their behaviour.
    public let pdtrIsMeasured: Bool

    public init(volts: Double, amps: Double, watts: Double, pdtrIsMeasured: Bool = true) {
        self.volts = volts
        self.amps = amps
        self.watts = watts
        self.pdtrIsMeasured = pdtrIsMeasured
    }
}

/// The negotiated charging contract as the SMC reports it, per channel.
///
/// Distinct from ``SMCPortPowerChannel``, which is power the Mac is sourcing
/// OUT of a port. This is the contract for power coming IN, and it is the only
/// place that contract exists on M1 Pro / Max / Ultra: those machines never
/// publish a USB-C `IOPortFeaturePowerSource` node, so nothing else in the
/// system can say what the charger agreed to (public issue 491).
///
/// **The integer keys are big-endian.** The float keys next door (`DxJV`,
/// `DxJI`) are native little-endian, so the two cannot share a decoder and
/// reusing the float one here produces garbage. That is not a subtle failure:
/// 20000 mV read the wrong way round is 553,648,128.
public struct SMCPortContract: Sendable, Equatable {
    /// The SMC D-index (1..4). NOT the physical port number; map via ``uuid``.
    public let channel: Int
    /// Normalised 32-char lowercase hex of `DxUI`, the join key to a port.
    public let uuid: String
    /// `DxMP`, contract power in milliwatts.
    public let powerMW: Int
    /// `DxMV`, contract voltage in millivolts.
    public let voltageMV: Int
    /// `DxMI`, contract current in milliamps.
    public let currentMA: Int
    /// `DxDE`, the channel label. Often empty even on a genuine 20 V charger
    /// (153 channels in the corpus), so absence proves nothing. Useful only for
    /// spotting the outgoing `usb host` case.
    public let label: String

    public init(channel: Int, uuid: String, powerMW: Int, voltageMV: Int, currentMA: Int, label: String) {
        self.channel = channel
        self.uuid = uuid
        self.powerMW = powerMW
        self.voltageMV = voltageMV
        self.currentMA = currentMA
        self.label = label
    }
}
