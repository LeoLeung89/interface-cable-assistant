import Foundation

/// What the battery is doing right now, decided from live SMC keys. The
/// battery record (`AppleSmartBattery` IsCharging /
/// FullyCharged) lags a plug-in by up to about 60 s; these keys move within
/// about 3 s.
public enum BatteryChargeState: String, Sendable, Equatable, CaseIterable {
    case notPluggedIn
    case charging
    case full
    case onHold
    case chargeLimitReached
    case runningOnBattery
}

/// The SMC values the chain reads, already decoded. nil means the key was
/// absent or unreadable on this Mac.
public struct BatteryChargeInputs: Sendable, Equatable {
    /// `CH0R`: power-input inhibit flags.
    public var ch0r: UInt32?
    /// `CHCE`: a charger is present.
    public var chce: Bool?
    /// `CHCC`: the charger can charge.
    public var chcc: Bool?
    /// `AC-i`: input current limit. Absent on newer firmware.
    public var acInputLimit: UInt16?
    /// `BSFC`: battery full.
    public var bsfc: Bool?
    /// `CHLS`: charge limit on older firmware; the low byte is the end threshold.
    public var chls: UInt16?
    /// `CHWA`: the fixed 80% charge limit is on (newer firmware).
    public var chwa: Bool?
    /// `BUIC`: battery charge, percent.
    public var buic: UInt8?
    /// `CHNC`: the set of reasons the battery is not charging.
    public var chnc: UInt64?
    /// `CHSC`: system charging. Used only when `CHNC` can't be read.
    public var chsc: Bool?

    public init(
        ch0r: UInt32? = nil, chce: Bool? = nil, chcc: Bool? = nil,
        acInputLimit: UInt16? = nil, bsfc: Bool? = nil, chls: UInt16? = nil,
        chwa: Bool? = nil, buic: UInt8? = nil, chnc: UInt64? = nil, chsc: Bool? = nil
    ) {
        self.ch0r = ch0r; self.chce = chce; self.chcc = chcc
        self.acInputLimit = acInputLimit; self.bsfc = bsfc; self.chls = chls
        self.chwa = chwa; self.buic = buic; self.chnc = chnc; self.chsc = chsc
    }
}

extension BatteryChargeState {
    // CHNC reason bits.
    static let chncBatteryFull: UInt64 = 1 << 0
    static let chncBMSBusy: UInt64 = 1 << 23
    static let chncChargeLimit: UInt64 = 1 << 24
    /// CH0R's low 16 bits, without bit 8 (BMS busy).
    static let ch0rInhibitMask: UInt32 = 0xFEFF

    /// The chain. Returns nil when a key it needs (`CHCE`, `CHCC`, `BSFC`, or
    /// both `CHNC` and `CHSC`) is missing, so the caller keeps the battery
    /// record's answer.
    public static func decide(_ k: BatteryChargeInputs) -> BatteryChargeState? {
        // 1. Power input inhibited.
        // Both outcomes mean the Mac is on battery. We split them only so
        // an unplugged Mac is never shown as "plugged in, running on battery".
        if let ch0r = k.ch0r, ch0r & ch0rInhibitMask != 0 {
            return k.chce == false ? .notPluggedIn : .runningOnBattery
        }
        // 2. Charger present, and able to charge.
        guard let chce = k.chce else { return nil }
        if !chce { return .notPluggedIn }
        guard let chcc = k.chcc else { return nil }
        if !chcc { return .runningOnBattery }
        // 3. Input current limit too low (key gone on newer firmware).
        if let limit = k.acInputLimit, limit < 100 { return .runningOnBattery }
        // 4. Battery full.
        guard let bsfc = k.bsfc else { return nil }
        if bsfc { return .full }
        // 5. Charging inhibitors.
        if let chnc = k.chnc {
            if chnc & chncBatteryFull != 0 { return .full }
            if chnc == chncBMSBusy && !isAtChargeLimit(k) { return .charging }
            if chnc & chncChargeLimit != 0 { return .chargeLimitReached }
            return chnc != 0 ? .onHold : .charging
        }
        // 6. CHNC unreadable: the system charging flag decides.
        guard let chsc = k.chsc else { return nil }
        return chsc ? .charging : .onHold
    }

    /// The charge-limit check, per reading: `CHWA`
    /// when it reads (on: fixed 80 minus 5, off: no limit, `CHLS` never used),
    /// else `CHLS` (end threshold minus 5, only when the threshold is at least
    /// 10). Limited when `BUIC` is at or past the limit.
    static func isAtChargeLimit(_ k: BatteryChargeInputs) -> Bool {
        var limit = 0
        if let chwa = k.chwa {
            if chwa { limit = 80 - 5 }
        } else if let chls = k.chls {
            let end = Int(chls & 0xFF)
            if end >= 10 { limit = end - 5 }
        }
        guard limit > 0, let buic = k.buic else { return false }
        return Int(buic) >= limit
    }

    /// The battery-record flags with a decided state applied. nil returns
    /// the record unchanged, so a Mac without the keys takes exactly today's
    /// path. `.notPluggedIn` clears IsCharging (the live SMC says the charger
    /// is gone, so a stale record must not survive) and keeps FullyCharged. `.full` keeps the record's IsCharging so
    /// the on-battery gate (`SystemPowerState.onBattery`) is unchanged for a
    /// full battery.
    public static func resolvedFlags(
        state: BatteryChargeState?, isCharging: Bool?, fullyCharged: Bool?
    ) -> (isCharging: Bool?, fullyCharged: Bool?) {
        switch state {
        case nil: return (isCharging, fullyCharged)
        case .notPluggedIn?: return (false, fullyCharged)
        case .charging?: return (true, false)
        case .full?: return (isCharging, true)
        case .onHold?, .chargeLimitReached?, .runningOnBattery?: return (false, false)
        }
    }
}
