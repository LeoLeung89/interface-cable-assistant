import Foundation
import Testing
@testable import WhatCableCore

/// issue #181, second corpus sweep: does the USB3 corroboration gate hold
/// on machines that predate macOS 26?
///
/// WHY THIS EXISTS. `USB3CorroborationCorpusSweepTests` joins devices to
/// ports through `UsbIOPort`, the registry path macOS publishes on the
/// XHCI controller. That field does not exist before macOS 26. Measured
/// on the corpus: every pre-26 folder examined carries zero real
/// `UsbIOPort` entries while still capturing between one and eight
/// SuperSpeed devices. So on those machines the first sweep's
/// "uncorroborated" verdict is a fact about its JOIN METHOD, not about
/// the port, and its assertion that no label should appear is
/// self-consistent but says nothing about what the shipping app does.
///
/// That mattered: the first sweep reported 23 uncorroborated ports, and
/// 16 of them turned out to be macOS 15 machines with a real SuperSpeed
/// drive plugged in (Samsung PSSD T7s and similar). If the app really
/// suppressed those, every macOS 15 user with a fast drive would lose
/// their speed line, which is a worse bug than the flash this PR fixes.
///
/// Production does not rely on `UsbIOPort` alone. `matchingDevices` falls
/// back to a BUS INDEX join, and that fallback is what carries pre-26
/// machines. This sweep models that fallback from the corpus and answers
/// the question the first sweep cannot.
///
/// Both sides of the fallback are reconstructed the way production
/// derives them, independently re-implemented here rather than shared
/// with the Darwin backend (which these tests cannot import):
///
/// - DEVICE side, mirroring `USBWatcher.classifyAncestry`: walk probe
///   38's recorded ancestor chain, and on reaching a native controller
///   (`AppleT<n>USBXHCI`) take the upper byte of ITS locationID
///   (`busIndex(fromLocationID:)` = `(loc >> 24) & 0xFF`); fall back to
///   the upper byte of the device's own locationID when the walk ends
///   without one. Tunnelled (`AppleUSBXHCITR`, dock controllers) and
///   Apple-embedded built-in controllers are excluded, exactly as
///   production excludes them from this fallback.
/// - PORT side: production reads the port's own ancestor registry name
///   (`hpm<N>` / `atc<N>` / `usb-drd<N>`). No probe captures the HPM
///   port's ancestor walk, so this uses probe 36's
///   `usb-c-port-number=K` map, which names the same indexed node for
///   each physical port.
///
/// The port-side model is the load-bearing assumption, so it is not
/// assumed: `busIndexModelAgreesWithUsbIOPort` validates it on the
/// machines where BOTH signals exist (macOS 26+), and only then is it
/// trusted on the machines where only one does.
@Suite("USB3 corroboration: bus-index fallback sweep (issue #181)")
struct USB3CorroborationBusIndexSweepTests {

    // MARK: - Probe access

