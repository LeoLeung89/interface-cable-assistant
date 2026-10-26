import Foundation
import Testing
@testable import WhatCableCore
@testable import WhatCableDarwinBackend

// MARK: - Issue #573 part 2: IOPortTransportStateCC (MagSafe cable identity)
//
// `USBPDSOPWatcher` was blind to MagSafe cable identities entirely: the
// MagSafe cable chip's VID/PID live on `IOPortTransportStateCC`, a class the
// watcher never matched. This file replays every `IOPortTransportStateCC`
// block in the customer-probe corpus through the REAL accept/parse
// functions (`isStateCCMagSafeCandidate`, `parseStateCCIdentity`), plus
// pure unit tests for their edges and the persistent-node lifecycle reducer
// (`reduceStateCCIdentities`), all without touching IOKit.

// MARK: - Probe-01 StateCC block extraction (independent of the watcher)

private let stateCCProbeRoot: URL = {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // WhatCableDarwinTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("research/customer-probes")
}()

private func stateCCAllProbeFolders() -> [String] {
    (try? FileManager.default
        .contentsOfDirectory(atPath: stateCCProbeRoot.path)
        .filter { entry in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(
                atPath: stateCCProbeRoot.appendingPathComponent(entry).path,
                isDirectory: &isDir
            )
            return isDir.boolValue
        }
        .sorted()
    ) ?? []
}

private func stateCCLoadProbeOutput(folder: String) -> String? {
    let url = stateCCProbeRoot.appendingPathComponent(folder).appendingPathComponent("01_walk_pd_tree.json")
    guard FileManager.default.fileExists(atPath: url.path),
          let data = try? Data(contentsOf: url),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let text = root["output"] as? String
    else { return nil }
    return text
}

/// One `IOPortTransportStateCC[N]` block's properties, as a `read:
/// (String) -> Any?` closure backed by a parsed dict. Values come back as
/// `NSNumber` (for `N (0xHEX)` and `true`/`false` lines) or `String` (for
/// quoted values), matching what `IORegistryEntryCreateCFProperty` hands the
/// real watcher, so the exact same `parseStateCCIdentity`/
/// `isStateCCMagSafeCandidate` code runs against both.
private func stateCCBlockBodies(text: String) -> [String] {
    var blocks: [String] = []
    var searchFrom = text.startIndex
    let header = "=== IOPortTransportStateCC["
    while let r = text.range(of: header, range: searchFrom..<text.endIndex) {
        let bodyStart = r.upperBound
        let rest = String(text[bodyStart...])
        let body: String
        if let next = rest.range(of: "\n=== ") ?? rest.range(of: "\n--- ") {
            body = String(rest[..<next.lowerBound])
        } else {
            body = String(rest.prefix(4000))
        }
        blocks.append(body)
        searchFrom = r.upperBound
    }
    return blocks
}

/// Parses `KEY = VALUE` lines (ignoring everything else, including the
/// nested `Metadata = { ... }` block's braces, which don't match the
/// pattern and are simply skipped -- the SOP1 keys inside it duplicate the
/// top-level ones with identical values, so last-write-wins is harmless).
private func stateCCReadClosure(body: String) -> (String) -> Any? {
    var dict: [String: Any] = [:]
    for line in body.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let eq = trimmed.range(of: " = ") else { continue }
        let key = String(trimmed[trimmed.startIndex..<eq.lowerBound])
        let rawValue = String(trimmed[eq.upperBound...])
        if rawValue == "true" {
            dict[key] = NSNumber(value: true)
        } else if rawValue == "false" {
            dict[key] = NSNumber(value: false)
        } else if rawValue.hasPrefix("\""), rawValue.hasSuffix("\""), rawValue.count >= 2 {
            dict[key] = String(rawValue.dropFirst().dropLast())
        } else {
            // "N (0xHEX)" or a bare number: take the leading digit run.
            let digits = rawValue.prefix { $0.isNumber || $0 == "-" }
            if !digits.isEmpty, let n = Int(digits) {
                dict[key] = NSNumber(value: n)
            }
        }
    }
    return { dict[$0] }
}

// MARK: - Corpus replay

@Suite("USBPDSOPWatcher StateCC (MagSafe cable identity) -- issue #573 part 2 corpus sweep")
struct USBPDSOPWatcherStateCCCorpusSweepTests {

