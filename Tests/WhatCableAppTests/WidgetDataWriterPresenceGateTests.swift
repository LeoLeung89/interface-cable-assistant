import Testing
@testable import WhatCable

/// Tests that exercise the real `WidgetDataWriter` code, not just the
/// extracted pure `WidgetPresenceState`/`structuralSignature` types it uses.
///
/// `WidgetDataWriter.init` was relaxed from `private` to `internal` so a
/// test can construct an isolated instance with a stub `presenceChecker`
/// (`WidgetDataWriter(presenceChecker:)`), separate from the app's real
/// `.shared` singleton.
///
/// `performScheduledWrite()` and `performHeartbeatTick()` are the extracted
/// bodies of `scheduleWrite()`'s debounced `Task` and the heartbeat timer's
/// loop iteration, made directly callable so a test does not have to wait
/// out the real 200ms debounce or 60s heartbeat interval. Both still run the
/// exact same lines the app runs; nothing here is a reimplementation of the
/// gate logic.
///
/// The test process has no App Group entitlement, so the actual file write
/// inside `writeToDefaults` always fails (`WidgetSnapshot.sharedFileURL` is
/// nil there). `writeAttemptCount` is incremented before that URL lookup, so
/// it is what these tests read to confirm the presence gate and structural
/// dedup let a call reach the write at all, independent of whether the OS
/// write itself could succeed.
@MainActor
@Suite("WidgetDataWriter presence gate wiring")
struct WidgetDataWriterPresenceGateTests {

    /// Always answers immediately with a fixed result. Unlike
    /// `WidgetPresenceRaceTests.GatedPresenceChecker`, nothing here needs to
    /// be held open: these tests care about the gate's effect, not call
    /// ordering.
    struct FixedPresenceChecker: WidgetPresenceChecking {
        let installed: Bool
        func hasInstalledWidgets() async -> Bool { installed }
    }

    @Test("A known-none-installed heartbeat tick performs no write")
    func knownNoneInstalledSuppressesHeartbeatWrite() async {
        let writer = WidgetDataWriter(presenceChecker: FixedPresenceChecker(installed: false))
        let wrote = await writer.performHeartbeatTick()

        #expect(!wrote)
        #expect(writer.writeAttemptCount == 0)
        #expect(!writer.presenceStateForTesting.shouldWrite)
    }

    @Test("A known-installed heartbeat tick writes")
    func knownInstalledHeartbeatWrites() async {
        let writer = WidgetDataWriter(presenceChecker: FixedPresenceChecker(installed: true))
        let wrote = await writer.performHeartbeatTick()

        #expect(wrote)
        #expect(writer.writeAttemptCount == 1)
    }

    @Test("Before any presence check, the debounced write path still attempts a write (fail-safe default)")
    func unknownPresenceStillAttemptsScheduledWrite() {
        // No refreshPresence() call has happened yet, so presenceState is
        // still nil/unknown. WidgetPresenceState's fail-safe default means
        // performScheduledWrite() must still be allowed through the gate; it
        // may still choose not to write for other reasons (the structural
        // dedup against a nil lastSnapshot never applies on a first call, so
        // this should reach writeToDefaults).
        let writer = WidgetDataWriter(presenceChecker: FixedPresenceChecker(installed: false))
        _ = writer.performScheduledWrite()

        #expect(writer.writeAttemptCount == 1, "The gate must not suppress a write before presence is known")
    }

    @Test("Once known-none-installed, the debounced write path performs no write")
    func knownNoneInstalledSuppressesScheduledWrite() async {
        let writer = WidgetDataWriter(presenceChecker: FixedPresenceChecker(installed: false))
        await writer.refreshPresence()
        #expect(!writer.presenceStateForTesting.shouldWrite, "Fixture setup check")

        let wrote = writer.performScheduledWrite()

        #expect(!wrote)
        #expect(writer.writeAttemptCount == 0)
    }

    @Test("A none-to-installed flip during the heartbeat performs a write in that same tick")
    func noneToInstalledFlipWritesPromptly() async {
        // `presenceChecker` is a `let`, so a single writer answers "false"
        // then "true" across two ticks via a stub that returns its results
        // in sequence. The second tick is the one this test cares about:
        // the flip from none-installed to installed must be reflected in
        // that same call, not require a further tick after it.
        let sequenced = SequencedPresenceChecker(results: [false, true])
        let writer = WidgetDataWriter(presenceChecker: sequenced)

        let tick1Wrote = await writer.performHeartbeatTick()
        #expect(!tick1Wrote, "Fixture setup check: must start from known-none-installed")
        #expect(writer.writeAttemptCount == 0)

        let tick2Wrote = await writer.performHeartbeatTick()
        #expect(tick2Wrote, "The tick that flips none -> installed must write immediately")
        #expect(writer.writeAttemptCount == 1, "Only the flip tick should have written; the first tick must not have")
    }

    /// Returns each entry of `results` in order, one per call, repeating the
    /// last entry once exhausted.
    final class SequencedPresenceChecker: WidgetPresenceChecking {
        private var results: [Bool]
        private var index = 0

        init(results: [Bool]) {
            precondition(!results.isEmpty)
            self.results = results
        }

        func hasInstalledWidgets() async -> Bool {
            let value = results[min(index, results.count - 1)]
            index += 1
            return value
        }
    }
}
