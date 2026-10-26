import Foundation
import Testing
@testable import WhatCableCore

/// Corpus-replay sweep for `BuiltInPortGrouping.parse` (issue #490): every
/// physical port node name macOS actually published across the corpus
/// (`UsbIOPort=.../Port-USB-A@1` tails in probe 38) must parse into a
/// (connector, number) pair, so no real machine's built-in device can fall
/// into the unattributed fallback because of a parser gap.
///
/// Raw probes are on-disk only (a fresh clone or worktree has just the
/// git-tracked fixtures), so the coverage floor only arms when the corpus is
/// actually present, same convention as the other corpus sweeps.
@Suite("BuiltInPortGrouping: corpus sweep")
struct BuiltInPortGroupingCorpusTests {

    private static let probeRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WhatCableCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("research/customer-probes")
    }()

    @Test("Every corpus UsbIOPort port node name parses")
    func corpusPortNodeNamesAllParse() throws {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(atPath: Self.probeRoot.path))?.sorted() ?? []

        var filesOnDisk = 0
        var filesDecoded = 0
        var namesSeen = 0
        var foldersWithUSBA = Set<String>()
        var distinctNames = Set<String>()

        for folder in folders {
            let url = Self.probeRoot.appendingPathComponent(folder)
                .appendingPathComponent("38_usb_device_tree.json")
            // Existence and decodability counted SEPARATELY: gating the floor
            // on post-decode success would let a decode regression disarm the
            // floor and false-pass (Codex review finding on the first cut).
            guard fm.fileExists(atPath: url.path) else { continue }
            filesOnDisk += 1
            guard let data = try? Data(contentsOf: url),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let text = root["output"] as? String
            else { continue }
            filesDecoded += 1

            for line in text.split(separator: "\n") where line.contains("UsbIOPort=") {
                guard let tail = line.split(separator: "/").last else { continue }
                let name = String(tail).trimmingCharacters(in: .whitespaces)
                guard name.hasPrefix("Port-") else { continue }
                namesSeen += 1
                distinctNames.insert(name)
                let parsed = BuiltInPortGrouping.parse(portNodeName: name)
                #expect(parsed != nil, "\(folder): unparsable port node \(name)")
                if parsed?.connector == "USB-A" { foldersWithUSBA.insert(folder) }
            }
        }

        print("[BuiltInPortGroupingSweep] \(filesOnDisk) probe-38 files (\(filesDecoded) decoded), \(namesSeen) port-node names, "
            + "\(distinctNames.count) distinct (\(distinctNames.sorted())), \(foldersWithUSBA.count) folders with USB-A")

        // Floor only when the on-disk corpus is present (100+ probe-38 files;
        // actual 597 as of 2026-08-09). Measured then: 21 folders publish a
        // Port-USB-A node (re-derived with an independent Python pass over
        // the raw text before being written here); floor at ~85% so the test
        // both proves the sweep found the known-present data and catches a
        // silent extraction regression.
        if filesOnDisk >= 100 {
            #expect(filesDecoded >= Int(Double(filesOnDisk) * 0.85),
                "corpus present (\(filesOnDisk) files) but only \(filesDecoded) decoded; loader regression?")
            #expect(foldersWithUSBA.count >= 18,
                "expected >= 18 folders with Port-USB-A nodes, found \(foldersWithUSBA.count)")
            #expect(namesSeen > 0, "corpus present but no port node names extracted")
        }
    }
}
