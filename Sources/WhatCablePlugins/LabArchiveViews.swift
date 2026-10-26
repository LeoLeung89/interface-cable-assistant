import SwiftUI
import AppKit
import Charts
import WhatCableCore

@MainActor
enum LabSave {
    static func text(_ value: String, name: String, model: LabModel) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try value.write(to: url, atomically: true, encoding: .utf8) }
        catch { model.error = "导出失败：\(error.localizedDescription)" }
    }
}

struct LabProfileEditor: View {
    @ObservedObject var model: LabModel
    @State var draft: NamedCable
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("线缆档案").font(.title2.bold())
            Form {
                TextField("档案名称", text: $draft.name)
                TextField("连接显示名称，例如 左侧显示器", text: $draft.connectionTitle)
                TextField("线缆类型，例如 USB-C 转 DP / USB-C", text: $draft.connectorType)
                TextField("最大规格，例如 最高 DP 1.4 / 最高 40 Gbps", text: $draft.maximumCapability)
                Text("类型与最大规格由你确认填写；不是当前速率，也不是软件已验证的上限。").font(.caption).foregroundStyle(.secondary)
                TextField("长度，例如 1.5 m", text: $draft.length)
                TextField("标称参数，例如 240 W / 40 Gbps", text: $draft.ratedSpecs)
                TextField("购买链接（可选）", text: $draft.purchaseURL)
                Text("备注").font(.caption)
                TextEditor(text: $draft.notes).frame(height: 110).border(.quaternary)
            }
            HStack(alignment: .top) {
                if let url = model.photoURL(draft.photoFilename), let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 160, height: 120)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Button("选择本地照片…") { if let file = model.importPhoto() { draft.photoFilename = file } }
                    if draft.photoFilename != nil { Button("移除档案中的照片") { draft.photoFilename = nil } }
                    Text("照片缩小后只存本机，不上传。标称参数由你填写，与软件读数分开保留。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("保存档案") {
                    model.saveProfile(draft)
                    if model.names.contains(draft) { dismiss() }
                }.buttonStyle(.borderedProminent)
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.name.count > 80)
            }
        }.padding(24).frame(width: 620)
    }
}

