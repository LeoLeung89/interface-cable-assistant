import Foundation
import AppKit
import CryptoKit
import UserNotifications
import WhatCableCore
import WhatCableDarwinBackend

@MainActor
extension LabModel {
    func portLabel(_ key: String) -> String {
        let label = archive.portLabels[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return label.isEmpty ? "端口 \(key)" : "\(label)（\(key)）"
    }

    func cableLabel(_ id: UUID?) -> String {
        guard let id else { return "尚未手动指定" }
        return names.first(where: { $0.id == id })?.name ?? "档案已删除"
    }

    var candidates: [NamedCable] {
        guard let fp = LabCableIdentity.fingerprint(selected?.cableEmarker) else { return [] }
        return names.filter { $0.fingerprint == fp }
    }

    func setVisible(_ visible: Bool) {
        windowVisible = visible
        WatcherHub.shared.setSurfaceVisible(visible, surface: "independent-lab")
        service.pollingInterval = visible ? .seconds(1) : .seconds(10)
        if visible || (recordsArchive && archive.recording && archiveWritable) {
            service.start()
            if visible { service.refresh() }
        } else { service.stop() }
        if !visible { flush(force: true) }
    }

    func shutdown() {
        guard recordsArchive else { return }
        engine.pause(at: Date())
        flush(force: true)
    }

    func setRecording(_ enabled: Bool) {
        guard archiveWritable else { return }
        if !enabled { engine.pause(at: Date()) }
        engine.archive.recording = enabled
        capture()
        setVisible(windowVisible)
        flush(force: true)
    }

    func setRetention(_ days: Int) {
        engine.archive.retentionDays = min(365, max(1, days))
        flush(force: true)
    }

    func setPortLabel(_ key: String, value: String) {
        engine.archive.portLabels[key] = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        flush(force: true)
    }

    func flush(force: Bool = false) {
        guard recordsArchive, archiveWritable else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastFlush) >= 30 else { return }
        engine.prune(at: now)
        do { try archiveStore.save(archive); lastFlush = now }
        catch { storageError = "历史记录保存失败：\(error.localizedDescription)" }
    }

    func recordPower(_ sample: PowerMonitorSnapshot) {
        guard recordsArchive, archiveWritable, archive.recording else { return }
        if lastPowerSource != sample.onBattery { engine.invalidatePower() }
        lastPowerSource = sample.onBattery
        let systemSeries = sample.onBattery ? "system:battery" : "system:input"
        let ports = sample.portSamples.droppingStaleContracted(externalPowerAbsent: sample.externalPowerAbsent)
            .filter { $0.isSMCMeasured && !$0.portKey.isEmpty }
        engine.retainPowerSeries(Set(ports.map { "port:\($0.portKey)" } + [systemSeries]))
        engine.recordPower(series: systemSeries, watts: Double(sample.activePowerMW) / 1000, at: sample.timestamp)
        for port in ports {
            engine.recordPower(series: "port:\(port.portKey)", watts: Double(port.watts) / 1000, at: sample.timestamp)
        }
        flush()
    }

    func displayReading(_ dp: IOPortTransportStateDisplayPort) -> LabDisplayReading? {
        guard let mode = dp.currentMode, dp.link.active else { return nil }
        // Internal hash, scoped to the port. No raw EDID/serial is exported.
        let identity = dp.monitor?.edid ?? Data("\(dp.monitor?.productName ?? "Display")".utf8)
        let hash = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        let key = "\(hash)|\(dp.parentPortType)/\(dp.parentPortNumber)|\(dp.index)"
        return LabDisplayReading(id: key, name: dp.monitor?.productName ?? "外接显示器",
            mode: LabDisplayMode(width: mode.width, height: mode.height, hz: mode.refreshHz))
    }

    func recordConnections() {
        guard recordsArchive, archiveWritable, archive.recording else { return }
        let now = Date()
        let observations = ports.compactMap { pc -> LabObservation? in
            guard let port = pc.port.portKey, let token = LabCableIdentity.sessionToken(pc) else { return nil }
            return LabObservation(port: port, token: token, fingerprint: LabCableIdentity.fingerprint(pc.cableEmarker),
                linkGbps: dataLink(pc)?.facts.activeGbps, displays: pc.portDisplayPorts.compactMap(displayReading))
        }
        let covered = Set(observations.flatMap(\.displays).map(\.id))
        let extra = (snapshot?.displayPorts ?? []).compactMap(displayReading).filter { !covered.contains($0.id) }
        let newEvents = engine.ingest(observations, standaloneDisplays: extra, at: now)
        for (port, cable) in bindings.assignments { engine.assign(cable, port: port) }
        for warning in newEvents where warning.warning { notify(warning) }
        if !newEvents.isEmpty { flush(force: true) }
    }

