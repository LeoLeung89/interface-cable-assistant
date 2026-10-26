import Foundation

struct LabDisplayMode: Codable, Equatable {
    var width: Int
    var height: Int
    var hz: Double
    var label: String { "\(width) × \(height) @ \(String(format: "%.1f", hz)) Hz" }
    func isBelow(_ baseline: Self) -> Bool {
        width * height < baseline.width * baseline.height || (width * height == baseline.width * baseline.height && hz + 1 < baseline.hz)
    }
}

struct LabDisplayReading: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var mode: LabDisplayMode
}

struct LabObservation {
    var port: String
    var token: String
    var fingerprint: String?
    var linkGbps: Double?
    var displays: [LabDisplayReading] = []
}

struct LabSession: Codable, Identifiable {
    var id = UUID()
    var port: String
    var token: String
    var fingerprint: String?
    var cableID: UUID?
    var started: Date
    var lastSeen: Date
    var ended: Date?
    var endReason: String?
    var latestGbps: Double?
    var bestGbps: Double?
    var peakWatts: Double = 0
    var measuredSamples: Int = 0
    var energyWh: Double = 0
    var measuredSeconds: Double = 0
    var duration: TimeInterval { max(0, (ended ?? lastSeen).timeIntervalSince(started)) }
}

struct LabEvent: Codable, Identifiable {
    var id = UUID()
    var time: Date
    var kind: String
    var port: String
    var title: String
    var detail: String
    var warning: Bool = false
}

struct LabPowerBucket: Codable, Identifiable {
    var hour: Date
    var series: String
    var count: Int = 0
    var sumWatts: Double = 0
    var peakWatts: Double = 0
    var energyWh: Double = 0
    var measuredSeconds: Double = 0
    var id: String { "\(hour.timeIntervalSince1970)|\(series)" }
    var averageWatts: Double { measuredSeconds > 0 ? energyWh * 3600 / measuredSeconds : sumWatts / Double(max(1, count)) }
}

struct LabComparison: Codable, Identifiable {
    var id = UUID()
    var time: Date
    var title: String
    var port: String
    var cableID: UUID?
    var cableName: String?
    var fingerprint: String?
    var linkGbps: Double?
    var charging: String
    var dataLink: String
    var displays: [String]
    var measuredPortWatts: Double?
    var systemWatts: Double?
    var context: String
}

struct LabArchive: Codable {
    var version = 1
    var recording = true
    var notifications = false
    var retentionDays = 90
    var portLabels: [String: String] = [:]
    var sessions: [LabSession] = []
    var events: [LabEvent] = []
    var buckets: [LabPowerBucket] = []
    var comparisons: [LabComparison] = []
    var displayBaselines: [String: LabDisplayReading] = [:]

    mutating func prune(at now: Date) {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400)
        sessions.removeAll { ($0.ended ?? $0.lastSeen) < cutoff }
        events.removeAll { $0.time < cutoff }
        buckets.removeAll { $0.hour.addingTimeInterval(3600) < cutoff }
        comparisons.removeAll { $0.time < cutoff }
        if sessions.count > 10000 {
            let open = sessions.filter { $0.ended == nil }
            sessions = (Array(sessions.filter { $0.ended != nil }.suffix(max(0, 10000 - open.count))) + open)
                .sorted { $0.started < $1.started }
        }
        events = Array(events.suffix(10000))
        buckets = Array(buckets.suffix(25000)); comparisons = Array(comparisons.suffix(500))
    }
}

/// Pure recording state: no IOKit, UI, networking or disk IO. Tests replay
/// observations to prove reconnect/debounce and energy attribution rules.
struct LabArchiveEngine {
    var archive: LabArchive
    private var attached: [String: UUID] = [:]
    private var reconnects: [String: [Date]] = [:]
    private var speeds: [String: (Double, Int)] = [:]
    private var displayCandidates: [String: (LabDisplayReading, Int)] = [:]
    private var displayLast: [String: LabDisplayReading] = [:]
    private var lastWarnings: [String: Date] = [:]
    private var previousPower: [String: (Date, Double)] = [:]
    private var bucketIndices: [String: Int] = [:]

    init(archive: LabArchive = LabArchive()) {
        self.archive = archive
        // An application restart is not evidence of a hardware disconnect.
        for i in self.archive.sessions.indices where self.archive.sessions[i].ended == nil {
            self.archive.sessions[i].ended = self.archive.sessions[i].lastSeen
            self.archive.sessions[i].endReason = "上次记录结束（非已确认断开）"
        }
    }

