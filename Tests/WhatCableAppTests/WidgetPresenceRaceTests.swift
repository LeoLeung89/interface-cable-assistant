import Testing
@testable import WhatCable

/// Tests for the generation guard in `WidgetDataWriter.refreshPresence()`.
///
/// The startup seed check and the heartbeat's periodic check both call
/// `refreshPresence()`, and nothing enforces the order their results land
/// in. A slow startup lookup completing after a faster, later heartbeat
/// lookup already found a widget installed would, without the guard,
/// overwrite that correct "installed" with a stale "not installed" and
/// suppress writes for up to another heartbeat interval (~60s).
///
/// `GatedPresenceChecker` lets the test hold each call open and release
/// them in a chosen order, so the race is reproduced exactly rather than
/// relying on wall-clock timing. Both it and the test run on the main
/// actor, matching `WidgetDataWriter`'s own isolation, so task scheduling
/// order is deterministic: a task only yields the actor at its `await`
/// point, and the test controls when that is by choosing when to release.
@MainActor
@Suite("WidgetDataWriter presence race")
struct WidgetPresenceRaceTests {

    /// Stub presence checker that suspends every call until the test
    /// explicitly releases it, by call order.
    ///
    /// `@MainActor` is spelled out because the suite's attribute does not
    /// reach nested types. Without it, `hasInstalledWidgets()` ran on the
    /// generic executor and appended to `pending` off the main thread while
    /// the test read it on main: a data race that crashed CI once, and a
    /// missed append under Thread Sanitizer's slower timing.
    @MainActor
    final class GatedPresenceChecker: WidgetPresenceChecking {
        private var pending: [(Bool) -> Void] = []

        var pendingCount: Int { pending.count }

        func hasInstalledWidgets() async -> Bool {
            await withCheckedContinuation { continuation in
                pending.append { installed in continuation.resume(returning: installed) }
            }
        }

        /// Resumes the call that started at `index` (0 = the first call
        /// made) with `installed`. Index, not FIFO removal, so calls can be
        /// released in any order while still being addressable by when they
        /// started.
        func release(at index: Int, installed: Bool) {
            precondition(index < pending.count, "no pending call at index \(index)")
            pending[index](installed)
        }
    }

    /// Spins until `pendingCount` reaches `count` or a generous iteration
    /// budget is exhausted. A single `Task.yield()` is normally enough to
    /// let an already-enqueued main-actor task reach its first suspension
    /// point, but this bounds the wait instead of assuming exactly one
    /// yield suffices, so the test fails loudly instead of hanging if that
    /// assumption is ever wrong.
    private func waitForPending(_ checker: GatedPresenceChecker, count: Int) async {
        for _ in 0..<50 where checker.pendingCount < count {
            await Task.yield()
        }
    }

    @Test("A late-arriving stale result does not overwrite a newer result that already landed")
    func staleResultIsDiscarded() async {
        let checker = GatedPresenceChecker()
        let writer = WidgetDataWriter(presenceChecker: checker)

        // "Startup" call: started first (generation 1), answers last.
        let startupTask = Task { @MainActor in await writer.refreshPresence() }
        await waitForPending(checker, count: 1)

        // "Heartbeat" call: started second (generation 2), answers first.
        let heartbeatTask = Task { @MainActor in await writer.refreshPresence() }
        await waitForPending(checker, count: 2)

        #expect(checker.pendingCount == 2, "Both calls must be in flight for this test to prove anything")

        // Heartbeat (the newer call) resolves first, finds a widget.
        checker.release(at: 1, installed: true)
        _ = await heartbeatTask.value
        #expect(writer.presenceStateForTesting.installed == true)
        #expect(writer.presenceStateForTesting.shouldWrite)

        // Startup (the older, now-stale call) resolves last, with "false".
        // Without the generation guard this would be the last write to
        // `presenceState.installed` and would flip it back to "not
        // installed", exactly the ~60s suppression bug this guard exists to
        // rule out.
        checker.release(at: 0, installed: false)
        _ = await startupTask.value

        #expect(writer.presenceStateForTesting.installed == true, "The stale result must not have overwritten the newer one")
        #expect(writer.presenceStateForTesting.shouldWrite)
    }

    @Test("The generation guard reports the stale call's refreshPresence() as not-a-flip")
    func staleResultReportsNoFlip() async {
        let checker = GatedPresenceChecker()
        let writer = WidgetDataWriter(presenceChecker: checker)

        // Seed a known "none installed" state so the flip-detection logic
        // has something to (wrongly) trigger on if the guard were missing.
        let seedTask = Task { @MainActor in await writer.refreshPresence() }
        await waitForPending(checker, count: 1)
        checker.release(at: 0, installed: false)
        _ = await seedTask.value
        #expect(writer.presenceStateForTesting.installed == false)

        // The seed call above already holds index 0 in `checker`'s pending
        // list (it is never removed, only appended to), so the two calls
        // under test here are indices 1 (startup) and 2 (heartbeat).
        let startupTask = Task { @MainActor in await writer.refreshPresence() }
        await waitForPending(checker, count: 2)
        let heartbeatTask = Task { @MainActor in await writer.refreshPresence() }
        await waitForPending(checker, count: 3)

        // Heartbeat resolves first: none -> installed, a real flip.
        checker.release(at: 2, installed: true)
        let heartbeatFlipped = await heartbeatTask.value
        #expect(heartbeatFlipped)

        // Startup resolves last, superseded. Even though its own answer
        // ("false") would, read in isolation, look like "no flip" anyway,
        // the guard must discard the call outright rather than letting it
        // touch presenceState at all.
        checker.release(at: 1, installed: false)
        let startupFlipped = await startupTask.value
        #expect(!startupFlipped)
        #expect(writer.presenceStateForTesting.installed == true)
    }
}
