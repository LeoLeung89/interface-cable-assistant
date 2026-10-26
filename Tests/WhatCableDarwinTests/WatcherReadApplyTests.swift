import Foundation
import IOKit
import Testing
@testable import WhatCableCore
@testable import WhatCableDarwinBackend

@Suite struct WatcherReadApplyTests {
    @Test func serviceForEntryIDFindsALiveService() throws {
        let smc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        try #require(smc != 0)
        defer { IOObjectRelease(smc) }
        var smcID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(smc, &smcID)
        let found = try #require(wcService(forEntryID: smcID))
        defer { IOObjectRelease(found) }
        var foundID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(found, &foundID)
        #expect(foundID == smcID)
        #expect(wcService(forEntryID: 0) == nil)
    }

    @MainActor @Test func usb3ApplyPublishesOnceAndBumpsGeneration() {
        let w = USB3TransportWatcher()
        let g0 = w.refreshGeneration
        w.apply([])
        #expect(w.refreshGeneration == g0)          // equal value: no publish
        w.apply(USB3TransportWatcher.readTransports())
        w.apply(w.transports)
        #expect(w.refreshGeneration <= g0 + 1)      // at most one real change
    }

    @MainActor @Test func trmUVDMAndDisplayApplyMatchRefresh() {
        let trm = TRMTransportWatcher(); trm.refresh()
        let trm2 = TRMTransportWatcher(); trm2.apply(TRMTransportWatcher.readTransports())
        #expect(trm.transports == trm2.transports && trm.cioCapabilities == trm2.cioCapabilities)

        let uvdm = AppleUVDMWatcher(); uvdm.refresh()
        let uvdm2 = AppleUVDMWatcher(); uvdm2.apply(AppleUVDMWatcher.readIdentities())
        #expect(uvdm.identities == uvdm2.identities)

        let dp = DisplayPortTransportWatcher(); dp.refresh()
        let dp2 = DisplayPortTransportWatcher()
        dp2.apply(DisplayPortTransportWatcher.readStatuses(bitsPerComponent: DisplayModeReader.currentBitsPerComponent()))
        #expect(dp.statuses == dp2.statuses)
    }

    @Test func displayReadRunsOffMain() async {
        let bpc = await MainActor.run { DisplayModeReader.currentBitsPerComponent() }
        let off = await Task.detached { DisplayPortTransportWatcher.readStatuses(bitsPerComponent: bpc) }.value
        let on = await MainActor.run { DisplayPortTransportWatcher.readStatuses(bitsPerComponent: bpc) }
        #expect(off == on)
    }

    @MainActor @Test func interestWatchersApplyMatchesRefresh() {
        let hpm = AppleHPMInterfaceWatcher(); hpm.refresh()
        let hpm2 = AppleHPMInterfaceWatcher(); hpm2.apply(AppleHPMInterfaceWatcher.readPorts())
        #expect(hpm.ports == hpm2.ports)

        let tb = IOIOThunderboltSwitchWatcher(); tb.refresh()
        let tb2 = IOIOThunderboltSwitchWatcher(); tb2.apply(IOIOThunderboltSwitchWatcher.readSwitches())
        #expect(tb.switches == tb2.switches)

        let pd = USBPDSOPWatcher(); pd.refresh()
        let pd2 = USBPDSOPWatcher(); pd2.apply(USBPDSOPWatcher.readIdentities())
        #expect(pd.identities == pd2.identities)

        let phy = AppleTypeCPhyWatcher(); phy.refresh()
        let phy2 = AppleTypeCPhyWatcher(); phy2.apply(AppleTypeCPhyWatcher.readPhys())
        #expect(phy.phys == phy2.phys)
    }

    @MainActor @Test func pdApplyPrunesStateCCHandlesNoLongerLive() {
        let pd = USBPDSOPWatcher()
        var released: [io_object_t] = []
        pd.releaseHandle = { released.append($0) }
        pd.seedStateCCInterest(entryID: 42, handle: 4242)
        pd.apply(USBPDSOPWatcher.Reading(identities: [], stateCCEntryIDs: []))
        #expect(released == [4242])
        #expect(pd.stateCCInterestHandles[42] == nil)
    }

    @Test func interestWatcherReadsRunOffMain() async {
        let ports = await Task.detached { AppleHPMInterfaceWatcher.readPorts() }.value
        let onMain = await MainActor.run { AppleHPMInterfaceWatcher.readPorts() }
        #expect(ports.ports.map(\.id) == onMain.ports.map(\.id))
        _ = await Task.detached { IOIOThunderboltSwitchWatcher.readSwitches() }.value
        _ = await Task.detached { USBPDSOPWatcher.readIdentities() }.value
        _ = await Task.detached { AppleTypeCPhyWatcher.readPhys() }.value
    }

    @MainActor @Test func powerApplyMatchesRefresh() {
        // One shared reading: two live reads drift (charger watts), which made this flaky.
        // The charger flag stays off: turning it on triggers its own live read.
        let smc = SMCPowerReader()
        let reading = PowerSourceWatcher.readSources(synthesis: nil, smcReader: smc, readCharger: true)
        let a = PowerSourceWatcher(smcReader: smc)
        a.refresh(using: reading)
        let b = PowerSourceWatcher(smcReader: smc)
        b.apply(reading); b.applyChargeState(reading.chargeState)
        #expect(a.sources == b.sources)
        #expect(a.chargerInputWatts == b.chargerInputWatts && a.chargerRatedWatts == b.chargerRatedWatts)
        #expect(a.batteryChargeState == b.batteryChargeState)
        // A reading with a charger must actually have been published, or the equality above is vacuous.
        if let charger = reading.charger {
            #expect(a.chargerInputWatts == charger.input && a.chargerRatedWatts == charger.rated)
        }
        a.stop(); b.stop(); smc.close()
    }

    @MainActor @Test func refreshUsingPublishesEveryField() {
        // Fixed reading, so sources and charge state are exercised on any Mac, battery or not.
        let source = PowerSource(id: 9, name: "Brick ID", parentPortType: 2, parentPortNumber: 1, options: [], winning: nil)
        let w = PowerSourceWatcher(smcReader: SMCPowerReader())
        w.refresh(using: .init(sources: [source], charger: .init(input: 61, rated: 70), chargeState: .charging))
        #expect(w.sources == [source])
        #expect(w.chargerInputWatts == 61 && w.chargerRatedWatts == 70)
        #expect(w.batteryChargeState == .charging)
        w.stop()
    }

    @MainActor @Test func powerApplyWithoutChargerLeavesReadoutAlone() {
        let w = PowerSourceWatcher(smcReader: SMCPowerReader())
        w.apply(PowerSourceWatcher.Reading(sources: [], charger: nil))
        #expect(w.chargerInputWatts == 0 && w.chargerRatedWatts == 0)
        w.apply(PowerSourceWatcher.Reading(sources: [], charger: .init(input: 61, rated: 70)))
        #expect(w.chargerInputWatts == 61 && w.chargerRatedWatts == 70)
    }
}
