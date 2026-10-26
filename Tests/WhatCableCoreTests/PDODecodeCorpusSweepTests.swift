import Foundation
import Testing
@testable import WhatCableCore

/// Corpus-replay sweep for `PDO.decode(rawValue:)`
/// (`Sources/WhatCableCore/Port/PortDiagnostics.swift`).
///
/// `PDODecodingTests.swift` already proves the bit-layout logic against
/// hand-built synthetic raw values, one per PDO type/subtype (Tables 6.11
/// through 6.16 of the USB-PD spec). This file replays every real PDO raw
/// value the customer-probe corpus contains through the same entry point, and
/// checks two things a synthetic-only suite can't:
///
/// 1. Real silicon never emits a raw value that decodes to something with an
///    out-of-range voltage/current/power -- i.e. `PDO.decode` never silently
///    manufactures a nonsense reading from a raw value nobody hand-picked.
/// 2. The decoded case's type (fixed / battery / variable / one of the three
///    APDO subtypes) agrees with an INDEPENDENT re-derivation of the same two
///    type-selector bits (`rawValue >> 30`) and, for APDOs, the subtype bits
///    (`rawValue >> 28`) written fresh in this file rather than copied from
///    `PDO.decode`'s own switch. A regression that flips a shift amount or a
///    mask in the production switch would keep passing its own synthetic
///    unit tests (which were written against the same possibly-buggy mental
///    model) but would disagree with this file's separately-written
///    re-derivation on any real value that exercises the changed bits.
///
/// Source: probe 19 (`19_pdo_decode_and_usb3_watch`), whose `PDO[N] = 0xHEX`
/// lines are literally the `PortControllerInfo` raw PDO words the app itself
/// decodes at runtime (see `PowerService` / `PortDiagnosticsWatcher`).
@Suite("PDO.decode: corpus sweep")
struct PDODecodeCorpusSweepTests {

