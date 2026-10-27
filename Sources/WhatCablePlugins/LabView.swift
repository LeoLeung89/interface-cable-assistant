import SwiftUI
import Charts
import AppKit
import WhatCableCore

@MainActor
final class LabWindow: NSObject, NSWindowDelegate {
    static let shared = LabWindow()
    private var window: NSWindow?
    let model = LabModel(recordsArchive: true)

    func show(port: String? = nil) {
        if let port { model.selectedPort = port }
        if window == nil {
            let controller = NSHostingController(rootView: LabView(model: model))
            let w = NSWindow(contentViewController: controller)
            w.title = "\(AppInfo.name) · 扩展诊断"
            w.setContentSize(NSSize(width: 1200, height: 840))
            w.minSize = NSSize(width: 1000, height: 700)
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false
            w.isRestorable = false
            w.delegate = self
            w.center()
            window = w
        }
        model.start()
        model.setVisible(true)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) { model.setVisible(false) }
    func windowDidMiniaturize(_ notification: Notification) { model.setVisible(false) }
    func windowDidDeminiaturize(_ notification: Notification) { model.setVisible(true) }
}

struct LabView: View {
    @ObservedObject var model: LabModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("连接与功率").font(.title2.bold())
                    Text("\(AppInfo.name) · 基于公开源码的独立扩展").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Label("每秒刷新", systemImage: "waveform.path").font(.caption).foregroundStyle(.secondary)
                Button("刷新", systemImage: "arrow.clockwise") { model.refresh() }
                Button("导出曲线…", systemImage: "square.and.arrow.up") { export() }
                Button("诊断报告…", systemImage: "doc.text") { LabSave.text(model.diagnosticReport(), name: "WhatCableLab-report.md", model: model) }
                Button("桌面组件…", systemImage: "square.grid.2x2") {
                    model.widgetWriter.publish(model: model, force: true)
                    LabWidgetWriter.instructions(status: model.widgetWriter.status)
                }
            }.padding(20)
            Divider()
            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(.orange).padding(10)
            }
            if let error = model.storageError { Text(error).foregroundStyle(.orange).padding(8) }
            TabView {
                LabPowerView(model: model).tabItem { Text("功率与电阻") }
                LabDiagnosticsView(model: model).tabItem { Text("连接诊断") }
                LabDisplayView(model: model).tabItem { Text("显示诊断") }
                LabLibraryView(model: model).tabItem { Text("线缆档案") }
                LabTimelineView(model: model).tabItem { Text("历史与提醒") }
                LabTopologyView(model: model).tabItem { Text("连接拓扑") }
                LabCompareView(model: model).tabItem { Text("线缆对比") }
                LabStatisticsView(model: model).tabItem { Text("长期统计") }
            }.padding(16)
        }
        .textSelection(.enabled)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "WhatCableLab-power.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.exportCSV().write(to: url, atomically: true, encoding: .utf8) }
        catch { model.error = "导出失败：\(error.localizedDescription)" }
    }
}

