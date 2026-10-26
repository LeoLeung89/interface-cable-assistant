import Foundation
import Testing
import WhatCableCore
@testable import WhatCablePlugins

struct LabTests {
    @Test func nativeDisplayLabelsRoundTripAndRejectUnsupportedOrInvalidData() throws {
        var labels = LabNativeLabels()
        var profile = NamedCable(name: "HDMI")
        profile.connectionTitle = "28C1Q"
        profile.connectorType = "HDMI"
        labels.ports["Port-HDMI@1"] = profile
        let restored = try LabNativeLabels.decode(JSONEncoder().encode(labels))
        #expect(restored.ports["Port-HDMI@1"] == profile)
        #expect(restored.ports["Port-HDMI@2"] == nil)
        labels.version = 2
        #expect(throws: (any Error).self) { try LabNativeLabels.decode(JSONEncoder().encode(labels)) }
        labels.version = 1
        labels.ports["Port-HDMI@1"]?.connectionTitle = String(repeating: "a", count: 81)
        #expect(throws: (any Error).self) { try LabNativeLabels.decode(JSONEncoder().encode(labels)) }
    }
    @Test func suggestionsUseDeviceIdentityWithoutInventingCableMaximum() {
        let display = LabConnectionSuggestions(displayName: "RV200 Pro MAX", accessoryName: nil,
            hasDisplay: true, hasUSBDevices: false, isThunderbolt: false, declaredSpeed: nil)
        #expect(display.title == "RV200 Pro MAX")
        #expect(display.kind == "USB-C 转 DP（建议）")
        #expect(display.maximum.isEmpty)
        let usb = LabConnectionSuggestions(displayName: "RV200 Pro", accessoryName: nil,
            hasDisplay: true, hasUSBDevices: true, isThunderbolt: false, declaredSpeed: .usb4Gen4)
        #expect(usb.kind == "USB-C（建议）")
        #expect(usb.maximum.contains("80 Gbps"))
        let ambiguous = LabConnectionSuggestions(displayName: nil, accessoryName: "扩展坞",
            hasDisplay: false, hasUSBDevices: true, isThunderbolt: true, declaredSpeed: .usb4Gen3)
        #expect(ambiguous.title == "扩展坞")
        #expect(ambiguous.maximum.contains("20/40"))
    }
    @Test func connectionPresentationPreservesManualSourceAndOldProfiles() throws {
        let old = NamedCable(name: "旧档案")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        for key in ["connectionTitle", "connectorType", "maximumCapability"] { json.removeValue(forKey: key) }
        let restored = try JSONDecoder().decode(NamedCable.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(restored.connectionTitle.isEmpty)
        #expect(restored.widgetCableDescription == nil)
        var profile = restored
        profile.connectionTitle = "左侧显示器"
        profile.connectorType = "USB-C 转 DP"
        profile.maximumCapability = "最高 DP 1.4"
        let decoded = try JSONDecoder().decode(NamedCable.self, from: JSONEncoder().encode(profile))
        #expect(decoded == profile)
        #expect(decoded.widgetCableDescription == "USB-C 转 DP（最高 DP 1.4，手动）")
        profile.connectorType = ""
        #expect(profile.widgetCableDescription == nil)
    }
    @Test func testCableNameDoesNotFollowReplacementOrReconnection() {
        var binding = LabBindings()
        let first = UUID()
        binding.update(["2/1": "first-session", "2/2": "other-session"])
        binding.assign(first, to: "2/1")
        binding.update(["2/1": "first-session", "2/2": "changed-session"])
        #expect(binding.assignments["2/1"] == first)
        binding.update(["2/1": "replacement-session"])
        #expect(binding.assignments["2/1"] == nil)
        binding.assign(first, to: "2/1")
        binding.update([:])
        binding.update(["2/1": "replacement-session"])
        #expect(binding.assignments["2/1"] == nil)
        binding.assign(first, to: "disconnected-port")
        #expect(binding.assignments["disconnected-port"] == nil)
    }

    @Test func testContractMaximumIsNeverPlottedAsMeasuredPower() {
        var history = LabHistory()
        let date = Date(timeIntervalSince1970: 100)
        let measured = port("2/1", smc: true, fallback: false)
        let contract = port("2/2", smc: false, fallback: true)
        let staleController = port("2/3", smc: false, fallback: false)
        history.append(snapshot(date, ports: [measured, contract, staleController]))
        #expect(Set(history.points.map(\.series)) == Set(["system", "2/1"]))
        #expect(history.points.first { $0.series == "2/1" }?.watts == 5)
    }

    @Test func testChartBreaksAtPowerSourceSwitchAndGapsAndPrunesOldPoints() {
        var history = LabHistory(retention: 10)
        history.append(snapshot(Date(timeIntervalSince1970: 100)))
        history.append(snapshot(Date(timeIntervalSince1970: 101), onBattery: true))
        history.append(snapshot(Date(timeIntervalSince1970: 106), onBattery: true))
        #expect(history.points.map(\.segment) == [0, 1, 2])
        history.append(snapshot(Date(timeIntervalSince1970: 120), onBattery: true))
        #expect(history.points.count == 1)
        #expect(history.points.first?.watts == 10)
    }

    @Test func testUnstableResistanceIsNotPresentedAsAReading() {
        let estimate = CableResistanceEstimate(milliohms: 123.456, sampleCount: 3, rSquared: 0, status: .unreliable)
        #expect(!LabText.resistance(estimate).contains("123"))
        #expect(LabText.resistance(estimate).contains("不可靠"))
    }

    @Test func testTerminalDeviceNamesCannotInjectEscapeSequencesOrNewlines() {
        let hostile = "Monitor\u{1B}[2J\n\r\u{07}Fake header"
        let clean = LabText.terminal(hostile)
        #expect(!clean.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        #expect(clean.contains("Monitor"))
    }

    private func port(_ key: String, smc: Bool, fallback: Bool) -> PortPowerSample {
        PortPowerSample(portIndex: 1, portKey: key, current: 1000, watts: 5000,
            configuredVoltage: 5000, configuredCurrent: 1000, adapterVoltage: 5000,
            vconnCurrent: 0, vconnPower: 0, pdPowerMW: 100000,
            isContractedFallback: fallback, isSMCMeasured: smc)
    }

    private func snapshot(_ date: Date, ports: [PortPowerSample] = [], onBattery: Bool = false) -> PowerMonitorSnapshot {
        PowerMonitorSnapshot(timestamp: date,
            systemSample: PowerSample(timestamp: date, systemVoltageIn: 20000, systemCurrentIn: 1000, systemPowerIn: 20000),
            portSamples: ports, resistanceEstimate: nil, externalConnected: !onBattery,
            batteryInstalled: true, batteryVoltageMV: 10000, batteryCurrentMA: 1000, batteryPowerMW: 10000)
    }
}
