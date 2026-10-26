import SwiftUI
import WidgetKit
import Charts

struct LabWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: LabWidgetSnapshot?
    var preview = false
    static var example: Self {
        Self(date: Date(), snapshot: LabWidgetSnapshot(timestamp: Date(), systemWatts: 42.5, onBattery: false,
            ports: [LabWidgetPort(id: "2/1", title: "背面左侧", cableName: "显示器线", connected: true,
                protocols: "DisplayPort", measuredWatts: 0.12),
                LabWidgetPort(id: "2/4", title: "扩展坞", cableName: "桌面数据线", connected: true,
                    protocols: "Thunderbolt", measuredWatts: 5.8)],
            trend: (0..<12).map { LabWidgetPowerPoint(time: Date().addingTimeInterval(Double($0 - 12) * 60),
                watts: 40 + Double($0 % 4), source: "input") }), preview: true)
    }
}

struct LabWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> LabWidgetEntry { .example }
    func getSnapshot(in context: Context, completion: @escaping (LabWidgetEntry) -> Void) {
        completion(context.isPreview ? .example : entry())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<LabWidgetEntry>) -> Void) {
        let current = entry()
        var entries = [current]
        if let snapshot = current.snapshot {
            for seconds in [121.0, 901.0] {
                let deadline = snapshot.timestamp.addingTimeInterval(seconds)
                if deadline > current.date { entries.append(LabWidgetEntry(date: deadline, snapshot: snapshot)) }
            }
        }
        // Request, never promise, a refresh. macOS owns the actual budget.
        completion(Timeline(entries: entries, policy: .after(Date().addingTimeInterval(60))))
    }
    private func entry() -> LabWidgetEntry {
        let url = LabWidgetSnapshot.widgetCacheURL
        // Creating our own directory tells the host that the sandbox container
        // is ready. It contains no grant to another application's data.
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let snapshot = (try? Data(contentsOf: url)).flatMap { try? LabWidgetSnapshot.decode($0) }
        return LabWidgetEntry(date: Date(), snapshot: snapshot)
    }
}

@main
struct LabDesktopWidgets: WidgetBundle {
    var body: some Widget {
        LabConnectionWidget()
        LabPowerWidget()
    }
}

struct LabConnectionWidget: Widget {
    let kind = LabWidgetSnapshot.connectionKind
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LabWidgetProvider()) { entry in
            LabConnectionView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("端口与线缆")
        .description("查看端口连接、已确认的线缆名称和最近一次功率。刷新频率由 macOS 控制。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct LabPowerWidget: Widget {
    let kind = LabWidgetSnapshot.powerKind
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LabWidgetProvider()) { entry in
            LabPowerView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("功率概览")
        .description("显示最近的系统输入或电池放电功率与趋势。主程序运行时提供读数。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct LabConnectionView: View {
    let entry: LabWidgetEntry
    @Environment(\.widgetFamily) private var family
    private var maximum: Int { family == .systemSmall ? 1 : family == .systemMedium ? 2 : 5 }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabWidgetHeader(title: "连接概览", entry: entry)
            if let snapshot = entry.snapshot {
                let active = snapshot.ports.filter { $0.connected }
                let ports = active.isEmpty ? snapshot.ports : active
                if snapshot.freshness(at: entry.date) == .expired {
                    Label("上次记录已过期", systemImage: "clock.badge.exclamationmark").font(.caption).foregroundStyle(.orange)
                }
                if ports.isEmpty { Text("尚未检测到端口").font(.caption).foregroundStyle(.secondary) }
                ForEach(ports.prefix(maximum)) { port in
                    HStack(alignment: .top, spacing: 7) {
                        RoundedRectangle(cornerRadius: 2).fill(port.connected ? .teal : .gray).frame(width: 3)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Image(systemName: port.iconName ?? "cable.connector").font(.system(size: 16)).foregroundStyle(.teal)
                                Text(port.cableName ?? port.statusTitle ?? port.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                                Spacer(minLength: 0)
                                if let speed = port.speedBadge { Text(speed).font(.system(size: 14, weight: .semibold)).foregroundStyle(.blue) }
                                if let watts = port.chargerWatts { Text("\(watts)W").font(.system(size: 14, weight: .semibold)).foregroundStyle(.orange) }
                                if let count = port.deviceCount, count > 0 {
                                    Label("\(count)", systemImage: "externaldrive").font(.system(size: 13)).foregroundStyle(.secondary)
                                }
                            }
                            if let cable = port.cableDescription {
                                Text(cable).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            if (family == .systemLarge && ports.count <= 4) || port.cableDescription == nil {
                                Text(port.detail ?? (port.connected ? port.protocols : "未连接"))
                                    .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                LabWidgetTimestamp(snapshot: snapshot, preview: entry.preview)
            } else { LabWidgetEmpty() }
        }.widgetURL(URL(string: "whatcable-lab://diagnostics"))
    }
}

struct LabPowerView: View {
    let entry: LabWidgetEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabWidgetHeader(title: entry.snapshot?.onBattery == true ? "电池放电" : "系统输入", entry: entry)
            if let snapshot = entry.snapshot {
                let expired = snapshot.freshness(at: entry.date) == .expired
                if let watts = snapshot.systemWatts, !expired {
                    Text(String(format: "%.2f W", watts)).font(.system(size: family == .systemSmall ? 29 : 38, weight: .semibold, design: .rounded)).monospacedDigit()
                } else { Text(expired ? "读数已过期" : "暂无功率读数").font(.headline).foregroundStyle(.secondary) }
                if !expired && snapshot.trend.count > 1 {
                    Chart(snapshot.trend) { point in
                        LineMark(x: .value("时间", point.time), y: .value("功率 W", point.watts),
                            series: .value("连续区段", point.segment)).foregroundStyle(.teal)
                    }.chartXAxis(.hidden).chartYAxis(.hidden).frame(maxHeight: family == .systemLarge ? 150 : 65)
                }
                if family != .systemSmall { Text("主板侧读数，非插座电量").font(.caption2).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                LabWidgetTimestamp(snapshot: snapshot, preview: entry.preview)
            } else { LabWidgetEmpty() }
        }.widgetURL(URL(string: "whatcable-lab://diagnostics"))
    }
}

struct LabWidgetHeader: View {
    let title: String
    let entry: LabWidgetEntry
    var body: some View {
        HStack {
            Label(title, systemImage: "cable.connector").font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 0)
            Text(entry.preview ? "示例" : "接口与线缆").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
        }
    }
}

struct LabWidgetTimestamp: View {
    let snapshot: LabWidgetSnapshot
    let preview: Bool
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "clock")
            Text(preview ? "示例数据" : "截至")
            if !preview { Text(snapshot.timestamp, style: .time) }
        }.font(.system(size: 12)).foregroundStyle(.secondary)
    }
}

struct LabWidgetEmpty: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("打开 接口线缆助手").font(.headline)
            Text("等待主程序同步。首次添加后请保持应用运行片刻。").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.padding(.top, 8)
    }
}
