import Foundation
import Testing

/// Corpus-replay tests for probe 41 (`41_class_discovery`), the discovery probe.
///
/// Probe 41 is the only probe that matches nothing. It walks the whole
/// IOService plane and records each class with the ancestry and owning kext the
/// kernel reports for it, so a class nobody wrote down still shows up. That
/// makes its OUTPUT FORMAT load-bearing in a way a normal probe's is not: the
/// class census in `inspect-probe.py` parses these rows to diff against
/// `class-baseline.json`, and a silent format drift would show up as "no new
/// classes" forever rather than as an error.
///
/// These tests replay the real captures on disk. Probe 41 is gitignored raw, so
/// a fresh clone has none and every test here skips: that is why each one
/// asserts against the count it actually found rather than a fixed floor, and
/// why the coverage test states plainly when it found nothing.
@Suite("Probe 41: class discovery corpus replay")
struct ClassDiscoveryCorpusTests {

    private static let probeRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WhatCableCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("research/customer-probes")
    }()

    private struct Capture {
        let folder: String
        let nodes: Int
        let declaredClasses: Int
        let stale: Bool
        let overflow: Bool
        let rows: [(cls: String, nodes: Int, kext: String, ancestry: String)]
    }

    private static func loadCaptures() -> [Capture] {
        guard let folders = try? FileManager.default.contentsOfDirectory(atPath: probeRoot.path)
        else { return [] }
        var out: [Capture] = []
        for folder in folders.sorted() {
            let url = probeRoot.appendingPathComponent("\(folder)/41_class_discovery.json")
            guard let data = try? Data(contentsOf: url) else { continue }  // absent: normal
            // A file that EXISTS but has no usable `output` is corrupt, not
            // absent, and silently skipping it would let the whole suite report
            // "no captures on disk" while a broken file sat there. Absent and
            // corrupt are different facts; only the first is normal.
            guard let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = doc["output"] as? String
            else {
                Issue.record("\(folder)/41_class_discovery.json exists but has no usable 'output' string")
                continue
            }

            func header(_ key: String) -> Int? {
                for line in text.split(separator: "\n") where line.hasPrefix("\(key)=") {
                    return Int(line.dropFirst(key.count + 1).prefix { $0.isNumber })
                }
                return nil
            }
            var rows: [(String, Int, String, String)] = []
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let parts = line.components(separatedBy: "\t")
                guard parts.count == 4, parts[0] != "CLASS", let n = Int(parts[1]) else { continue }
                rows.append((parts[0], n, parts[2], parts[3]))
            }
            out.append(Capture(
                folder: folder,
                nodes: header("nodes") ?? -1,
                declaredClasses: header("classes") ?? -1,
                stale: (header("iterator_stale") ?? 0) != 0,
                overflow: (header("class_table_overflow") ?? 0) != 0,
                rows: rows.map { (cls: $0.0, nodes: $0.1, kext: $0.2, ancestry: $0.3) }
            ))
        }
        return out
    }

    @Test("Probe 41: the declared class count matches the rows actually emitted")
    func declaredCountMatchesRows() {
        let captures = Self.loadCaptures()
        guard !captures.isEmpty else { return }
        for c in captures {
            // The probe prints `classes=N` in its header and then N rows. If
            // those disagree, either the table overflowed (which it reports
            // separately) or output was truncated, and either way the capture
            // is not the census it appears to be.
            #expect(c.rows.count == c.declaredClasses,
                "\(c.folder): header says \(c.declaredClasses) classes, \(c.rows.count) rows parsed")
            #expect(c.overflow == false,
                "\(c.folder): class table overflowed; the capture is incomplete")
        }
    }

    @Test("Probe 41: every row has a class name and a plausible node count")
    func rowsAreWellFormed() {
        let captures = Self.loadCaptures()
        guard !captures.isEmpty else { return }
        for c in captures {
            for row in c.rows {
                #expect(!row.cls.isEmpty, "\(c.folder): empty class name")
                #expect(row.nodes >= 1,
                    "\(c.folder): \(row.cls) reports \(row.nodes) nodes; a listed class must have at least one")
            }
            // Node count is the sum over classes, so it can never be below the
            // number of distinct classes.
            #expect(c.nodes >= c.rows.count,
                "\(c.folder): \(c.nodes) nodes for \(c.rows.count) classes is impossible")
        }
    }

    @Test("Probe 41: ancestry chains terminate at OSObject, or are explicitly absent")
    func ancestryChainsAreRooted() {
        let captures = Self.loadCaptures()
        guard !captures.isEmpty else { return }
        for c in captures {
            for row in c.rows where row.ancestry != "-" {
                // The kernel's OSMetaClass hierarchy roots at OSObject. A chain
                // that stops anywhere else means it was cut short, and the probe
                // marks that case explicitly rather than silently.
                let rooted = row.ancestry.hasSuffix("OSObject")
                    || row.ancestry.contains("<TRUNCATED")
                #expect(rooted,
                    "\(c.folder): \(row.cls) ancestry does not reach OSObject and is not marked truncated: \(row.ancestry)")
            }
        }
    }

    @Test("Probe 41: a stale capture is flagged, never presented as complete")
    func staleCapturesAreFlagged() {
        let captures = Self.loadCaptures()
        guard !captures.isEmpty else { return }
        // Not an assertion that no capture is stale (the registry genuinely can
        // change mid-walk); an assertion that we can always TELL. Anything
        // consuming these captures has to exclude the stale ones, so the flag
        // must survive parsing.
        for c in captures {
            #expect(c.nodes >= 0, "\(c.folder): header did not parse, so `stale` cannot be trusted either")
        }
        let stale = captures.filter(\.stale)
        if !stale.isEmpty {
            print("[ClassDiscovery] \(stale.count) stale capture(s), excluded from any census: \(stale.map(\.folder))")
        }
    }

    @Test("Coverage: report how much probe-41 data this run actually saw")
    func coverageReport() {
        let captures = Self.loadCaptures()
        guard !captures.isEmpty else {
            // Stated, not silent. Probe 41 raw is gitignored, so a fresh clone
            // legitimately has none and these tests are vacuous there. Saying so
            // stops a clean run being mistaken for a validated one.
            print("[ClassDiscovery] no probe-41 captures on disk; every test in this suite was vacuous")
            return
        }
        let total = captures.reduce(0) { $0 + $1.rows.count }
        print("[ClassDiscovery] \(captures.count) capture(s), \(total) class rows, "
            + "\(captures.filter(\.stale).count) stale")
    }
}
