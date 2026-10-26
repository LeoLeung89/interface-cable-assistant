import Testing
import Foundation
@testable import WhatCableDarwinBackend
@testable import WhatCableCore

/// Phase 2, item 2. Replays every `WinningPowerSourceOption` block in probe 17
/// through the real class-string parse.
///
/// The floor assertions matter more than the pass. A regex that matches
/// nothing returns a clean sweep, and this repo has been burned by exactly
/// that three times in one session. So the sweep asserts it FOUND blocks and
/// that it classified them, and a deliberate-break check proves it can go red.
///
/// WHAT THIS SWEEP CANNOT CHECK, and it is half the job. It validates block
/// FINDING, not Class READING. The corpus holds exactly one distinct `Class`
/// value across every block, so a reader that ignored the probe text
/// entirely and returned the expected string as a constant would pass this
/// sweep completely clean. That is inherent in the data, not a gap someone
/// forgot to close, and no amount of extra corpus work fixes it: there is no
/// second value in the corpus to tell a real parse from a hardcoded one.
/// Shown by PR #599's review gate.
///
/// The other half is covered by the companion unit test in this file,
/// ``failsClosedOnUnknownClass``, which feeds the classifier strings the
/// corpus does not contain and pins that they do NOT reach `.fixed`. That is
/// what proves the classifier is a function of its input rather than a
/// constant. Do not read a green sweep on its own as evidence the parse is
/// right; the two tests are only meaningful together.
@Suite("PowerSource supply kind corpus sweep")
struct PowerSourceSupplyKindCorpusSweepTests {

    @Test("Every winning option in the corpus carries a class string and parses as fixed")
    func everyWinningOptionParsesFixed() throws {
        let folders = CorpusPowerProbes.foldersWithProbe17()
        try #require(!folders.isEmpty, "corpus missing: link the private research corpus (link-research.sh)")

        var blocks = 0
        var fixed = 0
        var dashShapeBlocks = 0
        var equalsShapeBlocks = 0
        var missingClass: [String] = []
        var notFixed: [String] = []
        var rawMarkerTotal = 0
        var perFolderCountMismatch: [String] = []
        var perFolderShapeExcess: [String] = []

        for folder in folders {
            guard let text = CorpusPowerProbes.probe17Text(folder) else { continue }
            let found = CorpusPowerProbes.winningOptionClassStrings(in: text)

            // An independent tally of the SAME thing, computed here and
            // sharing no code with the reader: a plain substring count of the
            // block marker. See the "per-folder invariants" note below for
            // why this, and not a numeric band, is what actually pins the
            // reader.
            let rawMarkers = text.components(separatedBy: "WinningPowerSourceOption: {").count - 1
            rawMarkerTotal += rawMarkers
            if found.count != rawMarkers {
                perFolderCountMismatch.append("\(folder): \(rawMarkers) markers, \(found.count) blocks")
            }

            var folderDash = 0
            var folderEquals = 0
            for block in found {
                blocks += 1
                switch block.shape {
                case .dash: dashShapeBlocks += 1; folderDash += 1
                case .equals: equalsShapeBlocks += 1; folderEquals += 1
                case nil: break
                }
                guard let cls = block.classString else { missingClass.append(folder); continue }
                switch PowerSourceWatcher.supplyKind(fromOptionClass: cls) {
                case .fixed: fixed += 1
                case .nonFixed, .unknown: notFixed.append("\(folder): \(cls)")
                }
            }
            if folderDash > 1 || folderEquals > 2 {
                perFolderShapeExcess.append("\(folder): \(folderDash) dash, \(folderEquals) equals")
            }
        }

        // PER-FOLDER INVARIANTS. These, not the numeric bands below, are what
        // make this sweep hard to fool, and they are the part that does not
        // need re-measuring as the corpus grows.
        //
        // The bands were measured against the whole corpus, so they can only
        // ever say "the total looks about right", and PR #599's gate showed
        // how much room "about" left: duplicating every 4th dash block (165
        // extra) and dropping every 7th block (about 14%) BOTH passed the
        // previous bounds green. Reproduced here before changing anything,
        // by mutating `winningOptionClassStrings` and running the sweep.
        //
        // A per-folder invariant closes that, because both mutations change
        // the relationship between what a folder's text contains and what the
        // reader returned for it, no matter how many folders there are:
        //
        //  - block count against a raw marker tally. Measured 2026-09-03:
        //    the reader returns EXACTLY one block per
        //    `WinningPowerSourceOption: {` occurrence in every folder,
        //    zero exceptions. Any duplication or any drop breaks this, at any
        //    corpus size.
        //  - blocks per shape per folder. Measured: a
        //    folder yields 0 or 1 dash block (never 2), and 0, 1 or 2 equals
        //    blocks. A
        //    shape-specific double-count breaks this even if the reader also
        //    dropped blocks elsewhere and kept the total plausible.
        //
        // If a future probe genuinely starts printing two dash blocks in one
        // folder, this fails and the right response is to re-measure and
        // widen it. It is not a reason to delete it.
        #expect(perFolderCountMismatch.isEmpty, "reader disagreed with a raw marker count: \(perFolderCountMismatch.prefix(5))")
        #expect(blocks == rawMarkerTotal, "\(blocks) blocks against \(rawMarkerTotal) raw markers in the same text")
        #expect(perFolderShapeExcess.isEmpty, "more blocks of one shape in a folder than the corpus has ever shown: \(perFolderShapeExcess.prefix(5))")

        // Not-empty guard: a regex that matches nothing returns a clean sweep.
        // No corpus size, shape split or folder count is asserted: those move
        // with every ingest. The per-folder checks above (block count equals
        // an independent marker count, shape excess) are what catch a reader
        // that double-counts or drops blocks, at any corpus size.
        #expect(blocks > 0, "no winning-option blocks found; parser is probably broken")
        #expect(missingClass.isEmpty, "winning options with no Class key: \(missingClass.prefix(5))")
        #expect(notFixed.isEmpty, "winning options that did not parse as fixed: \(notFixed.prefix(5))")
        #expect(fixed == blocks)

        #expect(dashShapeBlocks + equalsShapeBlocks == blocks, "every block should be attributed to exactly one shape")
    }

