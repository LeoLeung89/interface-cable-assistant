import Foundation

/// Strict "prefix + digits" matching for the Apple Silicon Thunderbolt PCIe
/// tunnel roots (`apciecN`) and Thunderbolt HAL roots (`acioN`). Shared by
/// `USBWatcher` (walking up to `apciecN` from a tunnelled `AppleUSBXHCITR`
/// controller) and `IOIOThunderboltSwitchWatcher` (walking up to `acioN`
/// from a host-root switch).
///
/// A loose `hasPrefix` check (the original implementation) would also match
/// an unrelated sibling registry name that happens to start with the same
/// letters, e.g. a hypothetical `apciecXfoo` or `apciecDebug` node. The
/// index digits are load-bearing: `ChainDeviceAttribution`'s structural
/// tunnel join and the apciec<->acio port-scoping join both compare these
/// names for exact equality, so a loosely-matched name that isn't really
/// `"apciec" + digits` would silently corrupt that comparison. Flagged in
/// review.
enum RegistryRootNaming {
    /// True when `name` is EXACTLY `prefix` followed by one or more ASCII
    /// digits and nothing else (e.g. `isRootName("apciec2", prefix: "apciec")`
    /// is true; `isRootName("apciecDebug", prefix: "apciec")` is false).
    static func isRootName(_ name: String, prefix: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        let suffix = name.dropFirst(prefix.count)
        return !suffix.isEmpty && suffix.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
