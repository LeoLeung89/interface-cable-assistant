import Foundation
import Testing
import WhatCableLabWidgetShared

struct LabWidgetTests {
    private func packet(at time: Date = Date()) -> LabWidgetSnapshot {
        LabWidgetSnapshot(timestamp: time, systemWatts: 42.5, onBattery: false,
            ports: [LabWidgetPort(id: "2/1", title: "背面左侧", cableName: "我的显示器线", connected: true,
                protocols: "DisplayPort", measuredWatts: 0.12)],
            trend: [LabWidgetPowerPoint(time: time, watts: 42.5, source: "input", segment: 3)])
    }

    @Test func widgetSnapshotPreservesConfirmedNamesAndMeasuredValues() throws {
        let original = packet()
        let decoded = try LabWidgetSnapshot.decode(JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(decoded.ports.first?.cableName == "我的显示器线")
        #expect(decoded.trend.first?.segment == 3)
    }

    @Test func originalConnectionDetailsSurviveTransport() throws {
        var value = packet()
        value.ports[0].statusTitle = "显示器"
        value.ports[0].detail = "Studio Display · 5K 60Hz"
        value.ports[0].speedBadge = "40 Gbps"
        value.ports[0].deviceCount = 2
        value.ports[0].chargerWatts = 96
        let decoded = try LabWidgetSnapshot.decode(JSONEncoder().encode(value))
        #expect(decoded.ports[0] == value.ports[0])
    }

    @Test func previousCacheWithoutNewDetailsRemainsReadable() throws {
        let data = try JSONEncoder().encode(packet())
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var ports = try #require(json["ports"] as? [[String: Any]])
        for key in ["statusTitle", "detail", "speedBadge", "deviceCount", "chargerWatts", "iconName"] {
            ports[0].removeValue(forKey: key)
        }
        json["ports"] = ports
        let decoded = try LabWidgetSnapshot.decode(JSONSerialization.data(withJSONObject: json))
        #expect(decoded.ports[0].cableName == "我的显示器线")
        #expect(decoded.ports[0].detail == nil)
    }

    @Test func oldOrFutureSnapshotsCannotBePresentedAsCurrentPower() {
        let now = Date()
        #expect(packet(at: now).freshness(at: now) == .recent)
        #expect(packet(at: now.addingTimeInterval(-121)).freshness(at: now) == .delayed)
        #expect(packet(at: now.addingTimeInterval(-901)).freshness(at: now) == .expired)
        #expect(packet(at: now.addingTimeInterval(61)).freshness(at: now) == .expired)
    }

    @Test func unsupportedCacheVersionIsRejected() throws {
        var value = packet(); value.version = 2
        let data = try JSONEncoder().encode(value)
        #expect(throws: (any Error).self) { try LabWidgetSnapshot.decode(data) }
    }

    @Test func oversizedCacheCannotExhaustWidgetMemory() {
        let data = Data(repeating: 32, count: 1_000_001)
        #expect(throws: (any Error).self) { try LabWidgetSnapshot.decode(data) }
    }

    @Test func excessivePortCountIsRejected() throws {
        var value = packet()
        value.ports = Array(repeating: value.ports[0], count: 17)
        let data = try JSONEncoder().encode(value)
        #expect(throws: (any Error).self) { try LabWidgetSnapshot.decode(data) }
    }

    @Test func hostWaitsForSystemCreatedWidgetContainer() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        #expect(LabWidgetSnapshot.hostCacheURL(home: home) == nil)
        let data = home.appendingPathComponent("Library/Containers/\(LabWidgetSnapshot.extensionID)/Data")
        #expect(!FileManager.default.fileExists(atPath: data.path))
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let target = try #require(LabWidgetSnapshot.hostCacheURL(home: home))
        #expect(target.path.hasPrefix(data.path))
        #expect(target.lastPathComponent == "widget-v1.json")
        #expect(!LabWidgetSnapshot.extensionID.contains("uk.whatcable"))
        try FileManager.default.removeItem(at: home)
    }
}
