import Foundation
import Darwin
import WhatCableCore
import WhatCableDarwinBackend

@MainActor
enum LabCLI {
    static func snapshot() async {
        setCoreLocale("zh-Hans")
        let model = LabModel()
        model.start()
        defer { model.stop() }
        // Give the first shared hardware read and power tick time to settle.
        try? await Task.sleep(for: .seconds(2))
        do {
            guard let snapshot = model.snapshot else { throw CocoaError(.fileReadUnknown) }
            let raw = try JSONFormatter.render(ports: snapshot.ports, sources: snapshot.powerSources,
                identities: snapshot.identities, showRaw: false, adapter: snapshot.adapter,
                thunderboltSwitches: snapshot.thunderboltSwitches, isDesktopMac: snapshot.isDesktopMac,
                batteryFullyCharged: snapshot.batteryFullyCharged, batteryIsCharging: snapshot.batteryIsCharging,
                batteryChargeState: snapshot.batteryChargeState, federatedIdentities: snapshot.federatedIdentities,
                usb3Transports: snapshot.usb3Transports, trmTransports: snapshot.trmTransports,
                cioCapabilities: snapshot.cioCapabilities, accessoryIdentities: snapshot.accessoryIdentities,
                usbDevices: snapshot.usbDevices, displayPorts: snapshot.displayPorts,
                builtInDisplayPorts: BuiltInDisplayPort.group(from: snapshot.displayPorts))
            var object: [String: Any] = ["build": "接口线缆助手 independent MIT extensions",
                "cableSnapshot": try JSONSerialization.jsonObject(with: Data(raw.utf8))]
            if let power = model.power {
                object["power"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(power))
            }
            object["diagnostics"] = model.ports.map { pc -> [String: Any] in
                var row: [String: Any] = ["port": pc.port.portKey ?? pc.port.serviceName]
                if let c = model.charging(pc) { row["charging"] = ["summary": c.summary, "detail": c.detail] }
                if let d = model.dataLink(pc) { row["dataLink"] = ["summary": d.summary, "detail": d.detail] }
                row["displays"] = pc.portDisplayPorts.compactMap { dp -> [String: String]? in
                    guard let d = model.display(dp, pc: pc) else { return nil }
                    return ["summary": d.summary, "detail": d.detail]
                }
                return row
            }
            print(String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        } catch {
            FileHandle.standardError.write(Data("接口线缆助手: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func monitorJSON() async {
        let service = PowerService()
        service.start()
        defer { service.stop() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for await snapshot in service.snapshots {
            do {
                print(String(decoding: try encoder.encode(snapshot), as: UTF8.self))
                fflush(stdout)
            } catch {
                FileHandle.standardError.write(Data("接口线缆助手: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
    }

    static func dashboard() async {
        setCoreLocale("zh-Hans")
        let model = LabModel()
        model.start()
        defer { model.stop() }
        let interactive = isatty(STDOUT_FILENO) == 1
        var done = false
        let signals = [SIGINT, SIGTERM].map { value -> DispatchSourceSignal in
            signal(value, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: value, queue: .main)
            source.setEventHandler { done = true }
            source.resume()
            return source
        }
        defer {
            signals.forEach { $0.cancel() }
            signal(SIGINT, SIG_DFL)
            signal(SIGTERM, SIG_DFL)
            if interactive { print("\u{1B}[?25h", terminator: ""); fflush(stdout) }
        }
        if interactive { print("\u{1B}[?25l", terminator: "") }
        try? await Task.sleep(for: .seconds(1))
        while !done && !Task.isCancelled {
            var lines = ["接口线缆助手 | 功率与连接 | Ctrl+C 退出", Date().formatted(), ""]
            if let power = model.power {
                lines.append("\(power.onBattery ? "电池放电" : "系统输入"): \(LabText.watts(power.activePowerMW))")
                lines.append("充电路径电阻: \(LabText.resistance(power.resistanceEstimate))")
                lines.append("电阻包含接头、充电器和内部路径，不能单独判断线材质量。")
            }
            for pc in model.ports {
                lines.append("")
                lines.append("\(pc.port.portDescription ?? pc.port.serviceName) | \(pc.port.connectionActive == true ? "已连接" : "未连接") | \(pc.port.transportsActive.joined(separator: "/"))")
                if let diagnostic = model.charging(pc) { lines.append("  充电: \(diagnostic.summary)") }
                if let diagnostic = model.dataLink(pc) { lines.append("  数据: \(diagnostic.summary)") }
                for dp in pc.portDisplayPorts {
                    if let diagnostic = model.display(dp, pc: pc) { lines.append("  显示: \(diagnostic.summary)") }
                }
                if let power = model.power {
                    for sample in power.portSamples.droppingStaleContracted(externalPowerAbsent: power.externalPowerAbsent)
                        where sample.portKey == pc.port.portKey {
                        lines.append("  功率: \(LabText.watts(sample.isContractedFallback ? sample.pdPowerMW : sample.watts)) (\(sample.isContractedFallback ? "协商上限，非实测" : sample.isSMCMeasured ? "SMC 实测" : "控制器读数，可能滞留"))")
                    }
                }
            }
            if interactive { print("\u{1B}[H\u{1B}[2J", terminator: "") }
            print(lines.map(LabText.terminal).joined(separator: "\n"))
            fflush(stdout)
            if !interactive { break }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