    @Test func acceptAndParseReplayMatchesTheMeasuredSplit() {
        var accepted = 0
        var rejectedInactive = 0
        var rejectedActiveNoKeys = 0
        var rejectedUSBC = 0
        var entryID: UInt64 = 0

        for folder in stateCCAllProbeFolders() {
            guard let text = stateCCLoadProbeOutput(folder: folder) else { continue }
            for body in stateCCBlockBodies(text: text) {
                let read = stateCCReadClosure(body: body)
                entryID += 1
                let isCandidate = USBPDSOPWatcher.isStateCCMagSafeCandidate(read: read)
                let identity = USBPDSOPWatcher.parseStateCCIdentity(
                    entryID: entryID, read: read, hpmControllerUUID: nil)

                if !isCandidate {
                    // USB-C (or any non-MagSafe) StateCC block: must never
                    // candidate and must never emit. This is the bogus-
                    // identity risk the whole two-stage design exists to
                    // close, so it's checked unconditionally, not just
                    // counted.
                    #expect(identity == nil, "\(folder): non-candidate StateCC block produced an identity")
                    rejectedUSBC += 1
                    continue
                }

                if let identity {
                    // Growth-safe (Codex amendment): assert the identity
                    // preserves THIS block's own VID/PID, never a hardcoded
                    // 0x05AC/0x7800 invariant (a future PID is a second
                    // trackable model, not an error).
                    let expectedVID = (read("Vendor ID (SOP1)") as? NSNumber)?.intValue
                    let expectedPID = (read("Product ID (SOP1)") as? NSNumber)?.intValue
                    #expect(identity.vendorID == expectedVID)
                    #expect(identity.productID == expectedPID)
                    #expect(identity.parentPortType == PortIdentity.magSafeTypeCode)
                    #expect(identity.vdos.isEmpty)
                    #expect(identity.endpoint == .sopPrime)
                    accepted += 1
                } else {
                    let active = (read("Active") as? NSNumber)?.boolValue ?? false
                    let hasKeys = (read("Vendor ID (SOP1)") as? NSNumber) != nil
                        && (read("Product ID (SOP1)") as? NSNumber) != nil
                    if !active {
                        rejectedInactive += 1
                    } else if !hasKeys {
                        rejectedActiveNoKeys += 1
                    } else {
                        Issue.record("\(folder): candidate, active, both keys present, but produced no identity")
                    }
                }
            }
        }

        // Skip cleanly (not fail) when the corpus isn't checked out. This
        // is the documented convention for every sweep in this codebase
        // (an orchestrator ruling, design review round 5, against a Codex
        // suggestion to change it): the private CI's separate
        // corpus-presence check is the loud failure for a missing corpus,
        // not this test silently going red on a fresh clone/worktree with
        // no `research` symlink.
        let total = accepted + rejectedInactive + rejectedActiveNoKeys + rejectedUSBC
        guard total > 0 else { return }

        // Growth-safe floors (Codex amendment): non-vacuous, never exact
        // totals. Measured at review time (2026-08-31, 1325 probe-01
        // files, independently re-derived twice): 266 accepted, 616
        // rejected-inactive, 1 rejected-active-no-keys, 3342 rejected USB-C.
        #expect(accepted >= 200, "accepted: \(accepted)")
        #expect(rejectedUSBC >= 500, "rejected USB-C: \(rejectedUSBC)")
        #expect(rejectedInactive > 0, "rejected inactive: \(rejectedInactive)")
        // The corpus is tracked in git and only grows, so the one known
        // active-without-keys outlier can never disappear on its own;
        // a floor here (design review, Low) catches a parser regression
        // that silently stopped finding it, not just a corpus shrink that
        // can't actually happen.
        #expect(rejectedActiveNoKeys >= 1, "rejected active-no-keys: \(rejectedActiveNoKeys)")
    }
}

// MARK: - Accept-test unit tests (edges)

@Suite("USBPDSOPWatcher StateCC accept test -- edges")
struct USBPDSOPWatcherStateCCAcceptTests {

    private func read(_ dict: [String: Any]) -> (String) -> Any? {
        { dict[$0] }
    }

    private let magSafeActiveWithKeys: [String: Any] = [
        "ParentBuiltInPortType": NSNumber(value: 17),
        "ParentBuiltInPortNumber": NSNumber(value: 1),
        "Active": NSNumber(value: true),
        "Vendor ID (SOP1)": NSNumber(value: 0x05AC),
        "Product ID (SOP1)": NSNumber(value: 0x7800),
    ]

