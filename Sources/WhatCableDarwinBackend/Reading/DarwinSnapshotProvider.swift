import Foundation
import os.log
import WhatCableCore

/// macOS implementation of `CableSnapshotProvider`. Takes the shared
/// `HubRead` hardware read, publishes it through the IOKit watcher classes
/// and assembles their state into a `CableSnapshot`.
///
/// `snapshot()` starts the watchers once, refreshes the polling-driven ones
/// (the others fire IOKit match notifications during start), and reads.
/// `watch()` keeps them started and polls for changes on a 1s timer.
/// Polling is sufficient because `AppleHPMInterfaceWatcher` already requires it for
/// property-change events; the others share the same loop for simplicity.
public final class DarwinSnapshotProvider: CableSnapshotProvider, @unchecked Sendable {
    public init() {}

    private static let log = Logger(subsystem: "uk.whatcable.whatcable", category: "charging")

    @MainActor
    private final class State {
        let portWatcher = AppleHPMInterfaceWatcher()
        let smcReader = SMCPowerReader()
        let powerWatcher: PowerSourceWatcher
        let pdWatcher = USBPDSOPWatcher()
        let usbWatcher = USBWatcher()
        let tbWatcher = IOIOThunderboltSwitchWatcher()
        let usb3Watcher = USB3TransportWatcher()
        let trmWatcher = TRMTransportWatcher()
        let phyWatcher = AppleTypeCPhyWatcher()
        let displayWatcher = DisplayPortTransportWatcher()
        let uvdmWatcher = AppleUVDMWatcher()
        var started = false
        /// The last read's undebounced charge state, for the one-shot confirm.
        var lastRawChargeState: BatteryChargeState?

        init() {
            powerWatcher = PowerSourceWatcher(smcReader: smcReader)
        }

        func ensureStarted() {
            guard !started else { return }
            portWatcher.start()
            powerWatcher.start()
            pdWatcher.start()
            usbWatcher.start()
            tbWatcher.start()
            usb3Watcher.start()
            trmWatcher.start()
            phyWatcher.start()
            displayWatcher.start()
            uvdmWatcher.start()

            started = true
        }

        func read() -> CableSnapshot {
            // One shared read (HubRead) in the fixed order, then each watcher
            // publishes its piece. AppleHPMInterface property changes don't
            // fire match notifications, so every read refreshes everything;
            // the others are notification-driven but the read is cheap and
            // keeps the snapshot consistent. Power synthesis (issue #401)
            // is built inside the read from this read's own ports and
            // identities.
            let reading = HubRead.readAll(
                HubReadRequest(readsChargerWatts: false,
                               displayBitsPerComponent: DisplayModeReader.currentBitsPerComponent(),
                               includesPhy: true),
                smcReader: smcReader
            )
            portWatcher.apply(reading.ports)
            pdWatcher.apply(reading.pd)
            powerWatcher.apply(reading.power)
            powerWatcher.applyChargeState(reading.power.chargeState)
            lastRawChargeState = reading.power.chargeState
            tbWatcher.apply(reading.thunderbolt)
            usb3Watcher.apply(reading.usb3)
            trmWatcher.apply(reading.trm)
            if let phy = reading.phy { phyWatcher.apply(phy) }
            displayWatcher.apply(reading.display)
            uvdmWatcher.apply(reading.uvdm)
            let battery = AppleSmartBatteryReader.read()
            let snap = CableSnapshot(
                ports: portWatcher.ports,
                powerSources: powerWatcher.sources,
                identities: pdWatcher.identities,
                usbDevices: usbWatcher.devices,
                adapter: SystemPower.currentAdapter(),
                thunderboltSwitches: tbWatcher.switches,
                isDesktopMac: battery.isDesktopMac,
                federatedIdentities: battery.federatedIdentities,
                usb3Transports: usb3Watcher.transports,
                trmTransports: trmWatcher.transports,
                cioCapabilities: trmWatcher.cioCapabilities,
                accessoryIdentities: uvdmWatcher.identities,
                typeCPhys: phyWatcher.phys,
                // statuses are enriched with the live CoreGraphics mode at the
                // watcher source now, so no enrich is needed here.
                displayPorts: displayWatcher.statuses.map(\.status),
                batteryFullyCharged: battery.battery?.fullyCharged,
                batteryIsCharging: battery.battery?.isCharging,
                batteryChargeState: powerWatcher.batteryChargeState
            )
            DarwinSnapshotProvider.logChargingSignals(snap)
            return snap
        }
    }

    @MainActor
    private static let state = State()

    /// One read for a one-shot caller (the CLI, the Dashboard's first paint,
    /// BenchReport). The time window can't elapse inside one read, so a
    /// running-on-battery result is confirmed by a second SMC read 2 s later.
    @MainActor
    public func snapshot() async throws -> CableSnapshot {
        Self.state.ensureStarted()
        var snap = Self.state.read()
        let smc = Self.state.smcReader
        snap.batteryChargeState = await PowerSourceWatcher.confirmedOneShotChargeState(
            first: Self.state.lastRawChargeState,
            readAgain: { PowerSourceWatcher.readChargeState(smcReader: smc) },
            sleep: { try? await Task.sleep(for: .seconds($0)) })
        return snap
    }

    private static func logChargingSignals(_ snap: CableSnapshot) {
        let activePorts = snap.ports.filter { $0.connectionActive == true }
        let adapterW = snap.adapter?.watts.map(String.init) ?? "none"
        log.debug(
            """
            charging signals: \(snap.ports.count) ports, \
            \(activePorts.count) active, \
            adapter \(adapterW)W
            """
        )
        for port in activePorts {
            guard let key = port.portKey else { continue }
            let sources = snap.powerSources.filter { $0.portKey == key }
            let names = sources.map { src -> String in
                let w = Int((Double(src.maxPowerMW) / 1000).rounded())
                return "\(src.name)(\(w)W)"
            }
            let label = port.portDescription ?? port.serviceName
            log.debug("  port \(label): sources=[\(names.joined(separator: ", "))]")
        }
    }

    public func watch() -> AsyncThrowingStream<CableSnapshot, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                Self.state.ensureStarted()
                var last: CableSnapshot? = nil
                while !Task.isCancelled {
                    let snap = Self.state.read()
                    if last != snap {
                        continuation.yield(snap)
                        last = snap
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

/// Default backend on Darwin platforms. CLI / GUI call this rather than
/// naming `DarwinSnapshotProvider` directly.
public func makeDefaultSnapshotProvider() -> any CableSnapshotProvider {
    DarwinSnapshotProvider()
}