    private static let probeRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WhatCableCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("research/customer-probes")
    }()

    private static func allFolders() -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: probeRoot.path) else { return [] }
        return entries.filter { entry in
            var isDir: ObjCBool = false
            let path = probeRoot.appendingPathComponent(entry).path
            FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            return isDir.boolValue
        }.sorted()
    }

    private struct RawPDO {
        let folder: String
        let raw: UInt32
    }

    /// Every `PDO[N] = 0xHEX` raw value in probe 19 across the whole corpus.
    /// Deliberately does NOT also parse the `USB HVC Menu` lines further down
    /// the same probe (`[0] 5000mV / 3000mA = 15.0W`): those are the
    /// charger's already-decoded HVC menu, not a raw PDO word, so they are
    /// not inputs to `PDO.decode`.
    private static let rawPDOs: [RawPDO] = {
        guard let re = try? NSRegularExpression(pattern: #"PDO\[\d+\] = (0x[0-9a-fA-F]+)"#) else { return [] }
        var result: [RawPDO] = []
        for folder in allFolders() {
            let url = probeRoot.appendingPathComponent(folder).appendingPathComponent("19_pdo_decode_and_usb3_watch.json")
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = obj["output"] as? String
            else { continue }

            let matches = re.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for m in matches {
                guard let r = Range(m.range(at: 1), in: text),
                      let value = UInt32(text[r].dropFirst(2), radix: 16)
                else { continue }
                result.append(RawPDO(folder: folder, raw: value))
            }
        }
        return result
    }()

    // MARK: - Independent type re-derivation
    //
    // Written fresh from the USB-PD spec tables, not copied from
    // `PDO.decode`'s switch, so a shift/mask regression in production can't
    // also be baked into this check.

    private enum ExpectedKind: Equatable, CustomStringConvertible {
        case fixed, battery, variable, pps, eprAvs, sprAvs, invalidAPDOFallback

        var description: String {
            switch self {
            case .fixed: return "fixed"
            case .battery: return "battery"
            case .variable: return "variable"
            case .pps: return "pps"
            case .eprAvs: return "eprAvs"
            case .sprAvs: return "sprAvs"
            case .invalidAPDOFallback: return "invalidAPDOFallback"
            }
        }
    }

    private static func expectedKind(_ raw: UInt32) -> ExpectedKind {
        let typeBits = (raw >> 30) & 0x3
        switch typeBits {
        case 0: return .fixed
        case 1: return .battery
        case 2: return .variable
        default:
            let subtypeBits = (raw >> 28) & 0x3
            switch subtypeBits {
            case 0: return .pps
            case 1: return .eprAvs
            case 2: return .sprAvs
            default: return .invalidAPDOFallback
            }
        }
    }

    private static func actualKind(_ pdo: PDO) -> ExpectedKind {
        switch pdo {
        case .fixed: return .fixed
        case .battery: return .battery
        case .variable: return .variable
        case .pps: return .pps
        case .eprAvs: return .eprAvs
        case .sprAvs: return .sprAvs
        }
    }

    // MARK: - Coverage floor
    //
    // Measured directly against the corpus snapshot at the time this sweep
    // was written (410 folders, full raw corpus hard-linked into this
    // worktree): 2293 raw `PDO[N] = 0xHEX` lines across 287 folders.
    // Floor = 85% of 2293, rounded down: 2293 * 0.85 = 1949.05 -> 1949.
    //
    // Two-tier reality: probe 19 is gitignored raw data, but it is NOT
    // entirely absent on a fresh clone -- 15 folders carry a committed probe-19
    // fixture (tracked for other tests, e.g. `TransportWatcherSweepTests`-style
    // sweeps), so `rawPDOs` is never empty even on a fresh clone. A plain
    // "is it empty" guard would therefore let the coverage-floor assertion
    // below run against only ~15 folders' worth of PDOs and fail. The real
    // gate has to be a folder-count THRESHOLD that distinguishes "just the
    // tracked fixtures" (15 folders) from "the full raw corpus is present"
    // (287 folders): `fullRawCorpusThreshold` sits well above the former and
    // well below the latter.
    private static let coverageFloor = 1949
    private static let fullRawCorpusThreshold = 50

    /// True when at least one probe-19 fixture is on disk, tracked or not.
    /// Used to gate the per-value invariant tests below, which have no floor
    /// to satisfy and are worth running even against the small tracked-only
    /// fixture set.
    private static func hasRawProbeFiles() -> Bool {
        !rawPDOs.isEmpty
    }

    /// True only when the full raw corpus (not just the tracked fixture
    /// subset) is present. Used to gate the coverage-floor assertion, which
    /// makes a claim about the FULL corpus and must skip rather than fail
    /// when only the small tracked set is available.
    private static func hasFullRawCorpus() -> Bool {
        Set(rawPDOs.map(\.folder)).count >= fullRawCorpusThreshold
    }

    // MARK: - Tests

    @Test("Coverage: the corpus has enough raw PDO words to exercise PDO.decode")
    func coverageFloorHolds() {
        guard Self.hasFullRawCorpus() else { return }
        #expect(Self.rawPDOs.count >= Self.coverageFloor,
            "Expected at least \(Self.coverageFloor) raw PDO words (85% of the 2293 counted when this sweep was written); found \(Self.rawPDOs.count). A drop this large means the corpus shrank or the parsing regressed, not normal noise.")
    }

    @Test("No crash / type agreement: PDO.decode's case matches an independent bit re-derivation")
    func decodedTypeMatchesIndependentBitCheck() {
        guard Self.hasRawProbeFiles() else { return }
        var examined = 0
        var mismatches: [String] = []
        for entry in Self.rawPDOs {
            let pdo = PDO.decode(rawValue: entry.raw)
            examined += 1
            let expected = Self.expectedKind(entry.raw)
            let actual = Self.actualKind(pdo)
            // The spec-invalid APDO subtype (11) is explicitly handled by
            // production as a PPS-layout fallback (see the source comment:
            // "Subtype 11 is invalid per spec; fall back to PPS layout").
            // Treat that fallback as agreeing with an independently-expected
            // .invalidAPDOFallback, rather than flagging every occurrence as
            // a mismatch against .pps.
            if expected == .invalidAPDOFallback {
                if actual != .pps {
                    mismatches.append("\(entry.folder): raw 0x\(String(entry.raw, radix: 16)) expected PPS-fallback for invalid APDO subtype 11, got \(actual)")
                }
                continue
            }
            if actual != expected {
                mismatches.append("\(entry.folder): raw 0x\(String(entry.raw, radix: 16)) expected \(expected), decoded as \(actual)")
            }
        }
        #expect(mismatches.isEmpty,
            "\(mismatches.count) real corpus PDO(s) decoded to a different type than an independent bit re-derivation expects:\n\(mismatches.prefix(10).joined(separator: "\n"))")
        #expect(examined == Self.rawPDOs.count)
    }

    @Test("Physical bounds: decoded voltage/current/power never exceed the field's own bit width")
    func decodedValuesStayWithinFieldBounds() {
        guard Self.hasRawProbeFiles() else { return }
        var violations: [String] = []
        for entry in Self.rawPDOs {
            let pdo = PDO.decode(rawValue: entry.raw)
            switch pdo {
            case .fixed(let voltage, let maxCurrent):
                // 10-bit field * 50mV max = 1023 * 50 = 51150mV;
                // 10-bit field * 10mA max = 1023 * 10 = 10230mA.
                if !(0...51150).contains(voltage) || !(0...10230).contains(maxCurrent) {
                    violations.append("\(entry.folder): fixed voltage=\(voltage) current=\(maxCurrent) out of field bounds")
                }
            case .battery(let minV, let maxV, let maxPower):
                // 10-bit fields * 50mV; 10-bit power field * 250mW max = 255750mW.
                if !(0...51150).contains(minV) || !(0...51150).contains(maxV) || !(0...255750).contains(maxPower) {
                    violations.append("\(entry.folder): battery minV=\(minV) maxV=\(maxV) maxPower=\(maxPower) out of field bounds")
                }
            case .variable(let minV, let maxV, let maxCurrent):
                if !(0...51150).contains(minV) || !(0...51150).contains(maxV) || !(0...10230).contains(maxCurrent) {
                    violations.append("\(entry.folder): variable minV=\(minV) maxV=\(maxV) current=\(maxCurrent) out of field bounds")
                }
            case .pps(let minV, let maxV, let maxCurrent):
                // 8-bit voltage fields * 100mV max = 25500mV;
                // 7-bit current field * 50mA max = 6350mA.
                if !(0...25500).contains(minV) || !(0...25500).contains(maxV) || !(0...6350).contains(maxCurrent) {
                    violations.append("\(entry.folder): pps minV=\(minV) maxV=\(maxV) current=\(maxCurrent) out of field bounds")
                }
            case .eprAvs(let minV, let maxV, let pdp):
                // min voltage 8 bits * 100mV = 25500mV; max voltage 9 bits *
                // 100mV = 51100mV; PDP 8 bits * 1000mW = 255000mW.
                if !(0...25500).contains(minV) || !(0...51100).contains(maxV) || !(0...255000).contains(pdp) {
                    violations.append("\(entry.folder): eprAvs minV=\(minV) maxV=\(maxV) pdp=\(pdp) out of field bounds")
                }
            case .sprAvs(let cur15V, let cur20V):
                // 10-bit current fields * 10mA max = 10230mA.
                if !(0...10230).contains(cur15V) || !(0...10230).contains(cur20V) {
                    violations.append("\(entry.folder): sprAvs cur15V=\(cur15V) cur20V=\(cur20V) out of field bounds")
                }
            }
        }
        #expect(violations.isEmpty,
            "\(violations.count) real corpus PDO(s) decoded outside their field's representable bounds (should be structurally impossible):\n\(violations.prefix(10).joined(separator: "\n"))")
    }
}
