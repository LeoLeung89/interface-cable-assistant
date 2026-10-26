import XCTest
@testable import WhatCableNotifications

/// Regression test for a registration race in `ManualClock`: `sleep(until:)`
/// used to check "already due" and append to `waiters` under two SEPARATE
/// lock acquisitions, so an `advance(by:)` landing in between could sweep
/// past a waiter that hadn't registered yet, stranding it forever (nothing
/// resumes it until a LATER `advance(by:)`, which may never come). Fixed by
/// making the due-check, the cancellation-check, and the registration one
/// atomic decision under a single lock acquisition (see `sleep(until:)`).
///
/// Every deadline is computed from a SINGLE `clock.now` snapshot taken
/// before any task is spawned, not read fresh inside each task body. That
/// matters: if a task's own deadline were computed lazily (`clock.now` read
/// only once the task actually starts running), a task that happens to be
/// scheduled AFTER the racing `advance(by:)` call already moved `_now`
/// forward would compute a deadline relative to the ALREADY-ADVANCED clock,
/// landing in a future no subsequent `advance` call in this test ever
/// reaches -- a hang, but one that says nothing about the atomicity bug
/// this test targets. Fixing every deadline up front isolates exactly the
/// race in `sleep(until:)` itself: whether a REGISTRATION racing a
/// CONCURRENT `advance(by:)` for an already-fixed, already-due-or-nearly-due
/// deadline can be stranded.
///
/// Spawns 20 unstructured tasks with deadlines 0-19ms from that snapshot,
/// all racing an `advance(by: 20ms)` called from a plain (non-`@MainActor`)
/// `Task.detached` context, so the race is genuinely concurrent rather than
/// serialized onto one actor. Before the atomicity fix this reliably hung
/// (confirmed: near-zero CPU time against a growing wall clock across
/// repeated runs, the wedged-not-slow signature); after the fix it
/// completes quickly and every task observes its sleep return, however the
/// scheduler happens to interleave registration against the advance.
///
/// Each round is bounded by an explicit timeout: a stranded waiter must fail
/// the test (fewer than 20 completions observed), never wedge the whole
/// suite waiting on `group.waitForAll()` forever. The timeout cancels the
/// round's task, which lets `ManualClock`'s cancellation handling (a
/// separate fix) unwind any still-parked sleeper; a sleep that resolves by
/// throwing `CancellationError` is deliberately NOT counted as completed,
/// since a cancellation-rescued stranding is still a stranding this test
/// exists to catch, not a pass.
final class ManualClockRegistrationRaceTests: XCTestCase {
    private static let perRoundTimeout: Duration = .milliseconds(500)

    func testConcurrentSleepersDoNotStrandAgainstARacingAdvance() async throws {
        for round in 0..<25 {
            try await runRound(round)
        }
    }

    private func runRound(_ round: Int) async throws {
        let clock = ManualClock()
        let referenceNow = clock.now
        let completedCount = CompletedCounter()

        let roundTask = Task {
            await withTaskGroup(of: Void.self) { group in
                for offset in 0..<20 {
                    let deadline = referenceNow.advanced(by: .milliseconds(offset))
                    group.addTask {
                        // Only a sleep that returns normally counts as
                        // "completed": one that throws (including a
                        // cancellation-rescued stranding, see the class
                        // doc comment) must not be mistaken for success.
                        if (try? await clock.sleep(until: deadline, tolerance: nil)) != nil {
                            await completedCount.increment()
                        }
                    }
                }
                group.addTask {
                    await Task.detached {
                        await clock.advance(by: .milliseconds(20))
                    }.value
                }
                await group.waitForAll()
            }
        }

        // Bound the round: if a waiter is genuinely stranded,
        // `group.waitForAll()` above never returns on its own. Cancelling
        // `roundTask` after the timeout lets `ManualClock`'s cancellation
        // handling unwind any parked sleeper instead of hanging the whole
        // test run, and the assertion below still fails on the resulting
        // completion shortfall.
        let timeoutTask = Task {
            try? await Task.sleep(for: Self.perRoundTimeout)
            roundTask.cancel()
        }

        await roundTask.value
        timeoutTask.cancel()

        let finalCount = await completedCount.value
        XCTAssertEqual(
            finalCount, 20,
            "round \(round): a sleeper was stranded by the registration race (\(finalCount)/20 completed within \(Self.perRoundTimeout))"
        )
    }

    private actor CompletedCounter {
        private(set) var value = 0
        func increment() { value += 1 }
    }
}
