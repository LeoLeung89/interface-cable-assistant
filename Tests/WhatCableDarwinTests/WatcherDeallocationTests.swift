import Foundation
import Testing
@testable import WhatCableDarwinBackend

/// Proves a started watcher can still be deallocated when its owner lets go.
///
/// `PowerService.start()` used to spawn its poll loop as
/// `Task { @MainActor in ... refresh() ... }`. A bare `refresh()` captures self
/// strongly, and self holds `pollTask`, so the two kept each other alive: the
/// object could only ever be freed if someone remembered to call `stop()`
/// first. Every sibling watcher captured weakly; this one did not.
///
/// It was dormant because all four call sites do call `stop()`, but
/// `PowerMonitorWindow`'s does so from SwiftUI's `.onDisappear`, which is a
/// convention rather than a guarantee. If it were ever skipped, the 1 Hz IOKit
/// and SMC reads would run against an unreachable object until the process
/// exited.
///
/// This is a real deallocation test, not a source-level one: it starts the
/// watcher, drops the only strong reference WITHOUT calling `stop()`, and
/// checks the weak reference clears. Reverting the `[weak self]` capture makes
/// it fail.
@Suite("Watcher deallocation")
@MainActor
struct WatcherDeallocationTests {

    @Test("A started PowerService deallocates when its owner drops it without stop()")
    func powerTelemetryWatcherDeallocatesWithoutStop() async {
        weak var weakWatcher: PowerService?

        // Inner scope so the strong reference is definitely gone at the end of
        // it, rather than lingering in this function's frame.
        do {
            let watcher = PowerService()
            weakWatcher = watcher
            watcher.start()
            #expect(weakWatcher != nil, "sanity: the watcher should be alive while a strong reference is held")
            // Deliberately NO stop(). That is the whole point: the leak only
            // showed when an owner relied on deinit instead of calling stop().
        }

        // Give the runtime a turn so the release actually lands. The poll task
        // is mid-`Task.sleep`, and with `[weak self]` it holds nothing, so the
        // object is free the moment the last strong reference goes.
        await Task.yield()

        #expect(weakWatcher == nil, """
            PowerService was still alive after its only strong reference was dropped. \
            Its poll task is retaining it, so the 1 Hz IOKit and SMC reads keep running against \
            an object nobody can reach or stop. Capture [weak self] in the start() poll loop.
            """)
    }

    @Test("It deallocates even when dropped while the poll loop is mid-sleep")
    func deallocatesWhileTaskIsSleeping() async throws {
        // The case the other two tests do NOT reach, and the one that actually
        // happens in the field.
        //
        // Both of those drop the reference with no `await` in between, and this
        // class and this test are both @MainActor, so the poll task never gets
        // scheduled at all before the drop. That passes without ever exercising
        // a sleeping task. An adversarial review caught exactly that, and with
        // it a real defect: binding `guard let self` at the top of the loop body
        // held a strong reference across the sleep, so the watcher survived up
        // to a full poll interval after its owner let go. Since the task is
        // asleep for essentially the whole of a 1 Hz cycle, that was the normal
        // case, not an edge one.
        weak var weakWatcher: PowerService?
        do {
            let watcher = PowerService()
            weakWatcher = watcher
            watcher.start()
            // Long enough for the task to run its first refresh and reach the
            // sleep, well short of the 1s interval that would wake it again.
            try await Task.sleep(nanoseconds: 200_000_000)
            #expect(weakWatcher != nil, "sanity: still held here")
        }
        // Deliberately far below the 1s poll interval: if this only passes
        // after a wake-up, the strong reference is spanning the sleep again.
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(weakWatcher == nil, """
            The watcher outlived its owner while its poll task was sleeping. The strong `self` \
            bound inside the loop is spanning the `await`, so the object cannot be freed until \
            the next wake, up to a full poll interval later. Sleep first, then bind self, so the \
            strong reference only covers the synchronous refresh().
            """)
    }

    @Test("Its poll task is cancelled eagerly by deinit, not left sleeping")
    func powerTelemetryWatcherCancelsPollOnDeinit() async {
        // Distinct from the test above: that one proves the object CAN die,
        // this one proves the work ends with it rather than after a delay.
        //
        // Precise about what is at stake, because it is easy to overstate:
        // without the deinit the task does NOT run forever. It wakes from its
        // current sleep (up to one poll interval), finds self nil and returns.
        // The deinit makes that immediate instead. The [weak self] capture is
        // what bounds the work; this is tidiness on top of it.
        var watcher: PowerService? = PowerService()
        watcher?.start()
        let task = watcher?.pollTaskForTesting
        #expect(task != nil, "sanity: start() should have created a poll task")
        #expect(task?.isCancelled == false, "sanity: the poll task should be running while the watcher is alive")

        watcher = nil
        await Task.yield()

        #expect(task?.isCancelled == true, """
            The poll task was not cancelled by its watcher's deinit, so it is left sleeping \
            until its next wake before noticing. Add `deinit { pollTask?.cancel() }` so \
            dropping the last reference ends the work at once.
            """)
    }
}
