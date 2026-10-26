import Foundation
import Testing
@testable import WhatCableCore
@testable import WhatCableDarwinBackend

@Suite struct HubReadTests {
    @Test func readAllRunsOffMainAndMatchesTheWatchers() async {
        let bpc = await MainActor.run { DisplayModeReader.currentBitsPerComponent() }
        let smc = SMCPowerReader()
        let request = HubReadRequest(readsChargerWatts: false, displayBitsPerComponent: bpc, includesPhy: true)
        let reading = await Task.detached { HubRead.readAll(request, smcReader: smc) }.value
        let ports = await MainActor.run { AppleHPMInterfaceWatcher.readPorts() }
        #expect(reading.ports.ports.map(\.id) == ports.ports.map(\.id))
        #expect(reading.phy != nil)
        let noPhy = HubRead.readAll(HubReadRequest(readsChargerWatts: false, displayBitsPerComponent: bpc, includesPhy: false), smcReader: smc)
        #expect(noPhy.phy == nil)
        #expect(noPhy.power.charger == nil)
        smc.close()
    }
}