    @Test func candidateAndEmitsWithFullValidData() {
        let r = read(magSafeActiveWithKeys)
        #expect(USBPDSOPWatcher.isStateCCMagSafeCandidate(read: r))
        let identity = USBPDSOPWatcher.parseStateCCIdentity(entryID: 1, read: r, hpmControllerUUID: nil)
        #expect(identity != nil)
        #expect(identity?.vendorID == 0x05AC)
        #expect(identity?.productID == 0x7800)
        #expect(identity?.endpoint == .sopPrime)
        #expect(identity?.vdos.isEmpty == true)
        #expect(identity?.parentPortType == 17)
    }

    /// "Present" means a parseable numeric value, zero included, not merely
    /// non-nil. A zero VID/PID is a real answer (the fingerprint's
    /// `hasUniqueModelID` is the trackability judge, not this parser).
    @Test func zeroValuesAreParsedAsPresent() {
        var dict = magSafeActiveWithKeys
        dict["Vendor ID (SOP1)"] = NSNumber(value: 0)
        dict["Product ID (SOP1)"] = NSNumber(value: 0)
        let identity = USBPDSOPWatcher.parseStateCCIdentity(entryID: 1, read: read(dict), hpmControllerUUID: nil)
        #expect(identity != nil)
        #expect(identity?.vendorID == 0)
        #expect(identity?.productID == 0)
    }

    /// specRevision and bcdDevice default 0 unless the node provides them
    /// (design review, Low): no corpus block has ever shown StateCC
    /// publishing either, so this fixture is synthetic, exercising a shape
    /// the corpus can't. Same key names/precedence the generic
    /// `parseIdentity` path uses: "Specification Revision" as a top-level
    /// key, "bcdDevice" inside Metadata.
    @Test func specRevisionAndBcdDeviceFlowThroughWhenPresent() {
        var dict = magSafeActiveWithKeys
        dict["Specification Revision"] = NSNumber(value: 3)
        dict["Metadata"] = ["bcdDevice": NSNumber(value: 0x0100)]
        let identity = USBPDSOPWatcher.parseStateCCIdentity(entryID: 1, read: read(dict), hpmControllerUUID: nil)
        #expect(identity?.specRevision == 3)
        #expect(identity?.bcdDevice == 0x0100)
    }

    /// The default, pinned alongside the above so the two can't both read
    /// as passing vacuously (e.g. both fixtures accidentally producing 0):
    /// with neither key present, both fields read exactly 0.
    @Test func specRevisionAndBcdDeviceDefaultToZeroWhenAbsent() {
        let identity = USBPDSOPWatcher.parseStateCCIdentity(
            entryID: 1, read: read(magSafeActiveWithKeys), hpmControllerUUID: nil)
        #expect(identity?.specRevision == 0)
        #expect(identity?.bcdDevice == 0)
    }

    @Test func missingVendorIDKeyNeverEmits() {
        var dict = magSafeActiveWithKeys
        dict["Vendor ID (SOP1)"] = nil
        #expect(USBPDSOPWatcher.parseStateCCIdentity(entryID: 1, read: read(dict), hpmControllerUUID: nil) == nil)
    }

    @Test func missingProductIDKeyNeverEmits() {
        var dict = magSafeActiveWithKeys
        dict["Product ID (SOP1)"] = nil
        #expect(USBPDSOPWatcher.parseStateCCIdentity(entryID: 1, read: read(dict), hpmControllerUUID: nil) == nil)
    }

    /// "Present" means numeric, not merely non-nil of any type: a String
    /// value must not parse as a VID/PID even though the key exists.
    @Test func nonNumericValueNeverEmits() {
        var dict = magSafeActiveWithKeys
        dict["Vendor ID (SOP1)"] = "not-a-number"
        #expect(USBPDSOPWatcher.parseStateCCIdentity(entryID: 1, read: read(dict), hpmControllerUUID: nil) == nil)
    }

    @Test func activeFalseWithKeysPresentNeverEmits() {
        var dict = magSafeActiveWithKeys
        dict["Active"] = NSNumber(value: false)
        // Still a CANDIDATE (interest-subscription gate ignores Active)...
        #expect(USBPDSOPWatcher.isStateCCMagSafeCandidate(read: read(dict)))
        // ...but never EMITS while inactive, even with both keys present.
        #expect(USBPDSOPWatcher.parseStateCCIdentity(entryID: 1, read: read(dict), hpmControllerUUID: nil) == nil)
    }

