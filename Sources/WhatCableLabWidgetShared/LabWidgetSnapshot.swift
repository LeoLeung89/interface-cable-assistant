import Foundation

public struct LabWidgetPort: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var cableName: String?
    public var connected: Bool
    public var protocols: String
    public var measuredWatts: Double?
    public var cableDescription: String?
    public var statusTitle: String?
    public var detail: String?
    public var speedBadge: String?
    public var chargerWatts: Int?
    public var deviceCount: Int?
    public var iconName: String?
    public init(id: String, title: String, cableName: String?, connected: Bool, protocols: String, measuredWatts: Double?, statusTitle: String? = nil, detail: String? = nil,
        speedBadge: String? = nil, chargerWatts: Int? = nil, deviceCount: Int? = nil, iconName: String? = nil, cableDescription: String? = nil) {
        self.id = id; self.title = title; self.cableName = cableName; self.connected = connected
        self.protocols = protocols; self.measuredWatts = measuredWatts
        self.cableDescription = cableDescription
        self.statusTitle = statusTitle; self.detail = detail; self.speedBadge = speedBadge
        self.chargerWatts = chargerWatts; self.deviceCount = deviceCount; self.iconName = iconName
    }
}

public struct LabWidgetPowerPoint: Codable, Identifiable, Equatable, Sendable {
    public var time: Date
    public var watts: Double
    public var source: String
    public var segment: Int
    public var id: Date { time }
    public init(time: Date, watts: Double, source: String, segment: Int = 0) {
        self.time = time; self.watts = watts; self.source = source; self.segment = segment
    }
}

public struct LabWidgetSnapshot: Codable, Equatable, Sendable {
    public static let extensionID = "local.leo.WhatCableLab.widget"
    public static let connectionKind = "local.leo.WhatCableLab.connection-widget"
    public static let powerKind = "local.leo.WhatCableLab.power-widget"
    public var version = 1
    public var timestamp: Date
    public var systemWatts: Double?
    public var onBattery: Bool
    public var ports: [LabWidgetPort]
    public var trend: [LabWidgetPowerPoint]
    public init(timestamp: Date, systemWatts: Double?, onBattery: Bool, ports: [LabWidgetPort], trend: [LabWidgetPowerPoint]) {
        self.timestamp = timestamp; self.systemWatts = systemWatts; self.onBattery = onBattery
        self.ports = ports; self.trend = trend
    }
    public enum Freshness: Equatable { case recent, delayed, expired }
    public func freshness(at now: Date) -> Freshness {
        let age = now.timeIntervalSince(timestamp)
        if age < -60 || age > 900 { return .expired }
        return age <= 120 ? .recent : .delayed
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 1_000_000 else { throw CocoaError(.fileReadTooLarge) }
        let snapshot = try JSONDecoder().decode(Self.self, from: data)
        guard snapshot.version == 1, snapshot.ports.count <= 16, snapshot.trend.count <= 60,
              snapshot.systemWatts.map({ $0.isFinite && $0 >= 0 }) ?? true,
              snapshot.ports.allSatisfy({ $0.id.count <= 100 && $0.title.count <= 120 && ($0.cableName?.count ?? 0) <= 120
                  && ($0.cableDescription?.count ?? 0) <= 200 && ($0.detail?.count ?? 0) <= 1000 && ($0.statusTitle?.count ?? 0) <= 200
                  && ($0.speedBadge?.count ?? 0) <= 100 && ($0.deviceCount ?? 0) >= 0 && ($0.deviceCount ?? 0) <= 1000
                  && $0.protocols.count <= 200 && ($0.measuredWatts.map { $0.isFinite && $0 >= 0 } ?? true) }),
              snapshot.trend.allSatisfy({ $0.watts.isFinite && $0.watts >= 0 && ["input", "battery"].contains($0.source) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return snapshot
    }
    /// Inside the sandboxed extension, Application Support is its own container.
    public static var widgetCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhatCableLab/widget-v1.json")
    }
    /// The non-sandboxed host may deliver a snapshot to its OWN extension's
    /// system-created container. Never create or impersonate an App Group.
    public static func hostCacheURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let data = home.appendingPathComponent("Library/Containers/\(extensionID)/Data", isDirectory: true)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: data.path, isDirectory: &directory), directory.boolValue else { return nil }
        return data.appendingPathComponent("Library/Application Support/WhatCableLab/widget-v1.json")
    }
}