struct LabPowerView: View {
    @ObservedObject var model: LabModel
    private var samples: [PortPowerSample] {
        guard let p = model.power else { return [] }
        return p.portSamples.droppingStaleContracted(externalPowerAbsent: p.externalPowerAbsent)
    }
    private var chartPoints: [LabPoint] { model.history.points.filter { $0.series == model.chartSeries } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let p = model.power {
                    HStack(spacing: 30) {
                        metric(p.onBattery ? "电池放电" : "系统电源输入", LabText.watts(p.activePowerMW))
                        metric("电压", String(format: "%.2f V", Double(p.activeVoltageMV) / 1000))
                        metric("电流", String(format: "%.3f A", Double(p.activeCurrentMA) / 1000))
                        Spacer()
                        Text(p.timestamp, style: .time).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("系统输入包含 Mac 自身耗电，不等于电池充电功率；0 表示报告值为零，不能证明硬件支持测量。")
                        .font(.caption).foregroundStyle(.secondary)
                } else { ProgressView("等待读数…") }

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("最近 10 分钟功率").font(.headline)
                            Spacer()
                            Picker("曲线", selection: $model.chartSeries) {
                                Text("系统输入 / 电池放电").tag("system")
                                ForEach(model.ports, id: \.port.id) { pc in
                                    if let key = pc.port.portKey {
                                        Text(model.portLabel(key)).tag(key)
                                    }
                                }
                            }.frame(width: 270)
                        }
                        if chartPoints.isEmpty {
                            ContentUnavailableView("暂无实测曲线", systemImage: "chart.xyaxis.line",
                                description: Text("端口曲线仅记录 SMC 实测值；仅有协商上限或控制器缓存时不会绘制。"))
                                .frame(height: 205)
                        } else {
                            Chart(chartPoints) { point in
                                LineMark(x: .value("时间", point.timestamp), y: .value("功率 W", point.watts),
                                    series: .value("连续区段", point.segment))
                                    .foregroundStyle(.teal)
                            }
                            .chartYScale(domain: 0...max(1, (chartPoints.map(\.watts).max() ?? 1) * 1.1))
                            .chartYAxisLabel("W")
                            .frame(height: 220)
                        }
                        Text("窗口显示时每秒采样；启用历史记录后，隐藏时约每 10 秒采样。断开连接、切换电源或采样中断时，曲线分段。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                GroupBox("端口功率") {
                    VStack(alignment: .leading, spacing: 10) {
                        if samples.isEmpty { Text("没有可用的端口功率数据。").foregroundStyle(.secondary) }
                        ForEach(Array(samples.enumerated()), id: \.offset) { _, s in
                            HStack {
                                Text(model.portLabel(s.portKey.isEmpty ? String(s.portIndex) : s.portKey))
                                Spacer()
                                Text(LabText.watts(s.isContractedFallback ? s.pdPowerMW : s.watts)).monospacedDigit()
                                Text(s.isContractedFallback ? "协商上限，非实测" : s.isSMCMeasured ? "SMC 实测" : "控制器读数，可能滞留")
                                    .font(.caption).foregroundStyle(.secondary).frame(width: 190, alignment: .trailing)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                GroupBox("充电路径电阻估算") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.snapshot?.isDesktopMac == true && model.power?.resistancePortKey == nil
                            ? "这台台式 Mac 没有可用于估算的 USB-C 充电输入"
                            : LabText.resistance(model.power?.resistanceEstimate)).font(.headline)
                        if let key = model.power?.resistancePortKey { Text("对应充电端口：\(key)").font(.caption) }
                        Text("估算包含线缆、接头、充电器输出与 Mac 内部路径，不能单独用来判定线材质量。需要持续充电和足够的电流变化；样本不足或不稳定时不报告阻值。")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("重新采样") { model.service.resetResistanceBaseline() }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }.padding(8)
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 27, weight: .semibold, design: .rounded)).monospacedDigit()
        }
    }
}

