import Foundation

/// Recognises a Mac cabled directly to another Mac over Thunderbolt.
///
/// The signature is five things holding at once: the port's CIO transport
/// is active, the CIO row's peer `Metadata` is empty, nothing is
/// provisioned through the tunnel, no partner switch hangs off the host
/// root, and an Apple USB 2.0 root device named as a Mac sits on the port.
/// The USB product ID is evidence, not the gate: it is per model (0x1902,
/// 0x1905 and 0x7307 seen so far) and a new Mac would arrive with a new
/// one. An Apple Vision Pro (0x12B1) shares the whole CIO half of this
/// signature, so the product name is what separates the two, and any name
/// that does not say "mac" fails closed.
public enum HostToHostLink {
    private static let appleVendorID: UInt16 = 0x05AC
    private static let usb2SpeedRaw: UInt8 = 2

    /// The peer Mac on this port's own device list, or nil.
    public static func peerMac(in devices: [USBDevice]) -> USBDevice? {
        devices.first { device in
            device.vendorID == appleVendorID
                && device.speedRaw == usb2SpeedRaw
                && !device.isThunderboltTunnelled
                && device.isRootDevice
                && (device.productName?.lowercased().contains("mac") ?? false)
        }
    }

    /// True only when every part of the signature holds. `devices` and
    /// `cio` are the port's own, already matched by the caller.
    public static func isHostToHost(
        port: AppleHPMInterface,
        devices: [USBDevice],
        cio: CIOCableCapability?,
        thunderboltSwitches: [IOThunderboltSwitch]
    ) -> Bool {
        guard port.transportsActive.contains("CIO") else { return false }
        guard let cio,
              cio.hasPeerMetadata == false,
              cio.tunneledTransportsProvisioned?.isEmpty == true else { return false }
        guard !thunderboltSwitches.isEmpty,
              let socketID = ThunderboltTopology.socketID(for: port),
              ThunderboltTopology.hostRoot(forSocketID: socketID, in: thunderboltSwitches) != nil,
              DataLinkDiagnostic.partnerSwitch(port: port, switches: thunderboltSwitches) == nil
        else { return false }
        return peerMac(in: devices) != nil
    }
}