    func rememberDisplays() {
        let readings = (snapshot?.displayPorts ?? []).compactMap(displayReading)
        for (_, group) in Dictionary(grouping: readings, by: \.id) where group.count == 1 {
            let display = group[0]
            engine.archive.displayBaselines[display.id] = display
        }
        flush(force: true)
    }

    func saveProfile(_ profile: NamedCable) {
        guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              profile.name.count <= 80, names.contains(where: { $0.id == profile.id }) else { return }
        guard profile.connectionTitle.count <= 80, profile.connectorType.count <= 40, profile.maximumCapability.count <= 80,
              profile.length.count <= 100, profile.ratedSpecs.count <= 300,
              profile.notes.count <= 8000, profile.purchaseURL.count <= 2048 else {
            error = "档案文字过长，请缩短后保存。"; return
        }
        if !profile.purchaseURL.isEmpty {
            guard let url = URL(string: profile.purchaseURL), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil else { error = "购买链接请填写完整的 http 或 https 地址。"; return }
        }
        var updated = names
        guard let i = updated.firstIndex(where: { $0.id == profile.id }) else { return }
        updated[i] = profile
        do { try persist(updated); names = updated; error = nil; widgetWriter.publish(model: self, force: true) }
        catch { self.error = "档案保存失败：\(error.localizedDescription)" }
    }

    func photoURL(_ filename: String?) -> URL? {
        guard let filename, filename == URL(fileURLWithPath: filename).lastPathComponent,
              filename.hasSuffix(".jpg") else { return nil }
        return storageDirectory.appendingPathComponent("photos").appendingPathComponent(filename)
    }

