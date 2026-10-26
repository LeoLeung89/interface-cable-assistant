import CoreGraphics
import Foundation
import WhatCableCore

/// What a shared read should include.
public struct HubReadRequest: Sendable {
    public var readsChargerWatts: Bool
    public var displayBitsPerComponent: [CGDirectDisplayID: Int]
    public var includesPhy: Bool

    public init(
        readsChargerWatts: Bool,
        displayBitsPerComponent: [CGDirectDisplayID: Int],
        includesPhy: Bool
    ) {
        self.readsChargerWatts = readsChargerWatts
        self.displayBitsPerComponent = displayBitsPerComponent
        self.includesPhy = includesPhy
    }
}

/// Everything one shared read produced, ready to hand to each watcher's `apply(_:)`.
public struct HubReading: Sendable, Equatable {
    public let ports: AppleHPMInterfaceWatcher.Reading
    public let pd: USBPDSOPWatcher.Reading
    public let power: PowerSourceWatcher.Reading
    public let thunderbolt: IOIOThunderboltSwitchWatcher.Reading
    public let usb3: [USB3Transport]
    public let trm: TRMTransportWatcher.Reading
    public let phy: AppleTypeCPhyWatcher.Reading?
    public let display: [DisplayPortTransportWatcher.DisplayPortUpdate]
    public let uvdm: [AppleAccessoryIdentity]
}

/// The one place the hardware read order and the power-synthesis wiring live.
/// The watcher hub and `DarwinSnapshotProvider` both call it. It touches no
/// watcher instance state, so it is safe off the main thread.
public enum HubRead {
    nonisolated public static func readAll(_ request: HubReadRequest, smcReader: SMCPowerReader) -> HubReading {
        let ports = AppleHPMInterfaceWatcher.readPorts()
        // PD before power: synthesis's partner-kind rung needs this read's identities, not the last tick's
        let pd = USBPDSOPWatcher.readIdentities()
        let power = PowerSourceWatcher.readSources(
            synthesis: .live(ports: ports.ports, identities: pd.identities),
            smcReader: smcReader,
            readCharger: request.readsChargerWatts
        )
        let thunderbolt = IOIOThunderboltSwitchWatcher.readSwitches()
        let usb3 = USB3TransportWatcher.readTransports()
        let trm = TRMTransportWatcher.readTransports()
        let phy = request.includesPhy ? AppleTypeCPhyWatcher.readPhys() : nil
        let display = DisplayPortTransportWatcher.readStatuses(bitsPerComponent: request.displayBitsPerComponent)
        let uvdm = AppleUVDMWatcher.readIdentities()
        return HubReading(
            ports: ports, pd: pd, power: power, thunderbolt: thunderbolt, usb3: usb3,
            trm: trm, phy: phy, display: display, uvdm: uvdm
        )
    }
}
