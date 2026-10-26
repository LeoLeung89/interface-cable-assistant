import Foundation
import Testing
@testable import WhatCableCore

/// Replay test for the USB device-tree walk (`USBDeviceNode.buildTree`, which
/// nests devices via `USBDevice.parentLocationID`) against real probe-38
/// `usb_device_tree` captures from the customer-probe corpus.
///
/// Two parts:
///
/// 1. **Anchored fixture** (`m3pro_macos26.5.1_h`): a CalDigit TS3-class dock
///    with two StarTech hubs, a Genesys hub, and a Wacom display hub fanning
///    out three levels deep. Its probe 38 is the one tracked in git (see the
///    `.gitignore` negation), so this part runs in CI on a fresh clone. It
///    asserts the exact nesting the probe's IOKit ancestor walk recorded.
/// 2. **Corpus sweep**: every folder that has a probe 38 on disk is run through
///    the same builder, asserting the core invariant that the walk loses no
///    device (a flattened tree has exactly as many nodes as input devices).
///    Folders without probe 38 (gitignored; absent on a fresh clone) are
///    skipped, mirroring the other corpus-replay sweeps.
struct Probe38TreeWalkTests {
    // MARK: - Probe root (repo tree, same resolution as the other sweeps)

    private static let probeRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WhatCableCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("research/customer-probes")
    }()

    // MARK: - Parsing

    /// Parse "--- Device[N] ---" blocks from probe 38 into `USBDevice` objects.
    /// Only the fields the tree walk needs are filled (locationID drives the
    /// nesting; vid/pid/name/class are for assertions and readable failures).
    static func parse(_ text: String) -> [USBDevice] {
        text.components(separatedBy: "--- Device[").dropFirst().compactMap { block in
            func value(_ key: String) -> String? {
                for line in block.split(separator: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    // Match "key = ..." exactly, so "locationID" does not also
                    // catch a longer key that happens to start the same way.
                    guard trimmed.hasPrefix(key),
                          trimmed.dropFirst(key.count).first == " " || trimmed.dropFirst(key.count).first == "=",
                          let eq = trimmed.firstIndex(of: "=")
                    else { continue }
                    return trimmed[trimmed.index(after: eq)...]
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
                return nil
            }
            // The probe emits IDs as hex with a `0x` prefix (idVendor = 0x451)
            // but class/speed as plain decimal (bDeviceClass = 17), so the two
            // are parsed differently: `hex()` for IDs and locationID, base-10
            // `UInt8.init` for class/speed below.
            func hex(_ key: String) -> UInt64? {
                guard var raw = value(key) else { return nil }
                if raw.hasPrefix("0x") || raw.hasPrefix("0X") { raw = String(raw.dropFirst(2)) }
                return UInt64(raw, radix: 16)
            }
            guard let loc = hex("locationID").map({ UInt32(truncatingIfNeeded: $0) }) else { return nil }
            return USBDevice(
                id: UInt64(loc),
                locationID: loc,
                vendorID: hex("idVendor").map { UInt16(truncatingIfNeeded: $0) } ?? 0,
                productID: hex("idProduct").map { UInt16(truncatingIfNeeded: $0) } ?? 0,
                vendorName: value("USB Vendor Name"),
                productName: value("USB Product Name"),
                serialNumber: nil,
                usbVersion: nil,
                speedRaw: value("Device Speed").flatMap { UInt8($0) },
                busPowerMA: nil,
                currentMA: nil,
                deviceClass: value("bDeviceClass").flatMap { UInt8($0) },
                rawProperties: [:]
            )
        }
    }

    private static func loadProbe38(folder: String) -> String? {
        let url = probeRoot.appendingPathComponent(folder).appendingPathComponent("38_usb_device_tree.json")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = root["output"] as? String
        else { return nil }
        return text
    }

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

    /// locationID -> depth, from the flattened tree.
    private static func depthByLocation(_ devices: [USBDevice]) -> [UInt32: Int] {
        var map: [UInt32: Int] = [:]
        for node in USBDeviceNode.flatten(USBDeviceNode.buildTree(from: devices)) {
            map[node.device.locationID] = node.depth
        }
        return map
    }

    // MARK: - parentLocationID heuristic (unit anchors)

    @Test("parentLocationID clears the lowest non-zero hub nibble")
    func parentResolution() {
        // StarTech 3.1 hub nests under the dock's TI hub.
        #expect(USBDevice.parentLocationID(0x2212_0000) == 0x2210_0000)
        // The BRIO webcam nests under the StarTech hub.
        #expect(USBDevice.parentLocationID(0x2212_2000) == 0x2212_0000)
        // A device directly on a controller root has no USB parent.
        #expect(USBDevice.parentLocationID(0x2020_0000) == nil)
    }

    // MARK: - Anchored fixture (tracked probe 38, runs in CI)

    @Test("m3pro_macos26.5.1_h: tree walk reproduces the recorded dock topology")
    func anchoredFixture() throws {
        // The public mirror strips research/ entirely (see .public-exclude), so
        // skip there rather than fail. In this repo research/ always exists and
        // the probe-38 fixture below is tracked, so the assertions run.
        guard FileManager.default.fileExists(atPath: Self.probeRoot.path) else { return }
        let text = try #require(
            Self.loadProbe38(folder: "m3pro_macos26.5.1_h"),
            "tracked probe-38 fixture must be present")
        let devices = Self.parse(text)
        // #require, not #expect: if the parser regressed, abort here rather than
        // run the topology assertions against a half-parsed device list.
        try #require(devices.count == 18)

        let tree = USBDeviceNode.buildTree(from: devices)
        let flat = USBDeviceNode.flatten(tree)

        // No device is lost in the walk.
        #expect(flat.count == devices.count)
        // Five controller-root devices sit at the top level.
        #expect(tree.count == 5)

        // Parent-child *identity*, not just depth. Depth alone cannot catch a
        // wrong-parent regression where two same-depth hubs swap children
        // (parentLocationID returning a different existing parent), so assert
        // the actual child locationIDs of each branch point.
        let tiHub3 = try #require(tree.first { $0.device.locationID == 0x2210_0000 })
        #expect(tiHub3.children.map(\.device.locationID) == [0x2212_0000])   // StarTech 3.1 hub
        let starHub3 = try #require(tiHub3.children.first)
        #expect(starHub3.children.map(\.device.locationID) == [0x2212_2000]) // Logitech BRIO

        let tiHub2 = try #require(tree.first { $0.device.locationID == 0x2230_0000 })
        #expect(tiHub2.children.map(\.device.locationID)
                == [0x2232_0000, 0x2234_0000, 0x2235_0000, 0x2236_0000])
        // ^ StarTech 2.0 hub, Genesys hub, a bare TI device, and the Billboard
        //   device (0x2236_0000, asserted by depth below).

        // Leaf-side hubs: assert each one's own children too. Without this a
        // sibling misfiled under the wrong hub at this level would still leave
        // the total device count and max depth unchanged, so the checks above
        // could not catch it.
        let starHub2 = try #require(tiHub2.children.first { $0.device.locationID == 0x2232_0000 })
        #expect(starHub2.children.map(\.device.locationID)
                == [0x2232_1000, 0x2232_3000, 0x2232_4000])   // incl. Magic Keyboard (0x2232_3000)
        let genesysHub = try #require(tiHub2.children.first { $0.device.locationID == 0x2234_0000 })
        #expect(genesysHub.children.map(\.device.locationID) == [0x2234_1000, 0x2234_3000])
        let wacomHub = try #require(tree.first { $0.device.locationID == 0x2320_0000 })
        #expect(wacomHub.children.map(\.device.locationID) == [0x2322_0000, 0x2325_0000])

        let depth = Self.depthByLocation(devices)
        #expect(depth[0x2212_2000] == 2)   // BRIO, three levels deep
        #expect(depth[0x2232_3000] == 2)   // Magic Keyboard, under StarTech 2.0 hub
        // The Billboard device (bDeviceClass 0x11) hangs off the second TI hub.
        #expect(depth[0x2236_0000] == 1)
        // The tree is exactly three levels deep (0..2): no run-away nesting.
        #expect((depth.values.max() ?? 0) == 2)
    }

    // MARK: - Corpus sweep (best-effort; skips folders without probe 38)

    @Test("Corpus sweep: probe-38 tree walk loses no device")
    func corpusSweep() {
        // Skip on the public mirror (research/ stripped); see anchoredFixture.
        guard FileManager.default.fileExists(atPath: Self.probeRoot.path) else { return }
        var swept = 0
        for folder in Self.allFolders() {
            guard let text = Self.loadProbe38(folder: folder) else { continue }
            let devices = Self.parse(text)
            guard !devices.isEmpty else { continue }
            swept += 1
            let flat = USBDeviceNode.flatten(USBDeviceNode.buildTree(from: devices))
            #expect(flat.count == devices.count,
                    "device lost building tree for \(folder): \(devices.count) in, \(flat.count) out")
            // Falsifiable depth bound: a parentLocationID cycle or runaway
            // nesting would blow past this (real USB topologies are <=7 hubs).
            #expect(flat.allSatisfy { $0.depth <= 8 },
                    "implausibly deep nesting in \(folder)")
        }
        print("[Probe38Sweep] swept \(swept) folders with probe 38")
        // The tracked m3pro fixture guarantees at least one folder; a zero here
        // means the path resolution broke and the sweep silently did nothing.
        #expect(swept >= 1)
    }
}
