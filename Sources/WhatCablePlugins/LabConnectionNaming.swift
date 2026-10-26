import SwiftUI
import WhatCableCore

/// Independent presentation labels; never change diagnostic or link facts.
public struct LabConnectionHeadline: View {
    let portKey: String?
    let fallback: String
    @ObservedObject private var model = LabWindow.shared.model
    @State private var editing = false

    public init(portKey: String?, fallback: String) {
        self.portKey = portKey; self.fallback = fallback
    }

    private var profile: NamedCable? {
        guard let portKey, let id = model.bindings.assignments[portKey] else { return nil }
        return model.names.first { $0.id == id }
    }

    public var body: some View {
        HStack {
            Text(profile.flatMap { $0.connectionTitle.isEmpty ? nil : $0.connectionTitle } ?? fallback)
                .font(.title3.bold())
            if let portKey {
                Button { editing = true } label: { Image(systemName: "pencil").font(.caption) }
                    .buttonStyle(.plain).help("修改连接名称与线缆类型")
                    .sheet(isPresented: $editing) {
                        LabConnectionNamingEditor(model: model, port: portKey, original: profile)
                    }
            }
        }
    }
}

struct LabConnectionNamingEditor: View {
    @ObservedObject var model: LabModel
    let port: String
    let original: NamedCable?
    @State private var title = ""
    @State private var kind = ""
    @State private var maximum = ""
    @State private var sessionToken: String?
    @Environment(\.dismiss) private var dismiss

    private var suggestions: LabConnectionSuggestions {
        let pc = model.ports.first { $0.port.portKey == port }
        let display = pc?.portDisplayPorts.compactMap { DisplayDiagnostic(dp: $0, cable: nil) }.first
        return LabConnectionSuggestions(displayName: display?.facts.monitorName,
            accessoryName: pc?.portAccessory?.displayName,
            hasDisplay: display != nil, hasUSBDevices: !(pc?.attributedDevices.isEmpty ?? true),
            isThunderbolt: pc?.port.transportsActive.contains(where: { $0.lowercased().contains("thunderbolt") || $0.lowercased().contains("usb4") }) ?? false,
            declaredSpeed: pc?.cableEmarker?.cableVDO?.speed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("连接名称与线缆说明").font(.title2.bold())
            Form {
                TextField("显示名称，例如 左侧显示器", text: $title)
                HStack {
                    TextField("线缆类型", text: $kind)
                    Menu("常用类型") {
                        ForEach(["USB-C", "USB-C 转 DP", "USB-C 转 HDMI", "Thunderbolt"], id: \.self) { value in
                            Button(value) { kind = value }
                        }
                    }
                }
                TextField(suggestions.maximum.isEmpty ? "最大规格未知，可按产品说明补充" : "最大规格", text: $maximum)
                Button("重新填入识别建议") {
                    title = suggestions.title; kind = suggestions.kind; maximum = suggestions.maximum
                }
            }
            Text(suggestions.explanation)
                .font(.caption).foregroundStyle(.secondary)
            Text("建议可修改，保存后视为你的确认。当前链路速率仍单独显示，不会当作线缆最大规格。")
                .font(.caption).foregroundStyle(.secondary)
            Text("保存到线缆档案。重新插入后需手动确认是这根线，再恢复这些名称和规格。")
                .font(.caption).foregroundStyle(.secondary)
            if let error = model.error { Text(error).foregroundStyle(.orange) }
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("保存") { save() }.buttonStyle(.borderedProminent)
                    .disabled(title.count > 80 || kind.count > 40 || maximum.count > 80
                        || model.bindings.tokens[port] == nil || (kind.isEmpty && !maximum.isEmpty))
            }
        }.padding(24).frame(width: 560)
        .onAppear {
            sessionToken = model.bindings.tokens[port]
            title = original?.connectionTitle.isEmpty == false ? original!.connectionTitle : suggestions.title
            kind = original?.connectorType.isEmpty == false ? original!.connectorType : suggestions.kind
            maximum = original?.maximumCapability.isEmpty == false ? original!.maximumCapability : suggestions.maximum
        }
    }

    private func save() {
        guard let sessionToken, model.bindings.tokens[port] == sessionToken else {
            model.error = "连接已变化，请重新打开命名窗口。"; return
        }
        model.selectedPort = port
        if let original, model.bindings.assignments[port] != original.id {
            model.error = "连接已变化，请重新打开命名窗口。"; return
        }
        if original == nil {
            guard model.bindings.assignments[port] == nil else {
                model.error = "线缆指定已变化，请重新打开命名窗口。"; return
            }
            let label = title.isEmpty ? (kind.isEmpty ? "连接线缆" : kind) : title
            model.saveName(label)
        }
        guard var profile = model.selectedName else { return }
        profile.connectionTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.connectorType = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.maximumCapability = maximum.trimmingCharacters(in: .whitespacesAndNewlines)
        model.saveProfile(profile)
        if model.error == nil { dismiss() }
    }
}
