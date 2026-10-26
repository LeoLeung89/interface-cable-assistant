import Foundation
import Testing
@testable import WhatCableCore
@testable import WhatCableDarwinBackend

// Replays every battery Mac's probe 34 (raw SMC keys) through the shipping
// chain: the reader's byte assembly, then `BatteryChargeState.decide`. The
// oracle below is an independent transcription of the decision order, with
// its own hex decode, not from
// the production code. Probe 34's printed "= N" decode is big-endian and is
// never read.
@Suite("Battery charge state - corpus sweep (probes 32/34)")
struct BatteryChargeStateCorpusSweepTests {

    /// Probe 34 rows as printed, key to raw hex. A row is kept only when its
    /// hex is exactly twice its printed size, so the half-written last line of
    /// an output cut at the pipe cap is dropped rather than misread.
    static func rawHex(_ text: String) -> [String: String] {
        var rows: [String: String] = [:]
        for line in text.split(separator: "\n") {
            // "  CHNC hex_  8    raw=8000000000000000"
            let t = line.split(separator: " ", omittingEmptySubsequences: true)
            guard t.count >= 4, t[0].count == 4, let size = Int(t[2]), size > 0,
                  t[3].hasPrefix("raw=") else { continue }
            let hex = String(t[3].dropFirst(4))
            guard hex.count == size * 2, hex.allSatisfy(\.isHexDigit) else { continue }
            rows[String(t[0])] = hex
        }
        return rows
    }

    /// The oracle's decode: reverse the byte pairs, read as one hex number.
    static func le(_ hex: String) -> UInt64? {
        var pairs: [String] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            pairs.append(String(hex[i..<j]))
            i = j
        }
        return UInt64(pairs.reversed().joined(), radix: 16)
    }

    /// The reference order. nil where no state can be decided.
    static func oracle(_ hex: [String: String]) -> BatteryChargeState? {
        func v(_ key: String) -> UInt64? { hex[key].flatMap { Self.le($0) } }
        if let ch0r = v("CH0R"), ch0r & 0xFFFF & ~UInt64(0x100) != 0 {
            // On battery either way. Split only so an unplugged Mac is
            // never shown as plugged in.
            return v("CHCE") == 0 ? .notPluggedIn : .runningOnBattery
        }
        guard let chce = v("CHCE") else { return nil }
        if chce == 0 { return .notPluggedIn }
        guard let chcc = v("CHCC") else { return nil }
        if chcc == 0 { return .runningOnBattery }
        if let aci = v("AC-i"), aci < 100 { return .runningOnBattery }
        guard let bsfc = v("BSFC") else { return nil }
        if bsfc != 0 { return .full }
        var limit: UInt64 = 0
        if let chwa = v("CHWA") {                       // CHWA wins; CHLS not read
            if chwa != 0 { limit = 80 - 5 }
        } else if let chls = v("CHLS") {                // CHLS only without CHWA
            if chls & 0xFF >= 10 { limit = (chls & 0xFF) - 5 }
        }
        let limited = limit > 0 && (v("BUIC").map { $0 >= limit } ?? false)
        // CHNC counts only at 8 bytes (16 hex digits).
        if hex["CHNC"]?.count == 16, let chnc = v("CHNC") {
            if chnc & 1 != 0 { return .full }
            if chnc == 1 << 23 && !limited { return .charging }
            if chnc & (1 << 24) != 0 { return .chargeLimitReached }
            return chnc != 0 ? .onHold : .charging
        }
        guard let chsc = v("CHSC") else { return nil }
        return chsc != 0 ? .charging : .onHold
    }

    /// The shipping path: the probe's bytes through the reader, then the chain.
    static func production(_ hex: [String: String]) -> BatteryChargeState? {
        let inputs = SMCPowerReader.batteryChargeInputs(read: { key in
            guard let h = hex[key] else { return nil }
            return stride(from: 0, to: h.count, by: 2).map { offset in
                let start = h.index(h.startIndex, offsetBy: offset)
                return UInt8(h[start..<h.index(start, offsetBy: 2)], radix: 16)!
            }
        })
        return BatteryChargeState.decide(inputs)
    }

    /// Today's mapping from the battery record, the app's fallback when the
    /// chain returns nil.
    static func legacy(isCharging: Bool?, fullyCharged: Bool?) -> BatteryChargeState? {
        if fullyCharged == true { return .full }
        switch isCharging {
        case true?: return .charging
        case false?: return .onHold
        case nil: return nil
        }
    }

    /// IsCharging / FullyCharged from probe 32's AppleSmartBattery section.
    static func batteryRecord(_ folder: String) -> (isCharging: Bool?, fullyCharged: Bool?) {
        guard let text = CorpusPowerProbes.text(folder: folder, probe: "32_smart_battery_full_keys") else { return (nil, nil) }
        let props = CorpusPowerProbes.probe32Properties(text)
        return ((props["IsCharging"] as? NSNumber)?.boolValue, (props["FullyCharged"] as? NSNumber)?.boolValue)
    }

    /// Every battery folder's probe 34 keys (a battery Mac publishes `B0AV`).
    static func batteryFolders() -> [(folder: String, hex: [String: String])] {
        CorpusPowerProbes.folders().compactMap { folder -> (folder: String, hex: [String: String])? in
            guard let text = CorpusPowerProbes.textAllowingTruncation(folder: folder, probe: "34_smc_power_keys") else { return nil }
            let hex = Self.rawHex(text)
            return hex["B0AV"] == nil ? nil : (folder, hex)
        }
    }

    @Test("The shipping chain matches the reference order on every battery folder")
    func chainMatchesOracle() {
        var checked = 0
        for (folder, hex) in Self.batteryFolders() {
            checked += 1
            let expected = Self.oracle(hex)
            let actual = Self.production(hex)
            #expect(actual == expected, "\(folder): chain \(String(describing: actual)), reference order \(String(describing: expected))")
        }
        #expect(checked > 0, "No battery folder parsed from probe 34; the rule checked nothing")
    }

    @Test("IsCharging true with CHNC zero resolves to charging")
    func chargingRecordWithClearCHNC() {
        var checked = 0
        for (folder, hex) in Self.batteryFolders() {
            guard hex["CHNC"]?.count == 16, let chnc = hex["CHNC"].flatMap(Self.le), chnc == 0 else { continue }
            let record = Self.batteryRecord(folder)
            guard record.isCharging == true else { continue }
            checked += 1
            // Resolved, as the app does it: where a required key is missing the
            // chain returns nil and the battery record decides. Applied to the
            // raw chain output this rule fails on exactly those folders.
            let resolved = Self.production(hex)
                ?? Self.legacy(isCharging: record.isCharging, fullyCharged: record.fullyCharged)
            #expect(resolved == .charging, "\(folder): resolved \(String(describing: resolved))")
        }
        #expect(checked > 0, "No folder had IsCharging true with CHNC 0; the rule checked nothing")
    }
}