struct LabTimelineView: View {
    @ObservedObject var model: LabModel
    @State private var onlyWarnings = true
    @State private var filter: UUID?
    private var sessions: [LabSession] {
        Array(model.archive.sessions.reversed().filter { filter == nil || $0.cableID == filter }.prefix(300))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("记录与提醒设置") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("启用本机连接历史和功率统计", isOn: Binding(get: { model.archive.recording }, set: model.setRecording))
                        HStack {
                            Picker("保留时间", selection: Binding(get: { model.archive.retentionDays }, set: model.setRetention)) {
                                Text("7 天").tag(7); Text("30 天").tag(30); Text("90 天").tag(90); Text("365 天").tag(365)
                            }.frame(width: 240)
                            Spacer()
                            if model.archive.notifications {
                                Button("关闭系统通知") { model.disableSystemNotifications() }
                            } else { Button("开启系统通知…") { model.requestSystemNotifications() } }
                        }
                        Text("异常默认在下方留痕。系统通知需你授权；速率和显示变化需连续 3 次观测确认，重复提醒至少间隔 2 分钟。退出应用后不记录。缩短保留时间会移除超期历史，不删除线缆档案。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }.disabled(!model.archiveWritable)
                HStack {
                    Text("连接历史").font(.headline)
                    Picker("线缆", selection: $filter) {
                        Text("全部连接").tag(UUID?.none)
                        ForEach(model.names) { Text($0.name).tag(Optional($0.id)) }
                    }.frame(width: 250)
                    Spacer()
                    Button("导出历史 CSV…") { LabSave.text(model.sessionsCSV(), name: "WhatCableLab-sessions.csv", model: model) }
                }
                if sessions.isEmpty { Text("暂无记录。连接发生后自动留痕；手动命名后可按线缆筛选。").foregroundStyle(.secondary) }
                ForEach(sessions) { session in
                    GroupBox {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(model.portLabel(session.port)) · \(model.cableLabel(session.cableID))").font(.headline)
                                Text("\(session.started.formatted()) → \(session.ended?.formatted() ?? "正在连接")")
                                Text("本段记录跨度 \(Int(session.duration)) 秒 · 最佳链路 \(session.bestGbps.map { "\($0) Gbps" } ?? "未知")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 6) {
                                Text(session.endReason ?? "持续观察中").font(.caption)
                                Text(session.measuredSamples > 0 ? String(format: "端口实测峰值 %.2f W · 估算 %.4f Wh", session.peakWatts, session.energyWh) : "无端口实测功率")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                }
                Divider()
                HStack {
                    Text("事件与异常").font(.headline)
                    Spacer()
                    Toggle("只看异常", isOn: $onlyWarnings).toggleStyle(.checkbox)
                }
                let events = Array(model.archive.events.reversed().filter { !onlyWarnings || $0.warning }.prefix(200))
                if events.isEmpty { Text("尚未记录到符合筛选条件的事件。").foregroundStyle(.secondary) }
                ForEach(events) { event in
                    HStack(alignment: .top) {
                        Image(systemName: event.warning ? "exclamationmark.triangle.fill" : "circle.fill")
                            .foregroundStyle(event.warning ? .orange : .secondary)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(event.title).font(.headline)
                            Text(event.detail).font(.callout).foregroundStyle(.secondary)
                            Text("\(event.time.formatted()) · \(model.portLabel(event.port))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }.padding(8)
                }
            }.padding(10)
        }
    }
}

struct LabStatisticsView: View {
    @ObservedObject var model: LabModel
    @State private var series = "system:input"
    @State private var days = 7
    private var buckets: [LabPowerBucket] {
        model.archive.buckets.filter { $0.series == series && $0.hour >= Date().addingTimeInterval(-Double(days) * 86400) }
            .sorted { $0.hour < $1.hour }
    }
    private var seriesKeys: [String] { Array(Set(model.archive.buckets.map(\.series))).sorted() }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Picker("读数", selection: $series) {
                        Text("系统输入").tag("system:input")
                        Text("电池放电").tag("system:battery")
                        ForEach(seriesKeys.filter { $0.hasPrefix("port:") }, id: \.self) { key in
                            Text(model.portLabel(String(key.dropFirst(5)))).tag(key)
                        }
                    }.frame(width: 260)
                    Picker("范围", selection: $days) { Text("24 小时").tag(1); Text("7 天").tag(7); Text("30 天").tag(30); Text("90 天").tag(90) }
                    Spacer()
                    Button("导出长期统计…") { LabSave.text(model.statisticsCSV(), name: "WhatCableLab-hourly-power.csv", model: model) }
                }
                let seconds = buckets.reduce(0) { $0 + $1.measuredSeconds }
                let wh = buckets.reduce(0) { $0 + $1.energyWh }
                let average = seconds > 0 ? wh * 3600 / seconds : 0
                HStack(spacing: 40) {
                    metric("观测期间平均", seconds > 0 ? String(format: "%.2f W", average) : "等待有效区间")
                    metric("观测峰值", String(format: "%.2f W", buckets.map(\.peakWatts).max() ?? 0))
                    metric("观测期间估算电量", String(format: "%.3f Wh", wh))
                    metric("有效覆盖", seconds < 3600 ? String(format: "%.1f 分钟", seconds / 60) : String(format: "%.2f 小时", seconds / 3600))
                }
                if buckets.isEmpty {
                    ContentUnavailableView("还没有长期统计", systemImage: "chart.bar",
                        description: Text("开启历史记录并让应用运行，系统输入和各端口实测值会按小时汇总。"))
                } else {
                    Chart(buckets) { bucket in
                        BarMark(x: .value("小时", bucket.hour, unit: .hour), y: .value("估算 Wh", bucket.energyWh)).foregroundStyle(.teal)
                    }.chartYAxisLabel("Wh").frame(height: 300)
                }
                Text("只积分两次有效读数之间不超过 35 秒的时段；休眠、退出、暂停记录和缺失读数不补算。端口仅统计 SMC 实测值。系统输入是主板侧读数，不能当成插座电量或电费依据。不同端口与系统值不能相加作为整机功耗。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("本地汇总每约 30 秒落盘，正常退出时保存；强制结束进程可能丢失最近一小段记录。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(12)
        }
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.title2.bold()).monospacedDigit() }
    }
}

