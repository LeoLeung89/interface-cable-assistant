import SwiftUI
import WhatCableCore

struct LabNativeLabels: Codable {
    var version = 1
    var ports: [String: NamedCable] = [:]
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 1_000_000 else { throw CocoaError(.fileReadTooLarge) }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1, value.ports.count <= 32,
              value.ports.allSatisfy({ $0.key.count <= 120 && $0.value.connectionTitle.count <= 80
                  && $0.value.connectorType.count <= 40 && $0.value.maximumCapability.count <= 80 }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }
}

extension LabModel {
    func saveNativeLabel(_ label: NamedCable, portID: String) {
        guard nativeLabelsWritable else { error = "HDMI 名称文件不可写，请先处理读取错误。"; return }
        guard BuiltInDisplayPort.group(from: snapshot?.displayPorts ?? []).contains(where: { $0.serviceName == portID }) else {
            error = "该显示接口已断开，请重新打开编辑窗口。"; return
        }
        var updated = nativeLabels
        updated.ports[portID] = label
        do {
            let data = try JSONEncoder().encode(updated)
            _ = try LabNativeLabels.decode(data)
            try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            try data.write(to: storageDirectory.appendingPathComponent("native-display-labels-v1.json"), options: .atomic)
            nativeLabels = updated; error = nil
            widgetWriter.publish(model: self, force: true)
        } catch { self.error = "HDMI 名称保存失败：\(error.localizedDescription)" }
    }
}

public struct LabNativeDisplayHeadline: View {
    let portID: String
    let portType: String
    let displayName: String?
    let fallback: String
    @ObservedObject private var model = LabWindow.shared.model
    @State private var editing = false

    public init(portID: String, portType: String, displayName: String?, fallback: String) {
        self.portID = portID; self.portType = portType
        self.displayName = displayName; self.fallback = fallback
    }
    public var body: some View {
        HStack {
            Text(model.nativeLabels.ports[portID].flatMap { $0.connectionTitle.isEmpty ? nil : $0.connectionTitle } ?? fallback)
                .font(.title3.bold())
            Button { editing = true } label: { Image(systemName: "pencil").font(.caption) }
                .buttonStyle(.plain).help("修改显示名称与 HDMI 线缆说明")
                .sheet(isPresented: $editing) {
                    LabNativeDisplayEditor(model: model, portID: portID, portType: portType, displayName: displayName)
                }
        }
    }
}

struct LabNativeDisplayEditor: View {
    @ObservedObject var model: LabModel
    let portID: String
    let portType: String
    let displayName: String?
    @State private var draft = NamedCable(name: "显示连接")
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("显示名称与线缆说明").font(.title2.bold())
            Form {
                TextField("显示名称", text: $draft.connectionTitle)
                TextField("线缆类型", text: $draft.connectorType)
                TextField("最大规格未知，可按产品说明补充", text: $draft.maximumCapability)
            }
            Text("名称取自显示器，类型取自 Mac 的原生接口。HDMI 没有 USB-C e-marker，软件无法从当前画面确定线材最大规格。")
                .font(.caption).foregroundStyle(.secondary)
            Text("这些信息按 \(portID) 接口保存，不代表识别了某一根线；更换显示器或 HDMI 线后，请重新核对名称与规格。名称留空恢复默认标题。")
                .font(.caption).foregroundStyle(.secondary)
            if let error = model.error { Text(error).foregroundStyle(.orange) }
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("保存") {
                    model.saveNativeLabel(draft, portID: portID)
                    if model.error == nil { dismiss() }
                }.buttonStyle(.borderedProminent)
                    .disabled(draft.connectionTitle.count > 80 || draft.connectorType.count > 40
                        || draft.maximumCapability.count > 80 || (draft.connectorType.isEmpty && !draft.maximumCapability.isEmpty))
            }
        }.padding(24).frame(width: 560)
        .onAppear {
            if let existing = model.nativeLabels.ports[portID] { draft = existing }
            else {
                draft.connectionTitle = String((displayName ?? "显示器").prefix(80))
                draft.connectorType = String(portType.prefix(40))
            }
        }
    }
}