    @Test func missingActiveKeyNeverEmits() {
        var dict = magSafeActiveWithKeys
        dict["Active"] = nil
        #expect(USBPDSOPWatcher.parseStateCCIdentity(entryID: 1, read: read(dict), hpmControllerUUID: nil) == nil)
    }

    @Test func usbcPortTypeNeverCandidatesNeverEmits() {
        var dict = magSafeActiveWithKeys
        dict["ParentBuiltInPortType"] = NSNumber(value: 2)
        #expect(!USBPDSOPWatcher.isStateCCMagSafeCandidate(read: read(dict)))
        #expect(USBPDSOPWatcher.parseStateCCIdentity(entryID: 1, read: read(dict), hpmControllerUUID: nil) == nil)
    }

    /// The BuiltIn key takes priority over the plain one when both are
    /// present (mirrors `parentPortIdentity(read:)`'s own rule, reused
    /// unchanged): a MagSafe BuiltIn type with a conflicting plain type
    /// must still read as MagSafe.
    @Test func builtInPortTypeTakesPriorityOverPlainPortType() {
        var dict = magSafeActiveWithKeys
        dict["ParentBuiltInPortType"] = NSNumber(value: 17)
        dict["ParentPortType"] = NSNumber(value: 2)   // conflicting, must lose
        #expect(USBPDSOPWatcher.isStateCCMagSafeCandidate(read: read(dict)))

        var usbcDict = magSafeActiveWithKeys
        usbcDict["ParentBuiltInPortType"] = NSNumber(value: 2)
        usbcDict["ParentPortType"] = NSNumber(value: 17)  // conflicting, must lose
        #expect(!USBPDSOPWatcher.isStateCCMagSafeCandidate(read: read(usbcDict)))
    }

    /// Only the PLAIN key present (no BuiltIn key at all): falls back
    /// correctly, same as `parentPortIdentity(read:)` does everywhere else.
    @Test func plainPortTypeUsedWhenNoBuiltInKeyPresent() {
        var dict = magSafeActiveWithKeys
        dict["ParentBuiltInPortType"] = nil
        dict["ParentPortType"] = NSNumber(value: 17)
        #expect(USBPDSOPWatcher.isStateCCMagSafeCandidate(read: read(dict)))
    }
}

// MARK: - Lifecycle reducer tests (pure, no IOKit)

@Suite("USBPDSOPWatcher StateCC lifecycle reducer")
struct USBPDSOPWatcherStateCCLifecycleTests {

    private func magSafeIdentity(entryID: UInt64, vendorID: Int = 0x05AC, productID: Int = 0x7800) -> USBPDSOP {
        USBPDSOP(
            id: entryID, endpoint: .sopPrime, parentPortType: 17, parentPortNumber: 1,
            vendorID: vendorID, productID: productID, bcdDevice: 0, vdos: [], specRevision: 0)
    }

    /// App starts with an inactive MagSafe node (no identity yet, but
    /// already a candidate so interest is subscribed -- covered by the
    /// accept tests above), then the cable is plugged: the identity appears.
    @Test func startInactiveThenPlugAppearsIdentity() {
        var identities: [USBPDSOP] = []
        // Inactive sighting: no identity produced, reducer is a no-op.
        identities = USBPDSOPWatcher.reduceStateCCIdentities(identities, entryID: 1, identity: nil)
        #expect(identities.isEmpty)

        // Plug: identity appears.
        let plugged = magSafeIdentity(entryID: 1)
        identities = USBPDSOPWatcher.reduceStateCCIdentities(identities, entryID: 1, identity: plugged)
        #expect(identities == [plugged])
    }

    @Test func unplugRemovesByEntryID() {
        let other = magSafeIdentity(entryID: 99, vendorID: 0x1234, productID: 0x5678)
        var identities: [USBPDSOP] = [magSafeIdentity(entryID: 1), other]

        identities = USBPDSOPWatcher.reduceStateCCIdentities(identities, entryID: 1, identity: nil)

        #expect(identities == [other])  // only entry 1 removed, entry 99 untouched
    }