struct LabCompareView: View {
    @ObservedObject var model: LabModel
    @State private var title = ""
    @State private var first: UUID?
    @State private var second: UUID?
    private var a: LabComparison? { model.archive.comparisons.first { $0.id == first } }
    private var b: LabComparison? { model.archive.comparisons.first { $0.id == second } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("先保持端口、设备和负载一致，分别连接两根线并保存快照，再选 A / B 对照。这里不做写盘测速，也不会自动把差异归因于线材。")
                    .foregroundStyle(.secondary)
                HStack {
                    Picker("端口", selection: $model.selectedPort) {
                        ForEach(model.ports, id: \.port.id) { pc in
                            if let key = pc.port.portKey { Text(model.portLabel(key)).tag(key) }
                        }
                    }.frame(width: 260)
                    TextField("快照名称，例如：线 A / 扩展坞 / 同一负载", text: $title)
                    Button("保存当前连接") {
                        model.captureComparison(title: title)
                        if first == nil { first = model.archive.comparisons.last?.id }
                        else { second = model.archive.comparisons.last?.id }
                        title = ""
                    }.disabled(model.selected?.port.connectionActive != true || !model.archiveWritable)
                }
                HStack {
                    picker("A", selection: $first)
                    picker("B", selection: $second)
                }
                if let a, let b {
                    if a.port != b.port || a.context != b.context {
                        Label("两次端口或设备条件不同，请谨慎比较。", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    HStack(alignment: .top, spacing: 16) { card(a, label: "A"); card(b, label: "B") }
                    Button("导出对比报告…") {
                        LabSave.text(report(a, b), name: "WhatCableLab-comparison.md", model: model)
                    }
                } else { ContentUnavailableView("选择两个快照进行比较", systemImage: "arrow.left.arrow.right") }
            }.padding(10)
        }.onAppear {
            first = first ?? model.archive.comparisons.dropLast().last?.id
            second = second ?? model.archive.comparisons.last?.id
        }
    }
    private func picker(_ label: String, selection: Binding<UUID?>) -> some View {
        Picker(label, selection: selection) {
            Text("选择快照").tag(UUID?.none)
            ForEach(model.archive.comparisons.reversed()) { row in
                Text("\(row.title) · \(row.time.formatted(date: .abbreviated, time: .shortened))").tag(Optional(row.id))
            }
        }
    }
    private func card(_ value: LabComparison, label: String) -> some View {
        GroupBox("\(label) · \(value.title)") {
            VStack(alignment: .leading, spacing: 12) {
                Text(value.time.formatted()).font(.caption).foregroundStyle(.secondary)
                Text("线缆：\(value.cableName ?? "未指定名称")")
                Text("端口：\(model.portLabel(value.port))")
                Text("链路：\(value.linkGbps.map { "\($0) Gbps" } ?? "未知")").font(.headline)
                Text(value.dataLink)
                Text("充电：\(value.charging)")
                Text("端口实测：\(value.measuredPortWatts.map { String(format: "%.2f W", $0) } ?? "无读数")")
                Text("系统功率：\(value.systemWatts.map { String(format: "%.2f W", $0) } ?? "无读数")")
                ForEach(Array(value.displays.enumerated()), id: \.offset) { _, display in Text(display) }
                Text(value.context).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private func report(_ a: LabComparison, _ b: LabComparison) -> String {
        var rows = ["# 接口线缆助手 线缆对比", "", "仅为观测快照；端口、设备或负载不同会影响结果，不代表线缆因果测试。", ""]
        for (label, c) in [("A", a), ("B", b)] {
            rows += ["## \(label)：\(LabReport.escape(c.title))", "", c.time.formatted(),
                "线缆：\(LabReport.escape(c.cableName ?? "未指定"))", "端口：\(LabReport.escape(model.portLabel(c.port)))",
                LabReport.escape(c.dataLink), LabReport.escape(c.charging),
                "端口实测：\(c.measuredPortWatts.map { String(format: "%.2f W", $0) } ?? "无读数")",
                "系统功率：\(c.systemWatts.map { String(format: "%.2f W", $0) } ?? "无读数")"]
            rows += c.displays.map(LabReport.escape)
            rows += [LabReport.escape(c.context), ""]
        }
        return rows.joined(separator: "\n")
    }
}

struct LabTopologyView: View {
    @ObservedObject var model: LabModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label("这台 Mac", systemImage: "desktopcomputer").font(.title2.bold())
                Text("按系统可确认的端口归属和父子关系显示。USB、显示和 Thunderbolt 的关系无法确认时分开列出，不推测跨协议连接。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.ports.filter { $0.port.connectionActive == true }, id: \.port.id) { pc in
                    GroupBox("↓ \(model.portLabel(pc.port.portKey ?? pc.port.serviceName))") {
                        VStack(alignment: .leading, spacing: 10) {
                            if let key = pc.port.portKey { Text("线缆：\(model.cableLabel(model.bindings.assignments[key]))").font(.caption) }
                            let nodes = USBDeviceNode.flatten(USBDeviceNode.buildTree(from: pc.attributedDevices))
                            ForEach(nodes) { node in
                                Label("\(node.device.displayName) · \(node.device.speedLabel)", systemImage: node.device.isHub ? "point.3.connected.trianglepath.dotted" : "externaldrive")
                                    .padding(.leading, CGFloat(node.depth) * 24)
                            }
                            ForEach(Array(pc.portDisplayPorts.enumerated()), id: \.offset) { _, dp in
                                Label("\(dp.monitor?.productName ?? "显示器") · \(dp.currentMode?.label ?? "模式未知")", systemImage: "display")
                            }
                            if nodes.isEmpty && pc.portDisplayPorts.isEmpty { Text("已连接；没有进一步的设备层级数据。").foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }.padding(.leading, 20)
                }
                if let snapshot = model.snapshot {
                    let unmatchedDisplays = snapshot.displayPorts.filter { dp in !model.ports.contains { $0.portDisplayPorts.contains(dp) } }
                    if !unmatchedDisplays.isEmpty {
                        GroupBox("原生视频输出 / 未归属到 USB-C 的显示器") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(Array(unmatchedDisplays.enumerated()), id: \.offset) { _, dp in
                                    Label("\(dp.monitor?.productName ?? "显示器") · \(dp.currentMode?.label ?? "模式未知")", systemImage: "display")
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                    }
                    let attributedIDs = Set(model.ports.flatMap(\.attributedDevices).map(\.id))
                    let unassigned = snapshot.usbDevices.filter { !attributedIDs.contains($0.id) }
                    if !unassigned.isEmpty {
                        GroupBox("内置或无法确认外接端口的 USB 设备") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(unassigned) { device in Label(device.displayName, systemImage: "externaldrive") }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                    }
                    let roots = snapshot.thunderboltSwitches.filter { $0.parentSwitchUID == nil }
                    if !roots.isEmpty {
                        Text("Thunderbolt / USB4 交换树").font(.headline)
                        ForEach(Array(roots.enumerated()), id: \.element.id) { index, root in
                            GroupBox("Mac 内置 Thunderbolt / USB4 控制器 \(index + 1)") {
                                VStack(alignment: .leading, spacing: 10) {
                                    let children = ThunderboltTopology.flatten(ThunderboltTopology.tree(from: root, in: snapshot.thunderboltSwitches))
                                    if children.isEmpty { Text("此控制器下未发现下游交换节点。").foregroundStyle(.secondary) }
                                    ForEach(children) { child in
                                        Label("\(child.sw.vendorName) \(child.sw.modelName)", systemImage: "arrow.turn.down.right")
                                            .padding(.leading, CGFloat(child.depth) * 24)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            }
                        }
                    }
                }
            }.padding(12)
        }
    }
}