    func importPhoto() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return nil }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
            guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 30_000_000,
                  let image = NSImage(contentsOf: source), image.size.width > 0, image.size.height > 0 else {
                throw CocoaError(.fileReadTooLarge)
            }
            let scale = min(1, 1600 / max(image.size.width, image.size.height))
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let resized = NSImage(size: size)
            resized.lockFocus(); image.draw(in: NSRect(origin: .zero, size: size)); resized.unlockFocus()
            guard let tiff = resized.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]), data.count <= 5_000_000 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let filename = UUID().uuidString + ".jpg"
            guard let target = photoURL(filename) else { throw CocoaError(.fileWriteUnknown) }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            return filename
        } catch { self.error = "照片导入失败：\(error.localizedDescription)"; return nil }
    }

    func captureComparison(title: String) {
        guard let pc = selected else { return }
        let key = selectedPort
        let sample = power?.portSamples.first { $0.portKey == key && $0.isSMCMeasured && !$0.isContractedFallback }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let comparison = LabComparison(time: Date(), title: String((name.isEmpty ? "当前连接快照" : name).prefix(100)),
            port: key, cableID: selectedName?.id, cableName: selectedName?.name,
            fingerprint: LabCableIdentity.fingerprint(pc.cableEmarker), linkGbps: dataLink(pc)?.facts.activeGbps,
            charging: charging(pc)?.summary ?? "无充电诊断", dataLink: dataLink(pc)?.summary ?? "无数据链路诊断",
            displays: pc.portDisplayPorts.compactMap { dp in displayReading(dp).map { "\($0.name)：\($0.mode.label)" } },
            measuredPortWatts: sample.map { Double($0.watts) / 1000 },
            systemWatts: power.map { Double($0.activePowerMW) / 1000 },
            context: "\(pc.attributedDevices.map(\.displayName).joined(separator: " / "))；\(pc.port.transportsActive.joined(separator: "/"))")
        engine.archive.comparisons.append(comparison)
        flush(force: true)
    }

    func requestSystemNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] allowed, requestError in
            Task { @MainActor in
                guard let self else { return }
                self.engine.archive.notifications = allowed
                if let requestError { self.error = "通知授权失败：\(requestError.localizedDescription)" }
                else if !allowed { self.error = "系统未允许通知；异常仍会保存在应用内。" }
                self.flush(force: true)
            }
        }
    }

    func disableSystemNotifications() { engine.archive.notifications = false; flush(force: true) }

    private func notify(_ event: LabEvent) {
        guard archive.notifications else { return }
        let content = UNMutableNotificationContent()
        content.title = "接口线缆助手：\(event.title)"
        content.body = "\(portLabel(event.port)) · \(event.detail)"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: event.id.uuidString, content: content, trigger: nil)) { _ in }
    }

    func diagnosticReport() -> String {
        var lines = ["# 接口线缆助手 诊断报告", "", "生成时间：\(Date().formatted())", "",
            "系统功率为主板侧读数；链路速率不是文件传输测速。此报告未包括设备序列号或原始 EDID。", ""]
        if let power { lines += ["系统功率：\(LabText.watts(power.activePowerMW))", "充电路径电阻：\(LabText.resistance(power.resistanceEstimate))", ""] }
        for pc in ports {
            let key = pc.port.portKey ?? pc.port.serviceName
            lines += ["## \(LabReport.escape(portLabel(key)))", "",
                "线缆：\(LabReport.escape(cableLabel(bindings.assignments[key])))",
                "状态：\(pc.port.connectionActive == true ? "已连接" : "未连接")"]
            lines += ["活动协议：\(LabReport.escape(pc.port.transportsActive.joined(separator: " / ")))" ]
            if let power {
                for sample in power.portSamples.droppingStaleContracted(externalPowerAbsent: power.externalPowerAbsent) where sample.portKey == key {
                    let label = sample.isContractedFallback ? "协商上限，非实测" : sample.isSMCMeasured ? "SMC 实测" : "控制器读数，可能滞留"
                    lines.append("端口功率：\(LabText.watts(sample.isContractedFallback ? sample.pdPowerMW : sample.watts))（\(label)）")
                }
            }
            if let c = charging(pc) { lines += ["充电：\(LabReport.escape(c.summary))", LabReport.escape(c.detail)] }
            if let d = dataLink(pc) { lines += ["数据：\(LabReport.escape(d.summary))", LabReport.escape(d.detail)] }
            for dp in pc.portDisplayPorts {
                if let d = display(dp, pc: pc) { lines += ["显示：\(LabReport.escape(d.summary))", LabReport.escape(d.detail)] }
            }
            lines.append("")
        }
        lines += ["## 最近异常", ""]
        for e in archive.events.reversed().filter(\.warning).prefix(30) {
            lines.append("- \(e.time.formatted()) · \(LabReport.escape(portLabel(e.port)))：\(LabReport.escape(e.title))；\(LabReport.escape(e.detail))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func statisticsCSV() -> String {
        var rows = ["hour,series,samples,average_W,peak_W,estimated_Wh,observed_seconds"]
        let formatter = ISO8601DateFormatter()
        for b in archive.buckets.sorted(by: { $0.hour < $1.hour }) {
            rows.append("\(formatter.string(from: b.hour)),\(b.series),\(b.count),\(b.averageWatts),\(b.peakWatts),\(b.energyWh),\(b.measuredSeconds)")
        }
        return rows.joined(separator: "\n") + "\n"
    }

    func sessionsCSV() -> String {
        let formatter = ISO8601DateFormatter()
        var rows = ["started,ended,port,cable,reason,best_link_Gbps,peak_measured_W,estimated_Wh,connection_span_seconds,power_measured_seconds"]
        for s in archive.sessions {
            let values = [formatter.string(from: s.started), s.ended.map(formatter.string) ?? "",
                portLabel(s.port), cableLabel(s.cableID), s.endReason ?? "持续观察中",
                s.bestGbps.map { String($0) } ?? "", s.measuredSamples > 0 ? String(s.peakWatts) : "", String(s.energyWh), String(s.duration), String(s.measuredSeconds)]
            rows.append(values.map(LabCSV.cell).joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }
}

enum LabCSV {
    static func cell(_ value: String) -> String {
        var value = value
        if let first = value.trimmingCharacters(in: .whitespacesAndNewlines).first,
           ["=", "+", "-", "@"].contains(String(first)) { value = "'" + value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

enum LabReport {
    static func escape(_ value: String) -> String {
        var result = LabText.terminal(value)
        for c in ["\\", "`", "*", "_", "[", "]", "<", ">", "#", "|"] {
            result = result.replacingOccurrences(of: c, with: "\\" + c)
        }
        return result
    }
}
