import WhatCableCore

/// Suggestions distinguish measured device identity, inferred connector
/// arrangement and cable declarations. Live link speed is deliberately absent.
struct LabConnectionSuggestions {
    let title: String
    let kind: String
    let maximum: String
    let explanation: String

    init(displayName: String?, accessoryName: String?, hasDisplay: Bool,
         hasUSBDevices: Bool, isThunderbolt: Bool, declaredSpeed: PDVDO.CableSpeed?) {
        title = [displayName, accessoryName].compactMap { value in
            value.flatMap { $0.isEmpty ? nil : String($0.prefix(80)) }
        }.first ?? (hasDisplay ? "显示器" : isThunderbolt ? "Thunderbolt 设备" : hasUSBDevices ? "USB 设备" : "已连接设备")
        if isThunderbolt { kind = "Thunderbolt / USB-C" }
        else if hasDisplay { kind = hasUSBDevices ? "USB-C（建议）" : "USB-C 转 DP（建议）" }
        else { kind = "USB-C" }
        switch declaredSpeed {
        case .usb20: maximum = "e-marker：480 Mbps"
        case .usb32Gen1: maximum = "e-marker：5 Gbps"
        case .usb32Gen2: maximum = "e-marker：10 Gbps 等级"
        // Encoding 3 differs between PD 3.0 and 3.1; do not turn the
        // upstream class label into an unambiguous cable maximum.
        case .usb4Gen3: maximum = "e-marker：20/40 Gbps 等级"
        case .usb4Gen4: maximum = "e-marker：80 Gbps 等级"
        case nil: maximum = ""
        }
        let source = declaredSpeed == nil
            ? "未读到线缆 e-marker，最大规格未知，不能从当前速度反推。"
            : "规格来自线缆 e-marker 声明，未作为实测或 DP 视频上限。"
        explanation = "名称来自已识别设备；带“建议”的接法根据显示与 USB 功能推测，不能仅凭这些信息确认线缆另一端的插头。" + source
    }
}