    @Test("The parse fails closed on anything that is not the known fixed class")
    func failsClosedOnUnknownClass() {
        // No corpus machine has ever reported a non-fixed class, and no
        // active contract that resolves against its advertised PDO list is
        // augmented (re-derived 2026-09-03; the one non-fixed selection in the
        // corpus is Variable, on a losing port on `m1_macos26.5.2_af`, which
        // `PowerOption.SupplyKind` sets out in full). So we cannot know
        // what a PPS class string looks like. Anything unrecognised must not
        // reach `.fixed`. This is the deliberate-break check for the sweep
        // above: it proves the classifier can return something other than
        // `.fixed`, so a green sweep means the data is fixed rather than the
        // classifier being a constant.
        #expect(PowerSourceWatcher.supplyKind(fromOptionClass: "IOPortFeaturePowerSourceOptionAugmented") == .nonFixed)
        #expect(PowerSourceWatcher.supplyKind(fromOptionClass: "IOPortFeaturePowerSourceOptionBattery") == .nonFixed)
        #expect(PowerSourceWatcher.supplyKind(fromOptionClass: "SomethingElseEntirely") == .nonFixed)
        #expect(PowerSourceWatcher.supplyKind(fromOptionClass: "IOPortFeaturePowerSourceOptionFixed") == .fixed)
    }

    @Test("parseOption treats a present but non-string Class as reported, not absent")
    func parseOptionFailsClosedOnPresentNonStringClass() throws {
        // Finding 1, PR #599 gate (Codex, confidence 0.97). The old line was
        // `(dict["Class"] as? String).map(supplyKind(fromOptionClass:)) ?? .unknown`,
        // which cannot tell "the key is absent" from "the key is present but
        // holds something that does not cast to String" (an unexpected CF
        // type, or NSNull). Both landed on `.unknown`, the weaker branch that
        // falls back to the phase-1 voltage-tier proxy and ACCEPTS a contract
        // sitting at exactly 5/9/12/15/20 V. A malformed but definitely-present
        // Class value is positive evidence something was reported, so it must
        // classify as `.nonFixed`, never `.unknown`.
        //
        // An empty string is NOT one of those cases, and an earlier version of
        // this comment wrongly listed it as one. An empty string casts to
        // String perfectly well, so the old line ran it through
        // `supplyKind(fromOptionClass:)`, where it failed to equal the fixed
        // class and came out `.nonFixed`. It reaches `.nonFixed` under the new
        // code too, by the present-but-unreadable branch. Same verdict before
        // and after; measured both ways 2026-09-03. The behaviour this test
        // guards is the non-string case only.
        let malformed: [String: Any] = [
            "Voltage (mV)": NSNumber(value: 20_000),
            "Max Current (mA)": NSNumber(value: 4_700),
            "Class": NSNumber(value: 1),  // present, but not a string
        ]
        let winning = try #require(PowerSourceWatcher.parseOption(malformed))
        #expect(winning.supplyKind == .nonFixed)

        // End to end: at 20 V, a standard SPR tier, this must NOT resolve a
        // charging input. Under the old code it would have: a malformed
        // Class fell to `.unknown`, and `.unknown` at 20 V passes the tier
        // proxy.
        let source = PowerSource(
            id: 1, name: "USB-PD", parentPortType: 0x2, parentPortNumber: 4,
            options: [winning], winning: winning, hpmControllerUUID: nil
        )
        #expect(ChargingInputResolver.fingerprint(
            sources: [source], batteryInstalled: true, externalConnected: true, chargerAttached: true
        ) == nil)
    }
}
