// Independent MIT-licensed extensions. No proprietary Pro implementation is used.
import Foundation
import CryptoKit
import WhatCableCore

struct NamedCable: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var fingerprint: String?
    var length: String = ""
    var purchaseURL: String = ""
    var ratedSpecs: String = ""
    var notes: String = ""
    var photoFilename: String?
    var connectionTitle: String = ""
    var connectorType: String = ""
    var maximumCapability: String = ""
    var widgetCableDescription: String? {
        let kind = connectorType.trimmingCharacters(in: .whitespacesAndNewlines)
        let maximum = maximumCapability.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kind.isEmpty else { return nil }
        return maximum.isEmpty ? "\(kind)（手动）" : "\(kind)（\(maximum)，手动）"
    }

    init(id: UUID = UUID(), name: String, fingerprint: String? = nil, length: String = "",
         purchaseURL: String = "", ratedSpecs: String = "", notes: String = "", photoFilename: String? = nil) {
        self.id = id; self.name = name; self.fingerprint = fingerprint
        self.length = length; self.purchaseURL = purchaseURL; self.ratedSpecs = ratedSpecs
        self.notes = notes; self.photoFilename = photoFilename
    }

    private enum CodingKeys: String, CodingKey { case id, name, fingerprint, length, purchaseURL, ratedSpecs, notes, photoFilename, connectionTitle, connectorType, maximumCapability }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        fingerprint = try c.decodeIfPresent(String.self, forKey: .fingerprint)
        length = try c.decodeIfPresent(String.self, forKey: .length) ?? ""
        purchaseURL = try c.decodeIfPresent(String.self, forKey: .purchaseURL) ?? ""
        ratedSpecs = try c.decodeIfPresent(String.self, forKey: .ratedSpecs) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        photoFilename = try c.decodeIfPresent(String.self, forKey: .photoFilename)
        connectionTitle = try c.decodeIfPresent(String.self, forKey: .connectionTitle) ?? ""
        connectorType = try c.decodeIfPresent(String.self, forKey: .connectorType) ?? ""
        maximumCapability = try c.decodeIfPresent(String.self, forKey: .maximumCapability) ?? ""
    }
}

/// An e-marker fingerprint identifies a design, not necessarily a physical cable.
enum LabCableIdentity {
    static func fingerprint(_ cable: USBPDSOP?) -> String? {
        guard let cable else { return nil }
        let material = ([String(cable.vendorID), String(cable.productID), String(cable.bcdDevice)]
            + cable.vdos.map(String.init)).joined(separator: ":")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func sessionToken(_ context: CableSnapshotContext.PortContext) -> String? {
        let p = context.port
        guard p.connectionActive == true else { return nil }
        // A late e-marker response is not a second physical connection.
        return [String(p.id), String(p.connectionCount ?? -1), String(p.plugEventCount ?? -1)].joined(separator: ":")
    }
}

struct LabBindings {
    private(set) var tokens: [String: String] = [:]
    private(set) var assignments: [String: UUID] = [:]

    mutating func update(_ current: [String: String]) {
        assignments = assignments.filter { key, _ in
            current[key] != nil && current[key] == tokens[key]
        }
        tokens = current
    }

    mutating func assign(_ cable: UUID?, to port: String) {
        guard tokens[port] != nil else { return }
        assignments[port] = cable
    }
}

struct LabPoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let watts: Double
    let series: String
    let segment: Int
}

/// Only actual SMC readings are plotted as measured per-port power.
/// Negotiated maxima and potentially stale PowerOutDetails are shown as text.
struct LabHistory {
    private(set) var points: [LabPoint] = []
    private var segments: [String: Int] = [:]
    private var lastTimes: [String: Date] = [:]
    private var lastSystemSource: Bool?
    let retention: TimeInterval

    init(retention: TimeInterval = 600) { self.retention = retention }

    mutating func append(_ snapshot: PowerMonitorSnapshot) {
        let now = snapshot.timestamp
        let switched = lastSystemSource != nil && lastSystemSource != snapshot.onBattery
        lastSystemSource = snapshot.onBattery
        add("system", watts: Double(snapshot.activePowerMW) / 1000, at: now, breakLine: switched)
        let samples = snapshot.portSamples.droppingStaleContracted(externalPowerAbsent: snapshot.externalPowerAbsent)
        for sample in samples where sample.isSMCMeasured && !sample.portKey.isEmpty {
            add(sample.portKey, watts: Double(sample.watts) / 1000, at: now)
        }
        points.removeAll { now.timeIntervalSince($0.timestamp) > retention }
        // Bound memory even if a driver supplies an unusual timestamp cadence.
        if points.count > 12000 { points.removeFirst(points.count - 12000) }
    }

    mutating func breakSeries(_ series: String) {
        segments[series, default: 0] += 1
        lastTimes.removeValue(forKey: series)
    }

    private mutating func add(_ series: String, watts: Double, at time: Date, breakLine: Bool = false) {
        guard watts.isFinite, watts >= 0 else { return }
        if breakLine || lastTimes[series].map({ time.timeIntervalSince($0) > 3 }) == true {
            segments[series, default: 0] += 1
        }
        if lastTimes[series] == time { return }
        lastTimes[series] = time
        points.append(LabPoint(timestamp: time, watts: watts, series: series, segment: segments[series, default: 0]))
    }
}

enum LabText {
    static func watts(_ value: Int) -> String { String(format: "%.2f W", Double(value) / 1000) }

    /// USB device strings are untrusted terminal input: strip all controls.
    static func terminal(_ value: String) -> String {
        String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
    }

    static func resistance(_ estimate: CableResistanceEstimate?) -> String {
        guard let e = estimate else { return "暂无可估算的充电路径" }
        let state: String
        switch e.status {
        case .stable: state = String(format: "%.1f mΩ", e.milliohms)
        case .insufficient: state = "样本不足"
        case .converging: state = "等待负载变化 / 收敛"
        case .unreliable: state = "数据不可靠，暂不报告阻值"
        }
        return "\(state) · \(e.sampleCount) 个样本 · ΔI \(e.currentSpanMilliamps) mA · R² \(String(format: "%.2f", e.rSquared))"
    }
}

/// Last confirmed label for a physical port and its observable connection.
/// This is a display preference, not proof of an individual cable's identity.
struct LabRememberedConnection: Codable, Equatable {
    var profileID: UUID
    var identity: String
}
struct LabRememberedConnections: Codable {
    var version = 1
    var ports: [String: LabRememberedConnection] = [:]
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 1_000_000 else { throw CocoaError(.fileReadTooLarge) }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1, value.ports.count <= 64,
              value.ports.allSatisfy({ $0.key.count <= 120 && $0.value.identity.count <= 2048 })
        else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }
    func profile(for port: String, identity: String?, validIDs: Set<UUID>) -> UUID? {
        guard let identity, let saved = ports[port], saved.identity == identity,
              validIDs.contains(saved.profileID) else { return nil }
        return saved.profileID
    }
}