struct LabDiagnosticsView: View {
    @ObservedObject var model: LabModel
    @State private var name = ""
    @State private var physicalLabel = ""
    @State private var editingPresentation = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("端口", selection: $model.selectedPort) {
                    ForEach(model.ports, id: \.port.id) { pc in
                        if let key = pc.port.portKey {
                            Text("\(model.portLabel(key)) · \(pc.port.connectionActive == true ? "已连接" : "未连接")").tag(key)
                        }
                    }
                }
                if let pc = model.selected {
                    HStack {
                        TextField("实体位置，例如：背面左起第二个", text: $physicalLabel)
                        Button("保存端口位置") { model.setPortLabel(model.selectedPort, value: physicalLabel) }
                            .disabled(!model.archiveWritable)
                    }
                    Text("手动确认物理位置后填写；软件无法可靠猜测机身左右顺序。已保存：\(model.portLabel(model.selectedPort))")
                        .font(.caption).foregroundStyle(.secondary)
                    nameCard(pc)
                    if let diagnostic = model.charging(pc) {
                        LabFinding(title: "充电诊断", summary: diagnostic.summary, detail: diagnostic.detail)
                        HStack {
                            fact("充电器能力", diagnostic.chargerW.map { "\($0) W" } ?? "未知")
                            fact("线缆标称能力", diagnostic.cableW.map { "\($0) W" } ?? "未知")
                            fact("协商功率", pc.chargerWattageSource.watts.map { "\($0) W" } ?? "未知")
                        }
                    } else {
                        LabFinding(title: "充电诊断", summary: "当前没有可诊断的充电连接", detail: "请连接充电器，或等待端口完成协商。")
                    }
                    if let diagnostic = model.dataLink(pc) {
                        LabFinding(title: "数据链路诊断", summary: diagnostic.summary, detail: diagnostic.detail)
                        HStack {
                            fact("Mac 端口", speed(diagnostic.facts.hostGbps))
                            fact("线缆标称", speed(diagnostic.facts.cableGbps))
                            fact("设备能力", speed(diagnostic.facts.deviceGbps))
                            fact("当前链路", speed(diagnostic.facts.activeGbps))
                        }
                    } else {
                        LabFinding(title: "数据链路诊断", summary: "当前没有可诊断的数据链路", detail: "只连接充电器时通常没有数据链路；软件显示的是链路速率，非文件传输测速。")
                    }
                    GroupBox("端口状态与针脚配置") {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("活动协议：\(pc.port.transportsActive.joined(separator: " / "))")
                            Text("插入事件：\(pc.port.plugEventCount.map(String.init) ?? "未知") · 过流计数：\(pc.port.overcurrentCount.map(String.init) ?? "未知")")
                            Text("液体检测控制器：\(pc.port.ldcmStateDescription ?? "硬件未提供状态")")
                            Text("插头方向：\(pc.port.plugOrientation == 1 ? "正常" : pc.port.plugOrientation == 2 ? "翻转" : "未知")")
                            if pc.port.pinConfiguration.isEmpty {
                                Text("硬件未提供针脚配置。").foregroundStyle(.secondary)
                            } else {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], alignment: .leading) {
                                    ForEach(pc.port.pinConfiguration.keys.sorted(), id: \.self) { pin in
                                        Text("\(pin): \(pc.port.pinConfiguration[pin] ?? "—")")
                                            .font(.system(.caption, design: .monospaced)).padding(8)
                                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                                    }
                                }
                            }
                            Text("显示 macOS 提供的原始通道配置，不代表逐针电压、导通测试或线材内部接线。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                } else { ContentUnavailableView("未检测到端口", systemImage: "cable.connector") }
            }.padding(8)
        }
        .onAppear { physicalLabel = model.archive.portLabels[model.selectedPort] ?? "" }
        .onChange(of: model.selectedPort) { _, key in name = ""; physicalLabel = model.archive.portLabels[key] ?? "" }
    }

    private func nameCard(_ pc: CableSnapshotContext.PortContext) -> some View {
        GroupBox("线缆自定义命名") {
            VStack(alignment: .leading, spacing: 10) {
                Button("编辑连接显示名称与线缆规格…") { editingPresentation = true }
                    .disabled(pc.port.connectionActive != true)
                    .sheet(isPresented: $editingPresentation) {
                        LabConnectionNamingEditor(model: model, port: model.selectedPort, original: model.selectedName)
                    }
                Text(model.selectedName.map { "当前名称：\($0.name)" } ?? "当前连接尚未指定线缆名称")
                    .font(.headline)
                if model.selectedName == nil && !model.candidates.isEmpty {
                    HStack {
                        Text("相同型号指纹的候选：").font(.caption)
                        ForEach(model.candidates.prefix(4)) { cable in
                            Button("确认是 \(cable.name)") { model.assign(cable.id) }
                        }
                    }
                }
                HStack {
                    TextField("输入线缆名称（最多 80 字）", text: $name)
                    Button(model.selectedName == nil ? "保存新线缆" : "修改名称") {
                        model.saveName(name)
                        name = ""
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 80)
                    Menu("指定已保存线缆") {
                        Button("取消当前指定") { model.assign(nil) }
                        ForEach(model.names) { cable in
                            Button(cable.name) { model.assign(cable.id) }
                        }
                    }
                }.disabled(pc.port.connectionActive != true)
                Text("名称永久保存在本机。每次重新插入后，请手动指定已保存的线缆；e-marker 通常只能识别型号，无法保证区分两根相同线缆。")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    private func speed(_ gbps: Double?) -> String { gbps.map { String(format: "%.2f Gbps", $0) } ?? "未知" }
    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LabFinding: View {
    let title: String
    let summary: String
    let detail: String
    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 8) {
                Text(summary).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
}

struct LabDisplayView: View {
    @ObservedObject var model: LabModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("基线按显示器信息与连接端口保存。主动调整显示模式后，可将当前模式重新记作正常。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("记住当前显示模式") { model.rememberDisplays() }
                }
                let displays = model.snapshot?.displayPorts ?? []
                if displays.isEmpty {
                    ContentUnavailableView("没有可读取的显示链路", systemImage: "display",
                        description: Text("连接外接显示器后显示实时模式、链路带宽与诊断。部分扩展坞或显示协议可能不提供这些信息。"))
                }
                ForEach(Array(displays.enumerated()), id: \.offset) { _, dp in
                    let pc = model.ports.first { $0.portDisplayPorts.contains(dp) }
                    if let d = model.display(dp, pc: pc) {
                        GroupBox(dp.monitor?.productName ?? "外接显示器") {
                            VStack(alignment: .leading, spacing: 10) {
                                if let native = BuiltInDisplayPort.group(from: displays).first(where: { $0.displays.contains(dp) }) {
                                    LabNativeDisplayHeadline(portID: native.serviceName, portType: native.portType,
                                        displayName: d.facts.monitorName, fallback: d.summary)
                                } else { Text(d.summary).font(.headline) }
                                Text(d.detail).foregroundStyle(.secondary)
                                if let m = d.facts.currentMode {
                                    Text("当前模式：\(m.label)").font(.system(.caption, design: .monospaced))
                                }
                                Text("链路：\(dp.link.laneCount) 通道 × \(dp.link.linkRateDescription ?? "未知速率")")
                                if let width = d.facts.topModeWidth, let height = d.facts.topModeHeight {
                                    Text("已声明最高模式：\(width) × \(height) @ \(d.facts.maxRefreshHz.map(String.init) ?? "?") Hz")
                                }
                                if let adapter = d.facts.branchDevice { Text("转接设备：\(adapter)") }
                                if let mode = d.facts.topModeAvailability {
                                    Text("最高模式可用性：\(availability(mode))")
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        }
                    } else {
                        LabFinding(title: dp.monitor?.productName ?? "外接显示器", summary: "显示链路未激活", detail: "没有足够数据进行诊断。")
                    }
                }
            }.padding(8)
        }
    }

    private func availability(_ value: DisplayDiagnostic.TopModeAvailability) -> String {
        switch value {
        case .offeredUncompressed: return "可用，无需 DSC 压缩"
        case .offeredWithDSC: return "可用，支持 DSC 压缩"
        case .offeredUnresolved: return "可用，压缩状态未确定"
        case .notOffered: return "当前链路不提供该模式"
        case .notListed: return "系统未列出该模式"
        }
    }
}

struct LabLibraryView: View {
    @ObservedObject var model: LabModel
    @State private var editing: NamedCable?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("名称、照片和参数保存在本机。下次连接时可确认匹配候选，或手动指定；历史只归属到你确认过的线缆。")
                .foregroundStyle(.secondary)
            if model.names.isEmpty { ContentUnavailableView("还没有命名线缆", systemImage: "tag") }
            List(model.names) { cable in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(cable.name).font(.headline)
                        Text(cable.fingerprint == nil ? "没有 e-marker 型号信息" : "已记录型号指纹，非唯一序列号")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("\(cable.length) · \(cable.ratedSpecs)").font(.caption)
                        Text("已关联 \(model.archive.sessions.filter { $0.cableID == cable.id }.count) 次连接")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("编辑档案") { editing = cable }
                    Button("删除", role: .destructive) { model.deleteName(cable.id) }
                }.padding(.vertical, 6)
            }
        }.padding(8)
        .sheet(item: $editing) { cable in LabProfileEditor(model: model, draft: cable) }
    }
}
