import Foundation
import Testing
@testable import WhatCablePlugins

struct LabArchiveTests {
    private func time(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
    private func observation(token: String = "one", fingerprint: String? = "model-A", speed: Double? = 80,
                             displays: [LabDisplayReading] = []) -> LabObservation {
        LabObservation(port: "2/1", token: token, fingerprint: fingerprint, linkGbps: speed, displays: displays)
    }

    @Test func lateEmarkerIsNotAReconnectionAndAssignmentSurvives() {
        var engine = LabArchiveEngine()
        _ = engine.ingest([observation(fingerprint: nil)], at: time(1))
        let cable = UUID(); engine.assign(cable, port: "2/1")
        _ = engine.ingest([observation()], at: time(2))
        #expect(engine.archive.sessions.count == 1)
        #expect(engine.archive.sessions.first?.cableID == cable)
        #expect(engine.archive.sessions.first?.fingerprint == "model-A")
        _ = engine.ingest([observation(fingerprint: "model-B")], at: time(3))
        #expect(engine.archive.sessions.count == 2)
        #expect(engine.archive.sessions.last?.cableID == nil)
    }

    @Test func reconnectWarningHasThresholdAndCooldown() {
        var engine = LabArchiveEngine()
        for t in [1.0, 10, 20, 30] {
            _ = engine.ingest([], at: time(t))
            _ = engine.ingest([observation(token: String(t))], at: time(t + 1))
        }
        #expect(engine.archive.events.filter { $0.kind == "reconnect" && $0.warning }.count == 1)
        #expect(engine.archive.sessions.count == 4)
    }

    @Test func transientLinkDipIsIgnoredAndSustainedDipWarns() {
        var engine = LabArchiveEngine()
        _ = engine.ingest([observation()], at: time(1))
        _ = engine.ingest([observation(speed: 40)], at: time(2))
        _ = engine.ingest([observation()], at: time(3))
        #expect(engine.archive.events.filter(\.warning).isEmpty)
        for t in 4...6 { _ = engine.ingest([observation(speed: 40)], at: time(Double(t))) }
        #expect(engine.archive.events.filter { $0.kind == "speed" }.count == 1)
    }

    @Test func displayBaselineNeedsStableReadAndWarnsAfterRestart() {
        var engine = LabArchiveEngine()
        let good = LabDisplayReading(id: "display", name: "Monitor", mode: LabDisplayMode(width: 5120, height: 2880, hz: 72))
        let low = LabDisplayReading(id: "display", name: "Monitor", mode: LabDisplayMode(width: 3840, height: 2160, hz: 60))
        for t in 1...3 { _ = engine.ingest([observation(displays: [good])], at: time(Double(t))) }
        #expect(engine.archive.displayBaselines["display"] == good)
        engine = LabArchiveEngine(archive: engine.archive)
        for t in 4...6 { _ = engine.ingest([observation(displays: [low])], at: time(Double(t))) }
        #expect(engine.archive.events.contains { $0.kind.hasPrefix("display-low:") && $0.warning })
    }

    @Test func nativeHDMIDisplayDoesNotCreateFakeCableSession() {
        var engine = LabArchiveEngine()
        let display = LabDisplayReading(id: "hdmi", name: "HDMI", mode: LabDisplayMode(width: 2560, height: 2880, hz: 60))
        for t in 1...3 { _ = engine.ingest([], standaloneDisplays: [display], at: time(Double(t))) }
        #expect(engine.archive.sessions.isEmpty)
        #expect(engine.archive.displayBaselines["hdmi"] == display)
    }

    @Test func indistinguishableDisplaysDoNotGetAutomaticBaselines() {
        var engine = LabArchiveEngine()
        let display = LabDisplayReading(id: "duplicate", name: "Same model", mode: LabDisplayMode(width: 3840, height: 2160, hz: 60))
        for t in 1...4 { _ = engine.ingest([], standaloneDisplays: [display, display], at: time(Double(t))) }
        #expect(engine.archive.displayBaselines.isEmpty)
    }

    @Test func missingPowerReadingBreaksIntegrationEvenAcrossAShortGap() {
        var engine = LabArchiveEngine()
        engine.recordPower(series: "port:2/1", watts: 36, at: time(1))
        engine.retainPowerSeries([])
        engine.recordPower(series: "port:2/1", watts: 36, at: time(10))
        #expect(engine.archive.buckets.reduce(0) { $0 + $1.energyWh } == 0)
    }

    @Test @MainActor func profilePersistsAndLegacyNameIsPreserved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cable = NamedCable(name: "旧名称", fingerprint: "model")
        try JSONEncoder().encode([cable]).write(to: directory.appendingPathComponent("cables.json"))
        let model = LabModel(storageDirectory: directory)
        var edited = try #require(model.names.first)
        edited.length = "1.5 m"; edited.ratedSpecs = "240 W / 40 Gbps"; edited.notes = "外出使用"
        model.saveProfile(edited)
        let reopened = LabModel(storageDirectory: directory)
        #expect(reopened.names.first == edited)
        #expect(reopened.names.first?.id == cable.id)
        try FileManager.default.removeItem(at: directory)
    }