    mutating func pause(at time: Date) {
        for id in attached.values {
            if let i = archive.sessions.firstIndex(where: { $0.id == id }) {
                archive.sessions[i].ended = min(time, archive.sessions[i].lastSeen)
                archive.sessions[i].endReason = "记录已暂停或应用退出"
            }
        }
        attached = [:]; previousPower = [:]; speeds = [:]; displayCandidates = [:]; displayLast = [:]; reconnects = [:]
    }

    mutating func ingest(_ observations: [LabObservation], standaloneDisplays: [LabDisplayReading] = [], at now: Date) -> [LabEvent] {
        guard archive.recording else { return [] }
        let before = archive.events.count
        let allDisplays = observations.flatMap(\.displays) + standaloneDisplays
        let ambiguous = Set(Dictionary(grouping: allDisplays, by: \.id).filter { $0.value.count > 1 }.keys)
        let visibleDisplays = Set(allDisplays.map(\.id)).subtracting(ambiguous)
        displayCandidates = displayCandidates.filter { visibleDisplays.contains($0.key) }
        let present = Set(observations.map(\.port))
        for port in Array(attached.keys) where !present.contains(port) { end(port, at: now, reason: "检测到断开") }
        for observation in observations {
            let port = observation.port
            if let id = attached[port], let i = archive.sessions.firstIndex(where: { $0.id == id }) {
                let old = archive.sessions[i]
                let changedFingerprint = old.fingerprint != nil && observation.fingerprint != nil && old.fingerprint != observation.fingerprint
                if old.token != observation.token || changedFingerprint { end(port, at: now, reason: "检测到新的连接") }
            }
            if attached[port] == nil {
                let session = LabSession(port: port, token: observation.token, fingerprint: observation.fingerprint,
                    started: now, lastSeen: now, latestGbps: observation.linkGbps, bestGbps: observation.linkGbps)
                archive.sessions.append(session); attached[port] = session.id
                event("connect", port, "连接已记录", "从软件观察到此连接开始计时；不是线缆出厂或首次使用时间。", at: now)
                reconnects[port, default: []].removeAll { now.timeIntervalSince($0) > 60 }
                reconnects[port, default: []].append(now)
                if reconnects[port, default: []].count >= 3 {
                    warn("reconnect", port, "短时间反复连接", "60 秒内观察到至少 3 次连接，请检查线缆、接头或扩展坞。", at: now)
                }
            }
            guard let id = attached[port], let i = archive.sessions.firstIndex(where: { $0.id == id }) else { continue }
            archive.sessions[i].lastSeen = now
            if observation.fingerprint != nil { archive.sessions[i].fingerprint = observation.fingerprint }
            if let speed = observation.linkGbps, speed > 0, speed.isFinite {
                let candidate = speeds[port]
                let count = candidate?.0 == speed ? (candidate?.1 ?? 0) + 1 : 1
                speeds[port] = (speed, count)
                if count >= 3 {
                    if let previous = archive.sessions[i].latestGbps, speed + 0.1 < previous {
                        warn("speed", port, "数据链路速率下降", "\(previous) → \(speed) Gbps；这是协商链路速率，不是文件传输测速。", at: now)
                    }
                    archive.sessions[i].latestGbps = speed
                    archive.sessions[i].bestGbps = max(archive.sessions[i].bestGbps ?? speed, speed)
                }
            }
            for display in observation.displays where !ambiguous.contains(display.id) { ingestDisplay(display, port: port, at: now) }
        }
        for display in standaloneDisplays where !ambiguous.contains(display.id) { ingestDisplay(display, port: "native-display", at: now) }
        return Array(archive.events.dropFirst(before))
    }

    mutating func assign(_ cableID: UUID?, port: String) {
        if let id = attached[port], let i = archive.sessions.firstIndex(where: { $0.id == id }) { archive.sessions[i].cableID = cableID }
    }

    private mutating func end(_ port: String, at now: Date, reason: String) {
        if let id = attached.removeValue(forKey: port), let i = archive.sessions.firstIndex(where: { $0.id == id }) {
            archive.sessions[i].ended = now
            archive.sessions[i].endReason = reason
        }
        previousPower.removeValue(forKey: "port:\(port)")
        speeds.removeValue(forKey: port)
        event("disconnect", port, "连接结束", reason, at: now)
    }

