import Foundation
import IOKit
import IOKit.ps
import WhatCableCore

/// External power adapter info from the system. Independent of the per-port
/// IOKit views.
public enum SystemPower {
    public static func currentAdapter() -> AdapterInfo? {
        guard let info = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        let w = (info["Watts"] as? NSNumber)?.intValue
        let voltageMV = (info["AdapterVoltage"] as? NSNumber)?.intValue
        let currentMA = (info["Current"] as? NSNumber)?.intValue
        let desc = info["Description"] as? String
        let tier = (info["AdapterPowerTier"] as? NSNumber)?.intValue
        let wireless: Bool? = (info["IsWireless"] as? NSNumber)?.boolValue

        // UsbHvcMenu is an array of dicts, each with "Voltage" (mV) and
        // "Current" (mA) keys describing one combo the charger supports.
        // CF arrays from IOKit don't always bridge cleanly to Swift arrays,
        // so cast through NSArray/NSDictionary (same pattern as
        // PowerSourceWatcher.parseOptions).
        let hvcMenu: [AdapterHVCEntry] = {
            guard let arr = info["UsbHvcMenu"] as? NSArray else { return [] }
            return arr.compactMap { element -> AdapterHVCEntry? in
                let dict: [String: Any]?
                if let d = element as? [String: Any] {
                    dict = d
                } else if let nsd = element as? NSDictionary {
                    var converted: [String: Any] = [:]
                    for case let (key, val) as (String, Any) in nsd {
                        converted[key] = val
                    }
                    dict = converted
                } else {
                    dict = nil
                }
                guard let dict else { return nil }
                let v = (dict["Voltage"] as? NSNumber)?.intValue ?? 0
                let c = (dict["Current"] as? NSNumber)?.intValue ?? 0
                guard v > 0, c > 0 else { return nil }
                return AdapterHVCEntry(voltageMV: v, currentMA: c)
            }
        }()

        let hvcIndex = (info["UsbHvcHvcIndex"] as? NSNumber)?.intValue
        let familyCode = (info["FamilyCode"] as? NSNumber)?.intValue
        let adapterID = (info["AdapterID"] as? NSNumber)?.intValue
        let pmuConfig = (info["PMUConfiguration"] as? NSNumber)?.intValue

        // IOKit can return empty strings for the identity fields when
        // the adapter is unknown or not yet enumerated. Treat empty
        // same as missing so the consumer doesn't special-case both.
        // Accepts both String and NSNumber: `Model` has always been a
        // string in observed samples ("0x7019"), but the dict typing
        // is `[String: Any]` and a different brick could return it as
        // a number; recover that case rather than drop the value.
        let trim: (Any?) -> String? = { value in
            let raw: String?
            if let s = value as? String {
                raw = s
            } else if let n = value as? NSNumber {
                raw = n.stringValue
            } else {
                raw = nil
            }
            guard let s = raw else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }

        return AdapterInfo(
            watts: w,
            isCharging: nil,
            source: "AC",
            voltageMV: voltageMV,
            currentMA: currentMA,
            adapterDescription: desc,
            powerTier: tier,
            isWireless: wireless,
            hvcMenu: hvcMenu,
            hvcActiveIndex: hvcIndex,
            familyCode: familyCode,
            adapterID: adapterID,
            pmuConfiguration: pmuConfig,
            manufacturer: trim(info["Manufacturer"]),
            name: trim(info["Name"]),
            model: trim(info["Model"])
        )
    }

    /// AppleSmartBattery's FullyCharged flag. `nil` on desktop Macs / when
    /// no battery is present. Same source the snapshot pipeline uses, so
    /// the GUI and CLI agree on battery-full state.
    public static func batteryFullyCharged() -> Bool? {
        AppleSmartBatteryReader.read().battery?.fullyCharged
    }

    /// AppleSmartBattery's IsCharging flag. `nil` on desktop Macs / when no
    /// battery is present. `false` while a charger is connected but macOS
    /// has paused charging (charge limit or Optimized Battery Charging).
    public static func batteryIsCharging() -> Bool? {
        AppleSmartBatteryReader.read().battery?.isCharging
    }
}

extension ChargingDiagnostic {
    /// Convenience: fetches the system adapter via IOKit and constructs
    /// a diagnostic. Callers that need a custom adapter (e.g. tests)
    /// can use the core init that takes `adapter:` explicitly.
    public init?(
        port: AppleHPMInterface,
        sources: [PowerSource],
        identities: [USBPDSOP]
    ) {
        self.init(
            port: port,
            sources: sources,
            identities: identities,
            adapter: SystemPower.currentAdapter()
        )
    }
}

