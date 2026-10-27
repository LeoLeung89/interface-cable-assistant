import Foundation
import Testing
@testable import WhatCablePlugins

struct ConnectionPersistenceTests {
    @Test func restartRestoresConfirmedNameButChangedDeviceDoesNot() throws {
        let id = UUID()
        var saved = LabRememberedConnections()
        saved.ports["2/1"] = LabRememberedConnection(profileID: id, identity: "display:left")
        let restarted = try LabRememberedConnections.decode(JSONEncoder().encode(saved))
        #expect(restarted.profile(for: "2/1", identity: "display:left", validIDs: [id]) == id)
        #expect(restarted.profile(for: "2/1", identity: "display:replacement", validIDs: [id]) == nil)
        #expect(restarted.profile(for: "2/2", identity: "display:left", validIDs: [id]) == nil)
        #expect(restarted.profile(for: "2/1", identity: nil, validIDs: [id]) == nil)
        #expect(restarted.profile(for: "2/1", identity: "display:left", validIDs: []) == nil)
    }
    @Test func corruptOrFutureAssociationDoesNotOverwriteExistingStore() throws {
        #expect(throws: (any Error).self) { try LabRememberedConnections.decode(Data("broken".utf8)) }
        var saved = LabRememberedConnections(); saved.version = 2
        #expect(throws: (any Error).self) { try LabRememberedConnections.decode(JSONEncoder().encode(saved)) }
    }

    @MainActor @Test func applicationReloadKeepsAssociationAndProtectsDamagedFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let first = LabModel(storageDirectory: directory)
        first.rememberedConnections.ports["2/4"] = LabRememberedConnection(profileID: id, identity: "emarker:drive")
        first.persistConnectionLabels()
        let second = LabModel(storageDirectory: directory)
        #expect(second.rememberedConnections.profile(for: "2/4", identity: "emarker:drive", validIDs: [id]) == id)
        let url = directory.appendingPathComponent("connection-labels-v1.json")
        let corrupt = Data("damaged existing preference".utf8)
        try corrupt.write(to: url)
        let damaged = LabModel(storageDirectory: directory)
        #expect(!damaged.rememberedConnectionsWritable)
        damaged.persistConnectionLabels()
        #expect(try Data(contentsOf: url) == corrupt)
    }
}