    @Test func repeatedCallbacksNeverDuplicate() {
        var identities: [USBPDSOP] = []
        let identity = magSafeIdentity(entryID: 1)
        for _ in 0..<5 {
            identities = USBPDSOPWatcher.reduceStateCCIdentities(identities, entryID: 1, identity: identity)
        }
        #expect(identities.count == 1)
        #expect(identities == [identity])
    }

    @Test func changedVendorIDReplacesRatherThanAppends() {
        var identities: [USBPDSOP] = [magSafeIdentity(entryID: 1, vendorID: 0x05AC, productID: 0x7800)]
        let changed = magSafeIdentity(entryID: 1, vendorID: 0x1234, productID: 0x9999)
        identities = USBPDSOPWatcher.reduceStateCCIdentities(identities, entryID: 1, identity: changed)
        #expect(identities.count == 1)
        #expect(identities == [changed])
    }

    /// Non-candidate node (would never even reach the reducer in production,
    /// since `processStateCCService` returns nil for it, but pins that the
    /// reducer itself has no candidate-awareness baked in: it's a pure
    /// upsert-by-ID, and candidacy is enforced entirely upstream).
    @Test func reducerIsAPlainUpsertIndependentOfCandidacy() {
        var identities: [USBPDSOP] = []
        identities = USBPDSOPWatcher.reduceStateCCIdentities(identities, entryID: 1, identity: nil)
        #expect(identities.isEmpty)
    }
}

// MARK: - StateCC interest-handle bookkeeping (issue #573 round-5 design
// review, required finding: the lifecycle tests above exercise the identity
// reducer, not the interest-handle map, so deleting an `IOObjectRelease`
// call or a handle-map mutation in the watcher left every prior test green.
// `StateCCInterestBookkeeping<Handle>` is the seam: generic over the handle
// type, so these tests use plain `Int` handles rather than a real IOKit
// `io_object_t`, which is a Mach port name a test has no business
// fabricating. The actual `IOObjectRelease` call itself, on whatever these
// prove gets returned, stays in `USBPDSOPWatcher` and is not exercised here:
// that one call is genuinely untestable without faking IOKit object
// identity, so it is surfaced here rather than covered by a fake.

@Suite("USBPDSOPWatcher StateCC interest-handle bookkeeping")
struct StateCCInterestBookkeepingTests {

    @Test("stop() (removeAll) empties the handle map and returns everything that was held")
    func removeAllEmptiesTheMap() {
        var bookkeeping = StateCCInterestBookkeeping<Int>()
        bookkeeping.register(entryID: 1, handle: 100)
        bookkeeping.register(entryID: 2, handle: 200)

        let removed = bookkeeping.removeAll()

        #expect(Set(removed.values) == [100, 200])
        #expect(bookkeeping.handles.isEmpty)
    }

    @Test("refresh-prune removes only the handle whose service disappeared")
    func pruneStaleRemovesOnlyTheGoneEntry() {
        var bookkeeping = StateCCInterestBookkeeping<Int>()
        bookkeeping.register(entryID: 1, handle: 100)   // stays live
        bookkeeping.register(entryID: 2, handle: 200)   // goes away

        let removed = bookkeeping.pruneStale(live: [1])

        #expect(removed == [2: 200])
        #expect(bookkeeping.handles == [1: 100])
    }

    /// A candidate that is merely INACTIVE (still present in the registry,
    /// no current identity) must stay in the live set and keep its handle:
    /// pruning is keyed on registry presence, not on whether the node
    /// currently emits.
    @Test("refresh-prune keeps a handle whose entry ID is still live, even with no current identity")
    func pruneStaleKeepsAnInactiveButStillPresentEntry() {
        var bookkeeping = StateCCInterestBookkeeping<Int>()
        bookkeeping.register(entryID: 1, handle: 100)

        let removed = bookkeeping.pruneStale(live: [1])   // still present, just not emitting

        #expect(removed.isEmpty)
        #expect(bookkeeping.handles == [1: 100])
    }

    @Test("Termination removes exactly the terminated entry's handle")
    func removeEntryIDRemovesExactlyThatOne() {
        var bookkeeping = StateCCInterestBookkeeping<Int>()
        bookkeeping.register(entryID: 1, handle: 100)
        bookkeeping.register(entryID: 2, handle: 200)

        let removed = bookkeeping.remove(entryID: 1)

        #expect(removed == 100)
        #expect(bookkeeping.handles == [2: 200])
    }

