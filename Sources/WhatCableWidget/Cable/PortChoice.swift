import AppIntents
import WhatCableCore

struct PortChoice: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Port")
    static var defaultQuery = PortChoiceQuery()

    var id: String
    var portName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(portName)")
    }
}

struct PortChoiceQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [PortChoice] {
        let all = readSnapshot()?.ports ?? []
        let set = Set(identifiers)
        return all.filter { set.contains(String($0.id)) }
            .map { PortChoice(id: String($0.id), portName: $0.portName) }
    }

    func suggestedEntities() async throws -> [PortChoice] {
        let ports = readSnapshot()?.ports ?? []
        return ports.filter { $0.status != .empty }
            .map { PortChoice(id: String($0.id), portName: $0.portName) }
    }

    func defaultResult() async -> PortChoice? { nil }

    private func readSnapshot() -> WidgetSnapshot? {
        guard let url = WidgetSnapshot.sharedFileURL,
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else {
            return nil
        }
        let age = Date().timeIntervalSince(snapshot.timestamp)
        guard age <= 5 * 60 else { return nil }
        return snapshot
    }
}
