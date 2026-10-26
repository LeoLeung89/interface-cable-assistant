import Foundation
import Testing
@testable import WhatCableCore
@testable import WhatCableDarwinBackend

/// "Running on battery" is published only once every read has produced it for
/// at least 2.0 s (monotonic clock, from the first such read). Any other read
/// resets the window. Every other state, and nil (fall back to the battery
/// record), publishes at once.
@Suite("Battery charge state debounce")
struct BatteryChargeStateDebounceTests {
    private typealias W = PowerSourceWatcher

    @Test("Two running-on-battery reads 350 ms apart do not publish it")
    func burstDoesNotPublish() {
        let first = W.debouncedChargeState(raw: .runningOnBattery, now: 10.0, runningSince: nil, published: nil)
        #expect(first.published == nil && first.runningSince == 10.0)
        let second = W.debouncedChargeState(raw: .runningOnBattery, now: 10.35, runningSince: first.runningSince, published: first.published)
        #expect(second.published == nil)
        let held = W.debouncedChargeState(raw: .runningOnBattery, now: 10.35, runningSince: 10.0, published: .charging)
        #expect(held.published == .charging)
    }

    @Test("Reads spanning at least 2 s publish it; just under does not")
    func twoSecondsPublish() {
        #expect(W.debouncedChargeState(raw: .runningOnBattery, now: 11.99, runningSince: 10.0, published: .charging).published == .charging)
        let at = W.debouncedChargeState(raw: .runningOnBattery, now: 12.0, runningSince: 10.0, published: .charging)
        #expect(at.published == .runningOnBattery && at.runningSince == 10.0)
    }

    @Test("An interrupted run resets the window")
    func interruptionResets() {
        var r = W.debouncedChargeState(raw: .runningOnBattery, now: 0.0, runningSince: nil, published: .charging)
        r = W.debouncedChargeState(raw: .charging, now: 1.0, runningSince: r.runningSince, published: r.published)
        #expect(r.published == .charging && r.runningSince == nil)
        r = W.debouncedChargeState(raw: .runningOnBattery, now: 1.5, runningSince: r.runningSince, published: r.published)
        r = W.debouncedChargeState(raw: .runningOnBattery, now: 3.0, runningSince: r.runningSince, published: r.published)
        #expect(r.published == .charging, "3.0 s after the first read but only 1.5 s into this run")
        r = W.debouncedChargeState(raw: .runningOnBattery, now: 3.5, runningSince: r.runningSince, published: r.published)
        #expect(r.published == .runningOnBattery)
    }

    @Test("Every other state, and nil, publishes on its first read and clears the window")
    func othersImmediate() {
        for state in [BatteryChargeState.notPluggedIn, .charging, .full, .onHold, .chargeLimitReached] {
            let r = W.debouncedChargeState(raw: state, now: 5.0, runningSince: 1.0, published: .runningOnBattery)
            #expect(r.published == state && r.runningSince == nil)
        }
        let none = W.debouncedChargeState(raw: nil, now: 5.0, runningSince: 1.0, published: .charging)
        #expect(none.published == nil && none.runningSince == nil)
    }

    /// A clock the test moves by hand.
    private final class FakeClock { var now: TimeInterval = 100 }

    @MainActor @Test("The watcher applies the window with its injected clock")
    func watcherSequence() {
        let clock = FakeClock()
        let w = PowerSourceWatcher(smcReader: SMCPowerReader(), clock: { clock.now })
        w.applyChargeState(.charging)
        #expect(w.batteryChargeState == .charging)
        w.applyChargeState(.runningOnBattery)
        clock.now += 0.35
        w.applyChargeState(.runningOnBattery)
        #expect(w.batteryChargeState == .charging)
        clock.now += 1.65
        w.applyChargeState(.runningOnBattery)
        #expect(w.batteryChargeState == .runningOnBattery)
        w.stop()
        #expect(w.batteryChargeState == nil)
    }

    // MARK: - One-shot confirm read (CLI single read, widget live path)

    /// Counts second reads and records sleeps; nothing really sleeps.
    private final class Recorder { var reads = 0; var slept: [TimeInterval] = [] }

    @Test("Confirm: a second running-on-battery read after 2 s publishes it")
    func confirmAgrees() async {
        let rec = Recorder()
        let state = await W.confirmedOneShotChargeState(
            first: .runningOnBattery,
            readAgain: { rec.reads += 1; return .runningOnBattery },
            sleep: { rec.slept.append($0) })
        #expect(state == .runningOnBattery)
        #expect(rec.reads == 1 && rec.slept == [2.0])
    }

    @Test("Confirm: a second read that disagrees is used instead")
    func confirmDisagrees() async {
        for second in [BatteryChargeState.charging, .notPluggedIn, nil] as [BatteryChargeState?] {
            let rec = Recorder()
            let state = await W.confirmedOneShotChargeState(
                first: .runningOnBattery,
                readAgain: { rec.reads += 1; return second },
                sleep: { rec.slept.append($0) })
            #expect(state == second)
            #expect(rec.reads == 1 && rec.slept == [2.0])
        }
    }

    @Test("Confirm: any other first read is used at once, with no sleep and no second read")
    func confirmSkipsOtherStates() async {
        let firsts: [BatteryChargeState?] = [nil, .notPluggedIn, .charging, .full, .onHold, .chargeLimitReached]
        for first in firsts {
            let rec = Recorder()
            let state = await W.confirmedOneShotChargeState(
                first: first,
                readAgain: { rec.reads += 1; return .runningOnBattery },
                sleep: { rec.slept.append($0) })
            #expect(state == first)
            #expect(rec.reads == 0 && rec.slept.isEmpty)
        }
    }
}