    @Test("Removing an entry ID that was never registered is a no-op, not a crash")
    func removeUnknownEntryIDIsANoOp() {
        var bookkeeping = StateCCInterestBookkeeping<Int>()
        bookkeeping.register(entryID: 1, handle: 100)

        let removed = bookkeeping.remove(entryID: 999)

        #expect(removed == nil)
        #expect(bookkeeping.handles == [1: 100])
    }

    /// Repeated registration for the same entry ID must not grow the map.
    /// `shouldRegister` is the gate a caller checks BEFORE doing whatever
    /// produces a new handle; pinned both as the gate returning false on a
    /// repeat, and as the map staying single-entry even if a caller called
    /// `register` again anyway (the dictionary-assignment shape of
    /// `register` alone already can't grow on a repeat of the SAME key, but
    /// asserting `handles.count == 1` after two registrations pins the
    /// externally observable guarantee, not the implementation detail).
    @Test("Repeated registration for the same entry ID never grows the map")
    func repeatedRegistrationNeverGrowsTheMap() {
        var bookkeeping = StateCCInterestBookkeeping<Int>()
        #expect(bookkeeping.shouldRegister(entryID: 1))

        bookkeeping.register(entryID: 1, handle: 100)
        #expect(!bookkeeping.shouldRegister(entryID: 1))   // the idempotency gate itself

        bookkeeping.register(entryID: 1, handle: 999)   // a caller that ignored the gate anyway
        #expect(bookkeeping.handles.count == 1)
    }
}

// MARK: - Watcher wiring into the bookkeeping (issue #573 rounds 6-7 design
// review, required findings): the tests above pin `StateCCInterestBookkeeping`
// itself, but nothing exercised the WATCHER's own call sites -- `stop()`,
// the refresh-prune step, the termination step -- so deleting any one of
// those calls into the struct left every earlier test green. These tests go
// through the real watcher methods: `stop()` and `refresh()` directly
// (round 6), and `handleStateCCRemoved(_:)` directly too (round 7, once
// `drainStateCCTerminatedEntryIDs` gave it a way to run without a real
// `io_iterator_t`). `releaseHandle` is substituted for a recording closure
// throughout. Fabricated `io_object_t` values (arbitrary `UInt32`s, never a
// real Mach port) are safe here specifically BECAUSE the real
// `IOObjectRelease` is never in the loop: the substituted closure only
// records what it was called with.
@MainActor
@Suite("USBPDSOPWatcher StateCC interest-handle wiring")
struct USBPDSOPWatcherStateCCWiringTests {

    /// Records every handle `releaseHandle` was called with, in call order.
    private final class ReleaseRecorder {
        var released: [io_object_t] = []
        func closure() -> (io_object_t) -> Void {
            { [weak self] handle in self?.released.append(handle) }
        }
    }

    @Test func stopReleasesEveryHandleAndEmptiesTheMap() {
        let watcher = USBPDSOPWatcher()
        let recorder = ReleaseRecorder()
        watcher.releaseHandle = recorder.closure()
        watcher.seedStateCCInterest(entryID: 1, handle: 1001)
        watcher.seedStateCCInterest(entryID: 2, handle: 1002)

        watcher.stop()

        #expect(Set(recorder.released) == [1001, 1002])
        #expect(watcher.stateCCInterestHandles.isEmpty)
    }

    @Test func refreshPruneReleasesExactlyTheHandleWhoseServiceIsGone() {
        let watcher = USBPDSOPWatcher()
        let recorder = ReleaseRecorder()
        watcher.releaseHandle = recorder.closure()
        watcher.seedStateCCInterest(entryID: 1, handle: 1001)   // stays live
        watcher.seedStateCCInterest(entryID: 2, handle: 1002)   // service gone

        watcher.pruneStateCCInterest(liveEntryIDs: [1])

        #expect(recorder.released == [1002])
        #expect(watcher.stateCCInterestHandles == [1: 1001])
    }

