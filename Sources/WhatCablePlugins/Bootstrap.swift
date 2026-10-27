import WhatCableAppKit
import SwiftUI

@MainActor
public func presentLabDiagnostics() { LabWindow.shared.show() }

@MainActor
public func bootstrapPlugins(registry: PluginRegistry) {
    registry.register(launchHook: {
        LabWindow.shared.model.start()
        LabWindow.shared.model.setVisible(false)
    })
    registry.register(menuItem: PluginMenuItem(id: "independent-lab", title: "扩展诊断与线缆命名…") {
        LabWindow.shared.show()
    }, at: .statusItemMenu)
    registry.register(headerButton: {
        AnyView(Button { LabWindow.shared.show() } label: {
            Image(systemName: "waveform.path.ecg").help("打开功率曲线、诊断与线缆命名")
        }.buttonStyle(.plain))
    })
    registry.register(portCardTrailing: { port in
        AnyView(Button("诊断与命名…") { LabWindow.shared.show(port: port.portKey) }.font(.caption))
    })
    registry.register(cliCommand: CLICommand(flagNames: ["--lab-dashboard"],
        helpLines: "  --lab-dashboard    Independent live terminal dashboard (Ctrl+C to exit)",
        readsCableData: true, matches: { $0.contains("--lab-dashboard") }, run: { _ in
            await LabCLI.dashboard()
        }))
    registry.register(cliCommand: CLICommand(flagNames: ["--lab-monitor-json"],
        helpLines: "  --lab-monitor-json Independent power telemetry, newline-delimited JSON",
        readsCableData: true, matches: { $0.contains("--lab-monitor-json") }, run: { _ in
            await LabCLI.monitorJSON()
        }))
    registry.register(cliCommand: CLICommand(flagNames: ["--lab-snapshot"],
        helpLines: "  --lab-snapshot     Independent diagnostic and power snapshot as JSON",
        readsCableData: true, matches: { $0.contains("--lab-snapshot") }, run: { _ in
            await LabCLI.snapshot()
        }))
}