    @Test @MainActor func corruptArchiveIsNotOverwrittenByTheModel() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("archive-v1.json")
        let content = Data("unreadable history".utf8)
        try content.write(to: url)
        let model = LabModel(storageDirectory: directory, recordsArchive: true)
        #expect(!model.archiveWritable && model.storageError != nil)
        model.flush(force: true)
        #expect(try Data(contentsOf: url) == content)
        try FileManager.default.removeItem(at: directory)
    }

    @Test func energySplitsAtHourBoundaryAndSkipsMissingTime() {
        var engine = LabArchiveEngine()
        engine.recordPower(series: "system:input", watts: 36, at: time(3590))
        engine.recordPower(series: "system:input", watts: 36, at: time(3610))
        #expect(engine.archive.buckets.count == 2)
        #expect(abs(engine.archive.buckets.reduce(0) { $0 + $1.energyWh } - 0.2) < 0.00001)
        #expect(engine.archive.buckets.allSatisfy { abs($0.energyWh - 0.1) < 0.00001 })
        engine.recordPower(series: "system:input", watts: 36, at: time(7200))
        #expect(abs(engine.archive.buckets.reduce(0) { $0 + $1.energyWh } - 0.2) < 0.00001)
    }

    @Test func powerDoesNotLeakAcrossCableReplacementOrPause() {
        var engine = LabArchiveEngine()
        _ = engine.ingest([observation()], at: time(1))
        engine.recordPower(series: "port:2/1", watts: 36, at: time(2))
        _ = engine.ingest([observation(token: "two")], at: time(3))
        engine.recordPower(series: "port:2/1", watts: 36, at: time(4))
        #expect(engine.archive.buckets.reduce(0) { $0 + $1.energyWh } == 0)
        engine.recordPower(series: "port:2/1", watts: 36, at: time(14))
        #expect(abs((engine.archive.sessions.last?.energyWh ?? 0) - 0.1) < 0.00001)
        engine.pause(at: time(15)); engine.archive.recording = false
        engine.recordPower(series: "port:2/1", watts: 100, at: time(20))
        #expect(abs(engine.archive.buckets.reduce(0) { $0 + $1.energyWh } - 0.1) < 0.00001)
    }

    @Test func restartClosesUnfinishedObservationsWithoutClaimingDisconnect() {
        var first = LabArchiveEngine()
        _ = first.ingest([observation()], at: time(1))
        _ = first.ingest([observation()], at: time(10))
        let second = LabArchiveEngine(archive: first.archive)
        #expect(second.archive.sessions.first?.ended == time(10))
        #expect(second.archive.sessions.first?.endReason?.contains("非已确认断开") == true)
        #expect(second.archive.events.filter { $0.kind == "disconnect" }.isEmpty)
    }

    @Test func archiveRoundTripAndCorruptDataProtection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LabArchiveStore(url: directory.appendingPathComponent("archive.json"))
        var archive = LabArchive(); archive.portLabels["2/1"] = "背面左侧"; archive.recording = false
        try store.save(archive)
        let loaded = try store.load()
        #expect(loaded.portLabels["2/1"] == "背面左侧")
        #expect(!loaded.recording)
        let invalid = Data("broken data".utf8)
        try invalid.write(to: store.url)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(try Data(contentsOf: store.url) == invalid)
        try FileManager.default.removeItem(at: directory)
    }

    @Test func legacyCableNamesDecodeWithoutLosingIdentity() throws {
        let id = UUID()
        let data = Data("{\"id\":\"\(id.uuidString)\",\"name\":\"旧线缆\",\"fingerprint\":\"abc\"}".utf8)
        let cable = try JSONDecoder().decode(NamedCable.self, from: data)
        #expect(cable.id == id && cable.fingerprint == "abc")
        #expect(cable.length.isEmpty && cable.notes.isEmpty && cable.photoFilename == nil)
        let decoded = try JSONDecoder().decode(NamedCable.self, from: JSONEncoder().encode(cable))
        #expect(decoded == cable)
    }

    @Test func retentionRemovesHistoryButKeepsDisplayAndPortPreferences() {
        var engine = LabArchiveEngine()
        _ = engine.ingest([observation()], at: time(1)); engine.pause(at: time(2))
        engine.archive.portLabels["2/1"] = "左侧"
        engine.archive.retentionDays = 7
        engine.prune(at: time(86400 * 10))
        #expect(engine.archive.sessions.isEmpty && engine.archive.events.isEmpty)
        #expect(engine.archive.portLabels["2/1"] == "左侧")
    }

    @Test func exportedUserTextCannotBecomeSpreadsheetFormulaOrMarkdownImage() {
        #expect(LabCSV.cell("=HYPERLINK(\"https://example.invalid\")").hasPrefix("\"'="))
        #expect(LabReport.escape("![image](https://example.invalid)").contains("\\["))
    }
}
