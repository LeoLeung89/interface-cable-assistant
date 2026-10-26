import Foundation

/// Per-port federated identity from the AppleSmartBattery's FedDetails array.
/// Each entry describes the PD partner connected to a physical port, using
/// data the battery controller collects independently of the HPM/TC services.
/// Available on laptops only (the array is absent or all-zeros on desktops).
public struct FederatedIdentity: Hashable, Sendable {
    /// 1-based port index (offset in the FedDetails array + 1).
    public let portIndex: Int
    public let vendorID: Int
    public let productID: Int
    public let pdSpecRevision: Int
    /// 0 = sink, 1 = source.
    public let powerRole: Int
    public let dualRolePower: Bool
    public let externalConnected: Bool

    public init(
        portIndex: Int,
        vendorID: Int,
        productID: Int,
        pdSpecRevision: Int,
        powerRole: Int,
        dualRolePower: Bool,
        externalConnected: Bool
    ) {
        self.portIndex = portIndex
        self.vendorID = vendorID
        self.productID = productID
        self.pdSpecRevision = pdSpecRevision
        self.powerRole = powerRole
        self.dualRolePower = dualRolePower
        self.externalConnected = externalConnected
    }

    /// True when this entry represents an actual connected device (VID != 0).
    public var hasDevice: Bool { vendorID != 0 }
}

extension FederatedIdentity {
    /// FedDetails evidence that a charger is attached to `port`, used where no
    /// per-port `IOPortFeaturePowerSource` node exists (M1 Pro/Max/Ultra USB-C,
    /// issue #459). The single source of truth for that gate, shared by
    /// `ChargingDiagnostic` (the standby banner) and `PortSummary` (the port
    /// card headline) so the two never diverge.
    ///
    /// Gates:
    ///  - `port` is a **USB-C** port. The FedDetails `portIndex == portNumber`
    ///    map is corpus-validated only for USB-C (29/29); MagSafe shares the
    ///    same port numbers (MagSafe 3@1 vs USB-C@1), so without this gate a
    ///    source-less MagSafe port could borrow USB-C 1's FedDetails entry.
    ///  - `portIsLive`: the caller's liveness signal. `FedExternalConnected`
    ///    lingers after unplug (~40% stale in the corpus), so a live-connection
    ///    gate is what makes the read trustworthy.
    ///  - the matched entry says a source is attached (`externalConnected`) with
    ///    the Mac as the **sink** (`powerRole == 0`), not sourcing power out to
    ///    a phone (`powerRole == 1`), which would read backwards.
    public static func chargerPresent(
        on port: AppleHPMInterface,
        in federatedIdentities: [FederatedIdentity],
        portIsLive: Bool
    ) -> Bool {
        guard portIsLive,
              port.portTypeDescription == "USB-C",
              let number = port.portNumber,
              let fed = federatedIdentities.first(where: { $0.portIndex == number })
        else { return false }
        return fed.externalConnected && fed.powerRole == 0
    }
}