    /// An entry ID that is merely inactive (still present, no current
    /// identity) is NOT a "service gone" case: `refresh()` always includes
    /// every StateCC candidate it found in `liveEntryIDs`, whether or not it
    /// currently emits (see `processStateCCService`'s own doc comment).
    @Test func refreshPruneReleasesNothingWhenTheOnlyEntryIsStillLive() {
        let watcher = USBPDSOPWatcher()
        let recorder = ReleaseRecorder()
        watcher.releaseHandle = recorder.closure()
        watcher.seedStateCCInterest(entryID: 1, handle: 1001)

        watcher.pruneStateCCInterest(liveEntryIDs: [1])

        #expect(recorder.released.isEmpty)
        #expect(watcher.stateCCInterestHandles == [1: 1001])
    }

    /// The two tests above call `pruneStateCCInterest(liveEntryIDs:)`
    /// directly, which pins that method's own behaviour but, on its own,
    /// would not notice `refresh()` losing its call INTO that method (the
    /// exact wiring gap this round's design review is about). This test
    /// closes that: it calls the REAL, public `refresh()`, which performs
    /// its own live IOKit registry walk for `liveEntryIDs` -- so the seeded
    /// entry ID has to be one no real StateCC node could ever report. Real
    /// IOKit registry entry IDs are large, kernel-assigned, monotonically
    /// increasing values (in the millions-plus on any Mac that has been
    /// running a while), so a small literal is safe to treat as
    /// "guaranteed absent" regardless of what hardware happens to be
    /// plugged into the machine running this test.
    @Test func refreshActuallyInvokesThePruneStep() {
        let watcher = USBPDSOPWatcher()
        let recorder = ReleaseRecorder()
        watcher.releaseHandle = recorder.closure()
        watcher.seedStateCCInterest(entryID: 1, handle: 1001)   // no real node has this ID

        watcher.refresh()

        #expect(recorder.released == [1001])
        #expect(watcher.stateCCInterestHandles.isEmpty)
    }

    /// Calls `removeStateCCEntry(entryID:)` directly: pins that method's own
    /// behaviour, but on its own would not notice `handleStateCCRemoved(_:)`
    /// losing its call INTO it. `terminationHandlerReleasesTheDrainedEntrysHandle`
    /// below is what closes that (design review round 7): it drives the
    /// REAL `handleStateCCRemoved(_:)`.
    @Test func terminationReleasesExactlyThatEntrysHandle() {
        let watcher = USBPDSOPWatcher()
        let recorder = ReleaseRecorder()
        watcher.releaseHandle = recorder.closure()
        watcher.seedStateCCInterest(entryID: 1, handle: 1001)
        watcher.seedStateCCInterest(entryID: 2, handle: 1002)

        watcher.removeStateCCEntry(entryID: 1)

        #expect(recorder.released == [1001])
        #expect(watcher.stateCCInterestHandles == [2: 1002])
    }

    /// The real termination entry point (design review round 7, required
    /// finding: `handleStateCCRemoved(_:)`'s own call into
    /// `removeStateCCEntry(entryID:)`, at the time unpinned, since every
    /// existing test called the helper directly). A genuine `io_iterator_t`
    /// is not actually needed: `drainStateCCTerminatedEntryIDs` is
    /// substituted with a closure that ignores whatever iterator value it's
    /// given and returns a seeded entry ID instead, so `handleStateCCRemoved`
    /// runs for real against a harmless placeholder iterator (`0`, never
    /// touched by real IOKit since the injected drain never looks at it).
    @Test func terminationHandlerReleasesTheDrainedEntrysHandle() {
        let watcher = USBPDSOPWatcher()
        let recorder = ReleaseRecorder()
        watcher.releaseHandle = recorder.closure()
        watcher.seedStateCCInterest(entryID: 1, handle: 1001)
        watcher.seedStateCCInterest(entryID: 2, handle: 1002)   // untouched by this termination
        watcher.drainStateCCTerminatedEntryIDs = { _ in [1] }   // pretend the iterator yielded entry 1

        watcher.handleStateCCRemoved(0)   // placeholder iterator value; never dereferenced

        #expect(recorder.released == [1001])
        #expect(watcher.stateCCInterestHandles == [2: 1002])
    }

    @Test func terminationOfAnUnregisteredEntryReleasesNothing() {
        let watcher = USBPDSOPWatcher()
        let recorder = ReleaseRecorder()
        watcher.releaseHandle = recorder.closure()
        watcher.seedStateCCInterest(entryID: 1, handle: 1001)

        watcher.removeStateCCEntry(entryID: 999)

        #expect(recorder.released.isEmpty)
        #expect(watcher.stateCCInterestHandles == [1: 1001])
    }
}