    private static let probeRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("research/customer-probes")
    }()

    private static func allFolders() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: probeRoot.path))?
            .filter { entry in
                var isDir: ObjCBool = false
                FileManager.default.fileExists(
                    atPath: probeRoot.appendingPathComponent(entry).path, isDirectory: &isDir)
                return isDir.boolValue
            }
            .sorted() ?? []
    }

    private static func loadProbeText(folder: String, probe: String) -> String? {
        let url = probeRoot.appendingPathComponent(folder).appendingPathComponent("\(probe).json")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let text = root["output"] as? String
        else { return nil }
        return text
    }

    // MARK: - Probe 38: devices, with production's bus-index derivation

    private struct Device38 {
        let locationID: UInt32
        let speedRaw: UInt8?
        /// Port name from a `UsbIOPort` ancestor, when macOS published one.
        let usbIOPortName: String?
        /// Production's bus index, or nil when the device is one production
        /// never bus-matches (tunnelled or behind the Mac's own hub).
        let busIndex: Int?
        let isExcludedFromBusMatch: Bool
    }

    private static func hexValue(_ raw: String) -> UInt32? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("0x") { s = String(s.dropFirst(2)) }
        return UInt32(s, radix: 16)
    }

    /// `USBWatcher.busIndex(fromLocationID:)`, re-implemented.
    private static func busIndex(fromLocationID loc: UInt32) -> Int {
        Int((loc >> 24) & 0xFF)
    }

    private static func isNativeController(_ className: String) -> Bool {
        className.hasPrefix("AppleT") && className.hasSuffix("USBXHCI")
    }

    private static func isEmbeddedBuiltIn(_ className: String) -> Bool {
        className.hasPrefix("AppleEmbedded") && className.contains("USBXHCI")
    }

    private static func isTunnelController(_ className: String) -> Bool {
        // The native Thunderbolt tunnel controller, plus the third-party
        // XHCI classes a TB3 dock brings with it. Production's
        // `isThunderboltDockController` is broader; this covers the classes
        // that actually occur in the corpus, and anything it misses can only
        // ADD a device to the bus-matched set, which the validation tier
        // would catch as a disagreement.
        className == "AppleUSBXHCITR"
            || className.hasPrefix("AppleUSBXHCIFL")
            || className.hasPrefix("AppleASMediaUSBXHCI")
            || className.hasPrefix("AppleUSBXHCIAR")
    }

    private static func parseDevices38(_ text: String) -> [Device38] {
        var out: [Device38] = []
        for block in text.components(separatedBy: "--- Device[").dropFirst() {
            var locationID: UInt32?
            var speedRaw: UInt8?
            var usbIOPortName: String?
            var bus: Int?
            var excluded = false
            var reachedController = false

            for rawLine in block.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(rawLine)
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                if locationID == nil, trimmed.hasPrefix("locationID = ") {
                    locationID = hexValue(String(trimmed.dropFirst("locationID = ".count)))
                    continue
                }
                if speedRaw == nil, trimmed.hasPrefix("Device Speed = ") {
                    speedRaw = UInt8(trimmed.dropFirst("Device Speed = ".count)
                        .trimmingCharacters(in: .whitespaces))
                    continue
                }
                // Ancestor rows only, in recorded order (device -> controller).
                guard trimmed.hasPrefix("[") , let classRange = trimmed.range(of: "class=") else {
                    continue
                }
                if reachedController { continue }

                let afterClass = trimmed[classRange.upperBound...]
                let className = String(afterClass.prefix { !$0.isWhitespace })

                if usbIOPortName == nil, let r = trimmed.range(of: "UsbIOPort=") {
                    let value = String(trimmed[r.upperBound...]).prefix { !$0.isWhitespace }
                    if let last = value.split(separator: "/").last, last.hasPrefix("Port-") {
                        usbIOPortName = String(last)
                    }
                }

                if isTunnelController(className) {
                    excluded = true
                    reachedController = true
                    continue
                }
                if isEmbeddedBuiltIn(className) {
                    // Behind the Mac's own board hub: production flags it and
                    // the bus-index fallback skips it outright.
                    excluded = true
                    reachedController = true
                    continue
                }
                if isNativeController(className) {
                    if let r = trimmed.range(of: "locationID=") {
                        let value = String(trimmed[r.upperBound...]).prefix { !$0.isWhitespace }
                        if let loc = hexValue(String(value)) { bus = busIndex(fromLocationID: loc) }
                    }
                    reachedController = true
                    continue
                }
            }

            guard let locationID else { continue }
            // Production's caller-side fallback: no controller locationID
            // read means the device's own locationID supplies the bus.
            let resolvedBus = excluded ? nil : (bus ?? busIndex(fromLocationID: locationID))
            out.append(Device38(
                locationID: locationID,
                speedRaw: speedRaw,
                usbIOPortName: usbIOPortName,
                busIndex: resolvedBus,
                isExcludedFromBusMatch: excluded
            ))
        }
        return out
    }

    // MARK: - Probe 36: physical port -> bus index

    /// Bus indices from probe 36's node names, split two ways.
    ///
    /// `usbC` holds only nodes carrying a real `usb-c-port-number` (>= 1).
    /// `all` holds every indexed node, including those reporting the `-1`
    /// sentinel: a bus that exists but belongs to no USB-C connector (the
    /// internal hub / USB-A block on desktops). The first draft dropped the
    /// sentinel rows entirely and then flagged their devices as carrying a
    /// bus "no port owns", which was a hole in the model, not in the data.
    private struct BusMap {
        let usbC: Set<Int>
        let all: Set<Int>
    }

    private static func parsePortBusMap36(_ text: String) -> BusMap {
        var usbC: Set<Int> = []
        var all: Set<Int> = []
        for rawLine in text.split(separator: "\n") {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard let portRange = line.range(of: "usb-c-port-number=") else { continue }
            let nodeName = String(line.prefix { !$0.isWhitespace })
            var bus: Int?
            for prefix in ["hpm", "atc", "usb-drd"] where nodeName.hasPrefix(prefix) {
                let digits = nodeName.dropFirst(prefix.count).prefix { $0.isNumber }
                if let n = Int(digits) { bus = n; break }
            }
            guard let bus else { continue }
            all.insert(bus)
            let value = line[portRange.upperBound...].prefix { !$0.isWhitespace }
            if let portNumber = Int(value), portNumber >= 1 { usbC.insert(bus) }
        }
        return BusMap(usbC: usbC, all: all)
    }

    /// `usb-c-port-number` -> bus index, for the one test that compares
    /// the probe's port numbering against macOS's own `@N` naming.
    private static func parsePortNumberToBus36(_ text: String) -> [Int: Int] {
        var map: [Int: Int] = [:]
        for rawLine in text.split(separator: "\n") {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard let portRange = line.range(of: "usb-c-port-number=") else { continue }
            let value = line[portRange.upperBound...].prefix { !$0.isWhitespace }
            guard let portNumber = Int(value), portNumber >= 1 else { continue }
            let nodeName = String(line.prefix { !$0.isWhitespace })
            for prefix in ["hpm", "atc", "usb-drd"] where nodeName.hasPrefix(prefix) {
                let digits = nodeName.dropFirst(prefix.count).prefix { $0.isNumber }
                if let n = Int(digits), map[portNumber] == nil { map[portNumber] = n }
                break
            }
        }
        return map
    }

    // MARK: - Probe 01: active-USB3 ports

    private struct ProbePort {
        let serviceName: String
        let portNumber: Int

        func asAppleHPMInterface(busIndex: Int?) -> AppleHPMInterface {
            AppleHPMInterface(
                id: UInt64(portNumber),
                serviceName: serviceName,
                className: "AppleHPMInterfaceType10",
                portDescription: serviceName,
                portTypeDescription: "USB-C",
                portNumber: portNumber,
                connectionActive: true,
                activeCable: nil,
                opticalCable: nil,
                usbActive: nil,
                superSpeedActive: nil,
                usbModeType: nil,
                usbConnectString: nil,
                transportsSupported: ["USB3"],
                transportsActive: ["USB3"],
                transportsProvisioned: [],
                plugOrientation: nil,
                plugEventCount: nil,
                connectionCount: nil,
                overcurrentCount: nil,
                pinConfiguration: [:],
                powerCurrentLimits: [],
                firmwareVersion: nil,
                bootFlagsHex: nil,
                busIndex: busIndex,
                rawProperties: [:]
            )
        }
    }

    private static func loadActiveUSB3Ports(folder: String) -> [ProbePort] {
        guard let text = loadProbeText(folder: folder, probe: "01_walk_pd_tree") else { return [] }
        let rawChunks = text.components(separatedBy: "=== IOAccessoryManager[")
        guard rawChunks.count > 1 else { return [] }
        var ports: [ProbePort] = []
        for chunk in rawChunks.dropFirst() {
            guard let endOfHeader = chunk.range(of: "===\n") else { continue }
            let rest = chunk[endOfHeader.upperBound...]
            let body: Substring
            if let endRange = rest.range(of: "\n=== ") {
                body = rest[..<endRange.lowerBound]
            } else {
                body = rest
            }
            guard body.contains("PortTypeDescription"),
                  body.contains("ConnectionActive = true")
            else { continue }
            let serviceName = parseQuoted(String(body), key: "Description") ?? "Port-Unknown@0"
            let portNumber = parseInt(String(body), key: "PortNumber") ?? 0
            guard parseList(String(body), key: "TransportsActive").contains("USB3") else { continue }
            ports.append(ProbePort(serviceName: serviceName, portNumber: portNumber))
        }
        return ports
    }

    private static func parseQuoted(_ block: String, key: String) -> String? {
        let prefix = "    \(key) = \""
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(prefix) {
                let after = line.dropFirst(prefix.count)
                guard let closing = after.firstIndex(of: "\"") else { return nil }
                return String(after[..<closing])
            }
        }
        return nil
    }

    private static func parseInt(_ block: String, key: String) -> Int? {
        let prefix = "    \(key) = "
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(prefix) {
                return Int(line.dropFirst(prefix.count).prefix { $0.isNumber })
            }
        }
        return nil
    }

    /// Probe 01 renders lists as `Key = [\n  [0] "CC"\n  [1] "USB3"\n    ]`.
    /// Getting this wrong is not hypothetical: the first draft of this file
    /// expected a `(...)` shape, parsed every list as empty, and the sweep
    /// silently found ZERO candidate ports while still reporting green on
    /// its other assertions.
    private static func parseList(_ block: String, key: String) -> [String] {
        let opener = "    \(key) = ["
        guard let openRange = block.range(of: opener) else { return [] }
        let afterOpen = block[openRange.upperBound...]
        guard let close = afterOpen.range(of: "\n    ]") else { return [] }
        return afterOpen[..<close.lowerBound].split(separator: "\n").compactMap { line -> String? in
            guard let q1 = line.firstIndex(of: "\""),
                  let q2 = line.lastIndex(of: "\""), q1 != q2 else { return nil }
            return String(line[line.index(after: q1)..<q2])
        }
    }

    // MARK: - Tier A: what the port-side model can and cannot claim
    //
    // Probe 36's own header warns: "usb-c-port-number may differ from HPM
    // @N; compare, do not assume equal." It does differ. Measured here:
    // on `m1_macos26.5.1_k`, `usb-drd1` carries usb-c-port-number=1 while
    // macOS's own `UsbIOPort` names that device's port `Port-USB-C@2`.
    // Across the corpus the two labels disagree on 175 of 1864
    // cross-checkable devices.
    //
    // So this file does NOT claim to know which physical card a bus index
    // belongs to. It claims the weaker thing that is actually true and is
    // all the gate needs: each USB-C port owns exactly one bus index, and
    // a device's bus is owned by one of them. Whether the label lands on
    // card @1 or card @2 is a port-ATTRIBUTION question that predates this
    // PR and is unaffected by it; the gate only asks whether a real device
    // corroborates the port it joined.

    @Test("Every cross-checkable device's bus index is owned by exactly one USB-C port node")
    func busIndexIsOwnedByExactlyOnePort() {
        var checked = 0
        var orphans: [String] = []

        for folder in Self.allFolders() {
            guard let text38 = Self.loadProbeText(folder: folder, probe: "38_usb_device_tree"),
                  let text36 = Self.loadProbeText(folder: folder, probe: "36_xhci_port_map")
            else { continue }
            let map = Self.parsePortBusMap36(text36)
            guard !map.all.isEmpty else { continue }

            for device in Self.parseDevices38(text38) {
                guard device.usbIOPortName != nil, let bus = device.busIndex else { continue }
                checked += 1
                if !map.all.contains(bus) {
                    orphans.append("\(folder) loc 0x\(String(device.locationID, radix: 16)) bus \(bus) owned by no port")
                    continue
                }
            }
        }

        guard checked > 0 else {
            Issue.record("no machines publish both UsbIOPort and a probe 36 port map; raw corpus not fetched?")
            return
        }
        #expect(checked >= 500,
            "too few cross-checkable devices (\(checked)) for this to mean anything")
        #expect(orphans.isEmpty,
            "\(orphans.count) device(s) carry a bus index no USB-C port owns, so the bus model is incoherent: \(orphans.prefix(10))")
    }

    @Test("The probe's own warning holds: usb-c-port-number is NOT the HPM @N number")
    func portNumberingIsNotIdentity() {
        // Pinned deliberately. If a future macOS makes these agree, this
        // test goes red and someone re-reads this section rather than
        // quietly inheriting an assumption that was only ever true by
        // accident. It also documents WHY the sweep below asserts
        // existence rather than a specific card.
        var checked = 0
        var mismatches = 0
        for folder in Self.allFolders() {
            guard let text38 = Self.loadProbeText(folder: folder, probe: "38_usb_device_tree"),
                  let text36 = Self.loadProbeText(folder: folder, probe: "36_xhci_port_map")
            else { continue }
            let portBus = Self.parsePortNumberToBus36(text36)
            guard !portBus.isEmpty else { continue }
            for device in Self.parseDevices38(text38) {
                guard let named = device.usbIOPortName,
                      let bus = device.busIndex,
                      let atSuffix = named.split(separator: "@").last,
                      let namedPortNumber = Int(atSuffix)
                else { continue }
                let modelPorts = portBus.filter { $0.value == bus }.map(\.key)
                guard !modelPorts.isEmpty else { continue }
                checked += 1
                if !modelPorts.contains(namedPortNumber) { mismatches += 1 }
            }
        }
        guard checked > 0 else {
            Issue.record("raw corpus not fetched?")
            return
        }
        #expect(mismatches > 0,
            "usb-c-port-number now agrees with HPM @N on all \(checked) cross-checkable devices; the note above and the existence-only sweep below need revisiting")
    }

    // MARK: - Tier B: what the fallback actually does on pre-26 machines

    private struct PreModernMachine {
        let folder: String
        /// One representative active-USB3 port, used as the fixture the
        /// owning bus index is applied to.
        let port: ProbePort
        /// Bus indices owned by USB-C ports on this machine.
        let ownedBuses: Set<Int>
        let devices: [Device38]
    }

    private static func preModernMachines() -> [PreModernMachine] {
        var out: [PreModernMachine] = []
        for folder in allFolders() {
            guard let text38 = loadProbeText(folder: folder, probe: "38_usb_device_tree"),
                  let text36 = loadProbeText(folder: folder, probe: "36_xhci_port_map")
            else { continue }
            let parsed = parseDevices38(text38)
            // Pre-macOS-26 signature: devices captured, none named by a
            // UsbIOPort ancestor.
            guard !parsed.isEmpty, parsed.allSatisfy({ $0.usbIOPortName == nil }) else { continue }
            let map = parsePortBusMap36(text36)
            guard !map.usbC.isEmpty else { continue }
            guard let port = loadActiveUSB3Ports(folder: folder).first else { continue }
            out.append(PreModernMachine(
                folder: folder, port: port,
                ownedBuses: map.usbC, devices: parsed
            ))
        }
        return out
    }

    @Test("Pre-macOS-26: a real SuperSpeed device still corroborates its port through the bus-index fallback")
    func preModernSuperSpeedDevicesStillCorroborate() {
        let machines = Self.preModernMachines()
        guard !machines.isEmpty else {
            Issue.record("no pre-macOS-26 machines with probe 36 + probe 38 on disk; raw corpus not fetched?")
            return
        }

        var devicesChecked = 0
        var keptLabel = 0
        var lost: [String] = []

        for m in machines {
            for device in m.devices {
                guard (device.speedRaw ?? 0) >= 3,
                      !device.isExcludedFromBusMatch,
                      let bus = device.busIndex,
                      m.ownedBuses.contains(bus)
                else { continue }
                devicesChecked += 1

                // The port that owns this bus, whichever card that is (see
                // the Tier A note). Production derives the same busIndex
                // from the port's own registry ancestor, so this models the
                // real join rather than reproducing the probe's port
                // numbering.
                let port = m.port.asAppleHPMInterface(busIndex: bus)
                let usbDevice = USBDevice(
                    id: 1, locationID: device.locationID,
                    vendorID: 0, productID: 0,
                    vendorName: nil, productName: nil, serialNumber: nil,
                    usbVersion: nil, speedRaw: device.speedRaw,
                    busPowerMA: nil, currentMA: nil,
                    busIndex: bus,
                    controllerPortName: nil,   // the whole point: macOS published none
                    rawProperties: [:]
                )
                let matched = port.matchingDevices(from: [usbDevice])
                guard let portKey = port.portKey else {
                    Issue.record("fixture error: no portKey for \(m.folder)")
                    continue
                }
                let transport = USB3Transport(
                    id: 1, portKey: portKey, signaling: 2,
                    signalingDescription: "Gen 2", dataRole: "host",
                    transportRestricted: false
                )
                guard transport.canonicallyMatches(port: port) else {
                    Issue.record("fixture error: transport does not match \(m.folder)")
                    continue
                }
                let summary = PortSummary(port: port, devices: matched, usb3Transports: [transport])
                if summary.linkSpeed != nil {
                    keptLabel += 1
                } else {
                    lost.append("\(m.folder) loc 0x\(String(device.locationID, radix: 16)) bus \(bus)")
                }
            }
        }

        #expect(devicesChecked >= 10,
            "expected at least 10 real SuperSpeed devices on pre-macOS-26 machines to exercise the fallback; got \(devicesChecked). Below this the sweep is not testing the case it exists for.")
        #expect(lost.isEmpty,
            "\(lost.count) real SuperSpeed device(s) on pre-macOS-26 machines failed to corroborate their port, so those users would LOSE a legitimate speed line: \(lost.prefix(10))")
        #expect(keptLabel == devicesChecked)
    }

    @Test("The bus-index join is discriminating, not a blanket match")
    func busIndexJoinIsDiscriminating() {
        // A fallback that matched everything to everything would make the
        // sweep above pass while proving nothing. Prove the join rejects a
        // device whose bus belongs to a different port.
        let machines = Self.preModernMachines()
        guard let m = machines.first(where: { $0.ownedBuses.count > 1 }) else {
            Issue.record("no pre-macOS-26 machine with more than one USB-C bus on disk; raw corpus not fetched?")
            return
        }
        let buses = m.ownedBuses.sorted()
        let port = m.port.asAppleHPMInterface(busIndex: buses[0])
        let deviceOnOtherBus = USBDevice(
            id: 1, locationID: 0, vendorID: 0, productID: 0,
            vendorName: nil, productName: nil, serialNumber: nil,
            usbVersion: nil, speedRaw: 4,
            busPowerMA: nil, currentMA: nil,
            busIndex: buses[1],
            controllerPortName: nil,
            rawProperties: [:]
        )
        #expect(port.matchingDevices(from: [deviceOnOtherBus]).isEmpty,
            "a device on bus \(buses[1]) must not match a port on bus \(buses[0]); the join is matching indiscriminately")
    }
}
