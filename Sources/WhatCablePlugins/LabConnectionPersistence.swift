import Foundation
import WhatCableCore

@MainActor
extension LabModel {
    func connectionIdentity(_ pc: CableSnapshotContext.PortContext) -> String? {
        let displays = pc.portDisplayPorts.compactMap(displayReading).map(\.id).sorted()
        if !displays.isEmpty { return "display:" + displays.joined(separator: ";") }
        if let name = pc.portAccessory?.displayName, !name.isEmpty { return "accessory:" + name }
        if let fp = LabCableIdentity.fingerprint(pc.cableEmarker) { return "emarker:" + fp }
        return nil
    }

    func persistConnectionLabels() {
        guard rememberedConnectionsWritable else { return }
        do {
            let data = try JSONEncoder().encode(rememberedConnections)
            _ = try LabRememberedConnections.decode(data)
            try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            try data.write(to: storageDirectory.appendingPathComponent("connection-labels-v1.json"), options: .atomic)
        } catch { self.error = "连接名称关联保存失败：\(error.localizedDescription)" }
    }

    func rememberConnection(_ id: UUID?, port: String) {
        guard rememberedConnectionsWritable else { return }
        if let id {
            guard let pc = ports.first(where: { $0.port.portKey == port }),
                  let identity = connectionIdentity(pc) else { return }
            rememberedConnections.ports[port] = LabRememberedConnection(profileID: id, identity: identity)
        } else { rememberedConnections.ports.removeValue(forKey: port) }
        persistConnectionLabels()
    }

    func restoreConnectionLabels() {
        guard recordsArchive else { return }
        let validIDs = Set(names.map(\.id))
        var changed = false
        for pc in ports {
            guard let key = pc.port.portKey, bindings.tokens[key] != nil,
                  bindings.assignments[key] == nil, let identity = connectionIdentity(pc) else { continue }
            if let id = rememberedConnections.profile(for: key, identity: identity, validIDs: validIDs) {
                restoreBinding(id, port: key)
                continue
            }
            // Migrate only the last explicitly assigned profile on this port,
            // and only with matching observable evidence. Never pick the first
            // of several same-model cable profiles.
            guard rememberedConnectionsWritable, rememberedConnections.ports[key] == nil,
                  let previous = archive.sessions.filter({ $0.port == key && $0.cableID != nil })
                    .max(by: { $0.lastSeen < $1.lastSeen }),
                  let id = previous.cableID, let profile = names.first(where: { $0.id == id }) else { continue }
            let fp = LabCableIdentity.fingerprint(pc.cableEmarker)
            let displayNames = pc.portDisplayPorts.compactMap { $0.monitor?.productName }
            let fingerprintMatches = fp != nil && fp == previous.fingerprint
            let displayMatches = displayNames.contains(profile.connectionTitle) || displayNames.contains(profile.name)
            guard fingerprintMatches || displayMatches else { continue }
            rememberedConnections.ports[key] = LabRememberedConnection(profileID: id, identity: identity)
            restoreBinding(id, port: key)
            changed = true
        }
        if changed { persistConnectionLabels() }
    }
}
