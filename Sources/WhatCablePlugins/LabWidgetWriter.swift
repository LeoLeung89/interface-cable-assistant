import Foundation
import AppKit
import WidgetKit
import WhatCableCore
import WhatCableLabWidgetShared

@MainActor
final class LabWidgetWriter {
    private var lastWrite = Date.distantPast
    private var lastReload = Date.distantPast
    private var lastStructure: [String] = []
    private(set) var status = "添加组件后自动同步"

    func publish(model: LabModel, force: Bool = false) {
        guard model.recordsArchive, let power = model.power else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastWrite) >= 10 else { return }
        lastWrite = now
        let measured = power.portSamples.droppingStaleContracted(externalPowerAbsent: power.externalPowerAbsent)
            .filter { $0.isSMCMeasured && !$0.portKey.isEmpty }
        var ports = model.ports.prefix(16).map { pc -> LabWidgetPort in
            let key = pc.port.portKey ?? pc.port.serviceName
            let profile = model.bindings.assignments[key].flatMap { id in model.names.first { $0.id == id } }
            let alias = profile?.connectionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = alias.flatMap { $0.isEmpty ? nil : $0 }
            let c = model.context!
            let summary = PortSummary(port: pc.port, sources: pc.portSources, identities: pc.portIdentities,
                devices: pc.matchedDevices, thunderboltSwitches: c.thunderboltSwitches,
                federatedIdentities: c.federatedIdentities, usb3Transports: pc.portUSB3,
                trmTransports: pc.portTRM, cioCapability: pc.portCIO, accessoryIdentity: pc.portAccessory,
                chargerWattageSource: pc.chargerWattageSource, batteryFullyCharged: c.batteryFullyCharged,
                batteryIsCharging: c.batteryIsCharging, batteryChargeState: c.batteryChargeState, adapter: c.adapter)
            let displays = pc.portDisplayPorts.compactMap { DisplayDiagnostic(dp: $0, cable: nil) }
            let display = displays.first
            let displayDetail = [display?.facts.monitorName, display?.facts.currentMode?.shortLabel].compactMap { $0 }.joined(separator: " · ")
            let title: String
            let icon: String
            switch summary.status {
            case .empty: title = "未连接"; icon = "cable.connector"
            case .charging: title = "充电中"; icon = "bolt.fill"
            case .batteryFull: title = "电池已充满"; icon = "battery.100percent"
            case .dataDevice: title = "USB 设备"; icon = "externaldrive"
            case .thunderboltCable: title = "Thunderbolt"; icon = "bolt.horizontal"
            case .displayCable: title = "显示器"; icon = "display"
            case .unknown: title = "已连接"; icon = "cable.connector"
            }
            let detail = !displayDetail.isEmpty ? displayDetail + (displays.count > 1 ? " +\(displays.count - 1)" : "")
                : pc.portAccessory?.displayName ?? summary.topLine ?? summary.subtitle
            return LabWidgetPort(id: key, title: model.portLabel(key), cableName: name,
                connected: pc.port.connectionActive == true,
                protocols: pc.port.transportsActive.joined(separator: " / "),
                measuredWatts: measured.first { $0.portKey == key }.map { Double($0.watts) / 1000 },
                statusTitle: title, detail: detail, speedBadge: summary.linkSpeed?.badge,
                chargerWatts: power.onBattery ? nil : pc.chargerWattageSource.watts,
                deviceCount: pc.attributedDevices.count, iconName: icon, cableDescription: profile?.widgetCableDescription)
        }
        for native in BuiltInDisplayPort.group(from: model.snapshot?.displayPorts ?? []) {
            let display = native.displays.compactMap { DisplayDiagnostic(dp: $0, cable: nil) }.first
            let label = model.nativeLabels.ports[native.serviceName]
            let detail = [display?.facts.monitorName, display?.facts.currentMode?.shortLabel].compactMap { $0 }.joined(separator: " · ")
            ports.append(LabWidgetPort(id: "native:" + native.serviceName, title: native.serviceName,
                cableName: label.flatMap { $0.connectionTitle.isEmpty ? nil : $0.connectionTitle },
                connected: true, protocols: native.portType, measuredWatts: nil,
                statusTitle: "显示器", detail: detail, iconName: "display", cableDescription: label?.widgetCableDescription))
        }
        ports = Array(ports.prefix(16))
        // A ten-minute, minute-sampled trend. Its segment ID preserves gaps.
        let points = model.history.points.filter { $0.series == "system" }
        var minute: Int?
        var trend: [LabWidgetPowerPoint] = []
        for point in points.reversed() {
            let key = Int(point.timestamp.timeIntervalSince1970 / 60)
            guard minute != key else { continue }
            minute = key
            trend.append(LabWidgetPowerPoint(time: point.timestamp, watts: point.watts,
                source: power.onBattery ? "battery" : "input", segment: point.segment))
        }
        let packet = LabWidgetSnapshot(timestamp: power.timestamp, systemWatts: Double(power.activePowerMW) / 1000,
            onBattery: power.onBattery, ports: ports, trend: Array(trend.reversed().suffix(60)))
        guard let target = LabWidgetSnapshot.hostCacheURL() else {
            status = "尚未初始化组件：请先在桌面组件库添加 接口线缆助手"
            return
        }
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(packet)
            _ = try LabWidgetSnapshot.decode(data)
            try data.write(to: target, options: .atomic)
            status = "已同步 · \(now.formatted(date: .omitted, time: .shortened))"
            let structure = ports.map { "\($0.id)|\($0.connected)|\($0.cableName ?? "")|\($0.title)|\($0.protocols)|\($0.detail ?? "")|\($0.speedBadge ?? "")|\($0.deviceCount ?? 0)|\($0.cableDescription ?? "")" }
            if structure != lastStructure || now.timeIntervalSince(lastReload) >= 60 {
                WidgetCenter.shared.reloadTimelines(ofKind: LabWidgetSnapshot.connectionKind)
                WidgetCenter.shared.reloadTimelines(ofKind: LabWidgetSnapshot.powerKind)
                lastReload = now; lastStructure = structure
            }
        } catch { status = "组件同步失败：\(error.localizedDescription)" }
    }

    static func instructions(status: String) {
        let alert = NSAlert()
        alert.messageText = "接口线缆助手 桌面小组件"
        alert.informativeText = "右键桌面 → 编辑小组件 → 搜索 接口线缆助手。\n\n可选「端口与线缆」「功率概览」，支持小、中、大尺寸。首次添加后请保持应用运行片刻。\n\n\(status)\n\n组件刷新由 macOS 调度，不是每秒实时显示；底部始终标记读数时间。超过 15 分钟的功率不再显示为当前读数。"
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }
}
