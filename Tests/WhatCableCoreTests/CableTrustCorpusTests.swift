import Testing
import Foundation
@testable import WhatCableCore

/// Empirical guard: run every catalogued real cable from `data/known-cables.md`
/// through the trust engine and assert none of them trips **red**. A red on a
/// genuine, community-reported, working cable is a false positive, the one
/// outcome this app can't afford. The behavioural axis needs live link data
/// the corpus doesn't carry, so this validates the static red/amber/green
/// path, which is exactly where a false red would come from.
@Suite("Cable Trust corpus validation")
struct CableTrustCorpusTests {

    private struct Row {
        let context: String
        let vid: Int
        let pid: Int
        let cableVDO: UInt32?
        let issue: String
    }

    /// Locate data/known-cables.md from this test file's path (repo root is
    /// three levels up from Tests/WhatCableCoreTests/).
    private static func corpusURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WhatCableCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("data/known-cables.md")
    }

    private static func hex(_ cell: String) -> Int? {
        let s = cell.replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespaces)
        guard s.lowercased().hasPrefix("0x"), let v = Int(s.dropFirst(2), radix: 16) else { return nil }
        return v
    }

    private static func parseRows() -> [Row] {
        guard let text = try? String(contentsOf: corpusURL(), encoding: .utf8) else { return [] }
        var rows: [Row] = []
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("|"), !t.contains("---"), !t.contains("| VID |") else { continue }
            var body = t
            if body.hasSuffix("|") { body.removeLast() }
            if body.hasPrefix("|") { body.removeFirst() }
            let cells = body.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            // context | VID | PID | Cable VDO | Vendor | XID | Speed | Power | Type | Source
            guard cells.count >= 10, let vid = hex(cells[1]) else { continue }
            let pid = hex(cells[2]) ?? 0
            let vdo = hex(cells[3]).map { UInt32(truncatingIfNeeded: $0) }
            rows.append(Row(context: cells[0], vid: vid, pid: pid, cableVDO: vdo, issue: cells[cells.count - 1]))
        }
        return rows
    }

    /// Build an SOP' identity matching a corpus row. Mirrors the fixture in
    /// CableTrustReportTests: vendor/product set directly, VDO[3] is the raw
    /// cable VDO (omitted when the row has none, so no encoding is decoded).
    private func identity(_ row: Row) -> USBPDSOP {
        var vdos: [UInt32] = [(3 << 27) | UInt32(truncatingIfNeeded: row.vid), 0, UInt32(truncatingIfNeeded: row.pid) << 16]
        if let vdo = row.cableVDO { vdos.append(vdo) }
        return USBPDSOP(
            id: 1, endpoint: .sopPrime,
            parentPortType: 0, parentPortNumber: 0,
            vendorID: row.vid, productID: row.pid, bcdDevice: 0,
            vdos: vdos, specRevision: 3
        )
    }

    @Test("No catalogued real cable trips red")
    func noCorpusCableIsRed() {
        let rows = Self.parseRows()
        #expect(rows.count >= 50, "corpus parse looks wrong: only \(rows.count) rows")

        var green = 0, amber = 0
        var reds: [(Row, [String])] = []

        for row in rows {
            let id = identity(row)
            let report = CableTrustReport(identity: id)
            let trust = CableTrust(
                report: report,
                vendorRegistered: VendorDB.isRegistered(row.vid),
                dataLink: nil,             // corpus has no live link data
                negotiatedWatts: nil,
                ratedWatts: id.cableVDO?.maxWatts
            )
            switch trust.tier {
            case .green: green += 1
            case .amber: amber += 1
            case .red: reds.append((row, report.flags.map(\.code)))
            }
        }

        print("""

        ── Cable trust corpus validation ──────────────────────────
        cables tested: \(rows.count)
        static tiers:  green \(green)   amber \(amber)   red \(reds.count)
        Behaviour-first model: with no live link/PD data in the corpus
        there is nothing to confirm, so every cable should be amber.
        Green needs watched delivery; red needs corroborated non-delivery.
        """)
        if reds.isEmpty {
            print("RED: none — no catalogued real cable is flagged red. ✓")
        } else {
            print("RED cables (investigate each — false positive or genuine pattern):")
            for (row, codes) in reds {
                print("  • \(row.context) [\(row.issue)]  flags: \(codes.joined(separator: ", "))")
            }
        }
        print("───────────────────────────────────────────────────────────\n")

        // The corpus has no behavioural data, so the static path must not
        // confirm (no green) and must not convict (no red): all amber.
        #expect(reds.isEmpty, "\(reds.count) catalogued cable(s) tripped red")
        #expect(green == 0, "\(green) cable(s) went green with no behavioural data")
        #expect(amber == rows.count)
    }
}