    private mutating func ingestDisplay(_ display: LabDisplayReading, port: String, at now: Date) {
        guard display.mode.width > 0, display.mode.height > 0, display.mode.hz > 0 else { return }
        let old = displayCandidates[display.id]
        let count = old?.0.mode == display.mode ? (old?.1 ?? 0) + 1 : 1
        displayCandidates[display.id] = (display, count)
        guard count == 3 else { return }
        if archive.displayBaselines[display.id] == nil { archive.displayBaselines[display.id] = display }
        if let previous = displayLast[display.id], previous.mode != display.mode {
            event("display", port, "显示模式变化：\(display.name)", "\(previous.mode.label) → \(display.mode.label)", at: now)
        }
        if let baseline = archive.displayBaselines[display.id], display.mode.isBelow(baseline.mode) {
            warn("display-low:\(display.id)", port, "显示模式低于已记住的基线", "\(display.name)：\(display.mode.label)；基线 \(baseline.mode.label)。请确认是否为主动调整。", at: now)
        }
        displayLast[display.id] = display
    }

    private mutating func event(_ kind: String, _ port: String, _ title: String, _ detail: String, at time: Date) {
        archive.events.append(LabEvent(time: time, kind: kind, port: port, title: title, detail: detail))
    }

    private mutating func warn(_ kind: String, _ port: String, _ title: String, _ detail: String, at time: Date) {
        let key = "\(kind)|\(port)"
        guard lastWarnings[key].map({ time.timeIntervalSince($0) >= 120 }) ?? true else { return }
        lastWarnings[key] = time
        archive.events.append(LabEvent(time: time, kind: kind, port: port, title: title, detail: detail, warning: true))
    }

    mutating func recordPower(series: String, watts: Double, at time: Date) {
        guard archive.recording, watts.isFinite, watts >= 0 else { return }
        let hour = Self.hour(time)
        let i = index(hour: hour, series: series)
        archive.buckets[i].count += 1
        archive.buckets[i].sumWatts += watts
        archive.buckets[i].peakWatts = max(archive.buckets[i].peakWatts, watts)
        if series.hasPrefix("port:"), let id = attached[String(series.dropFirst(5))],
           let session = archive.sessions.firstIndex(where: { $0.id == id }) {
            archive.sessions[session].peakWatts = max(archive.sessions[session].peakWatts, watts)
            archive.sessions[session].measuredSamples += 1
        }
        defer { previousPower[series] = (time, watts) }
        guard let (previousTime, previousWatts) = previousPower[series] else { return }
        let dt = time.timeIntervalSince(previousTime)
        // Never integrate sleep, missing observations, or a source transition.
        guard dt > 0, dt <= 35 else { return }
        var cursor = previousTime
        while cursor < time {
            let end = min(Self.hour(cursor).addingTimeInterval(3600), time)
            let a = previousWatts + (watts - previousWatts) * cursor.timeIntervalSince(previousTime) / dt
            let b = previousWatts + (watts - previousWatts) * end.timeIntervalSince(previousTime) / dt
            let seconds = end.timeIntervalSince(cursor)
            let wh = (a + b) / 2 * seconds / 3600
            let bucket = index(hour: Self.hour(cursor), series: series)
            archive.buckets[bucket].energyWh += wh
            archive.buckets[bucket].measuredSeconds += seconds
            cursor = end
        }
        if series.hasPrefix("port:"), let id = attached[String(series.dropFirst(5))],
           let session = archive.sessions.firstIndex(where: { $0.id == id }), previousTime >= archive.sessions[session].started {
            archive.sessions[session].peakWatts = max(archive.sessions[session].peakWatts, watts, previousWatts)
            archive.sessions[session].energyWh += (previousWatts + watts) / 2 * dt / 3600
            archive.sessions[session].measuredSeconds += dt
        }
    }

    mutating func invalidatePower() { previousPower = [:] }
    mutating func retainPowerSeries(_ present: Set<String>) { previousPower = previousPower.filter { present.contains($0.key) } }
    mutating func prune(at time: Date) { archive.prune(at: time); bucketIndices = [:] }
    private static func hour(_ time: Date) -> Date { Date(timeIntervalSince1970: floor(time.timeIntervalSince1970 / 3600) * 3600) }
    private mutating func index(hour: Date, series: String) -> Int {
        let key = "\(hour.timeIntervalSince1970)|\(series)"
        if let i = bucketIndices[key], i < archive.buckets.count, archive.buckets[i].id == key { return i }
        if let i = archive.buckets.firstIndex(where: { $0.id == key }) { bucketIndices[key] = i; return i }
        archive.buckets.append(LabPowerBucket(hour: hour, series: series))
        let i = archive.buckets.count - 1; bucketIndices[key] = i; return i
    }
}

struct LabArchiveStore {
    let url: URL
    func load() throws -> LabArchive {
        guard FileManager.default.fileExists(atPath: url.path) else { return LabArchive() }
        let value = try JSONDecoder().decode(LabArchive.self, from: Data(contentsOf: url))
        guard value.version == 1, (1...365).contains(value.retentionDays) else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }
    func save(_ archive: LabArchive) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(archive).write(to: url, options: .atomic)
    }
}
