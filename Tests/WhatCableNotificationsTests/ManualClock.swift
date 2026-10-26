import Foundation

/// A `Clock` a test drives by hand: `sleep(until:)` parks the caller until a
/// later `advance(by:)` call moves `now` past the deadline, never a real
/// wall-clock wait. This is what lets `DeviceDiffSequencerTests` exercise
/// multi-second settle windows, presentation gaps, and deadlines with zero
/// real sleeps and zero flake-margin guesswork: `advance(by:)` moves time by
/// an EXACT amount, so a test can assert "not yet" one nanosecond before a
/// window and "landed" exactly at it, deterministically.
///
/// Genuinely thread-safe, not just "safe in practice because every test
/// happens to run on the main actor": `lock` guards every read and mutation
/// of `_now` and `waiters`. This matters specifically because of
/// cancellation below -- a `Task`'s cancellation handler can run
/// synchronously on whatever thread called `.cancel()`, which is not
/// guaranteed to be the main actor, concurrently with an `advance(by:)` call
/// that might be resuming the very same waiter. `@unchecked Sendable`
/// because `Clock` requires `Sendable` and this type's actual safety (the
/// lock) isn't something the compiler can see through a plain stored
/// `NSLock`.
///
/// `sleep(until:)`'s cancellation check, due check, and registration are one
/// ATOMIC decision under a single lock acquisition (see that method). An
/// earlier version checked "already due" under one lock acquisition, then
/// registered the waiter under a SECOND, separate one: an `advance(by:)`
/// landing in that gap would sweep past a waiter that hadn't registered
/// yet, stranding it forever (nothing resumes it until a LATER `advance`,
/// which may never come). Reproduced as a genuine hang (near-zero CPU
/// against a growing wall clock, not merely slow) by
/// `ManualClockRegistrationRaceTests`, which stays in the test target as a
/// permanent regression guard. The same reasoning closes a second race:
/// `withTaskCancellationHandler`'s `onCancel` can fire BEFORE the operation
/// closure below ever registers a waiter, in which case `onCancel` finds
/// nothing to remove; the atomic registration re-checks `Task.isCancelled`
/// itself and resumes with `CancellationError` instead of registering, so
/// that ordering can no longer strand a waiter either.
final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        fileprivate var offset: Duration

        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }
    }

    private let lock = NSLock()
    private var _now: Instant = Instant(offset: .zero)
    var now: Instant {
        lock.lock()
        defer { lock.unlock() }
        return _now
    }
    let minimumResolution: Duration = .zero

    /// One entry per outstanding `sleep(until:)` call, in registration
    /// order. `advance(by:)` resumes every waiter whose deadline has been
    /// reached, earliest deadline first, so two waiters landing on the same
    /// `advance` call fire in the order their sleeps were due, matching
    /// what a real clock would do. `id` exists purely so a cancellation
    /// handler can find and remove its OWN waiter without disturbing any
    /// other still-pending one. Guarded by `lock`.
    private var waiters: [(id: UUID, deadline: Instant, continuation: CheckedContinuation<Void, Error>)] = []

    /// Monotonically increments every time `sleep(until:)` REGISTERS a new
    /// waiter (never on removal, whether by `advance(by:)` resuming one or
    /// `onCancel` pulling one out early). `settle()` uses this instead of
    /// comparing `waiters.count`: a plain count can go DOWN from a
    /// cancellation removing a waiter at the same moment a fresh sleep
    /// registers a new one, leaving the count unchanged while work is still
    /// genuinely outstanding. A monotonic counter that only ever moves
    /// forward on real new work has no such blind spot. Guarded by `lock`.
    private var registrationGeneration = 0

    /// `Clock`'s one required suspension point. Cancellation is early-wake-
    /// aware here, matching real `Task.sleep`: a cancelled sleep throws
    /// `CancellationError` promptly rather than staying parked until
    /// `advance(by:)` happens to reach its deadline.
    ///
    /// The cancellation check, the "already due" check, and the waiter
    /// registration are ONE atomic decision, made inside the continuation
    /// closure under a single `lock` acquisition, resolving to exactly one
    /// of three outcomes: already cancelled -> resume throwing
    /// `CancellationError`; already due -> resume immediately; otherwise ->
    /// append to `waiters`. Splitting any of these into separate lock
    /// acquisitions reopens a stranding race: see the type doc comment
    /// above and `ManualClockRegistrationRaceTests`.
    ///
    /// `withTaskCancellationHandler`'s `onCancel` closure can run
    /// synchronously and concurrently with the operation closure (if
    /// cancellation happens before the operation even runs) or with
    /// `advance(by:)`'s own resume, so all three sides take `lock` and each
    /// only resumes a waiter it itself removed from `waiters` (never one
    /// another side already claimed) -- no continuation is ever resumed
    /// twice.
    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        if Task.isCancelled { throw CancellationError() }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if deadline <= _now {
                    lock.unlock()
                    continuation.resume(returning: ())
                    return
                }
                registrationGeneration += 1
                waiters.append((id, deadline, continuation))
                lock.unlock()
            }
        } onCancel: {
            self.lock.lock()
            guard let index = self.waiters.firstIndex(where: { $0.id == id }) else {
                self.lock.unlock()
                return
            }
            let waiter = self.waiters.remove(at: index)
            self.lock.unlock()
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves `now` forward by `duration`, resumes every waiter whose
    /// deadline that reaches, then drains the main actor (`settle()`) so
    /// every resumed continuation's synchronous work (landing a diff,
    /// posting, or registering a BRAND NEW sleep of its own) has actually
    /// completed before this call returns control to the test.
    func advance(by duration: Duration) async {
        lock.lock()
        _now = _now.advanced(by: duration)
        let deadline = _now
        let ready = waiters
            .filter { $0.deadline <= deadline }
            .sorted { $0.deadline < $1.deadline }
        waiters.removeAll { $0.deadline <= deadline }
        lock.unlock()
        for waiter in ready {
            waiter.continuation.resume(returning: ())
        }
        await settle()
    }

    /// Repeatedly enqueues an empty barrier `Task { @MainActor in }` and
    /// awaits its `.value`. Swift schedules same-priority main-actor work
    /// FIFO, so by the time an empty barrier task actually runs, everything
    /// enqueued ahead of it (a resumed continuation's synchronous
    /// continuation, including any chain of further synchronous calls it
    /// makes) has already run to completion. Every producer this loop needs
    /// to wait for (`DeviceDiffSequencer`'s settle/gap/deadline tasks) is
    /// itself pinned `@MainActor`, so this is a real barrier for them, not
    /// just a hopeful yield; a call from off the main actor is still
    /// correctly ordered by the `Task { @MainActor in }` hop itself.
    ///
    /// One barrier round isn't always enough: a resumed continuation's chain
    /// can itself register a FRESH sleep (e.g. `landDeferredDeviceDiff`
    /// scheduling a new presentation-gap task from inside a landing), which
    /// only shows up once that round's barrier has actually run. So this
    /// loops, re-checking `registrationGeneration`, until a round registers
    /// nothing new. The generation counter (not `waiters.count`) is what
    /// makes "unchanged this round" mean "nothing left in flight": a plain
    /// count can go down from a concurrent cancellation removing a waiter at
    /// the same moment a fresh sleep registers one, masking real outstanding
    /// work as "no change". The generation only ever moves forward on a
    /// genuine new registration, so it can't be fooled that way.
    ///
    /// Replaces an earlier fixed-yield-count `advance(by:)` (a set number of
    /// `Task.yield()` calls) that measured flaky (~7-13% failure across
    /// several tests) on exactly this multi-hop scheduling: a fixed count
    /// can under-drain a chain deeper than it anticipated. This barrier
    /// approach has no arbitrary margin to run out.
    func settle() async {
        var previousGeneration = currentRegistrationGeneration()
        while true {
            await Task { @MainActor in }.value
            let currentGeneration = currentRegistrationGeneration()
            if currentGeneration == previousGeneration { break }
            previousGeneration = currentGeneration
        }
    }

    private func currentRegistrationGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return registrationGeneration
    }
}
