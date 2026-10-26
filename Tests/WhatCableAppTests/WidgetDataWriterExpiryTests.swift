import Testing
import WhatCableCore
@testable import WhatCable

/// Tests for `WidgetDataWriter.readingWindowRemaining(ages:)`, the pure
/// arithmetic behind the widget cache's expiry rewrite (spec section 4: a
/// snapshot written while a port is still inside `PortSummary
/// .emarkerReadWindow` gets one scheduled rewrite so the cache never freezes
/// a premature "No e-marker response" verdict).
///
/// Scheduling the rewrite itself (`Task.sleep` + `scheduleWrite()`) is not
/// exercised here: it depends on `WatcherHub.shared`'s live port list, which
/// a unit test cannot inject ports into without a real IOKit environment.
/// This is the honest gap flagged in the PR: the wiring that fires the
/// rewrite gets a manual live check; this file pins the arithmetic that
/// decides WHEN it should fire, which is where the actual bug risk lives
/// (the "youngest port governs" rule).
@Suite("WidgetDataWriter reading-window expiry arithmetic")
struct WidgetDataWriterExpiryTests {

    @Test("No ports inside the window: nothing to schedule")
    func noReadingPortsScheduleNothing() {
        let remaining = WidgetDataWriter.readingWindowRemaining(ages: [nil, 7.0, 6.0, 10.0])
        #expect(remaining == nil)
    }

    @Test("A single port inside the window schedules at its own remaining time")
    func singleReadingPortSchedulesItsOwnRemaining() {
        let remaining = WidgetDataWriter.readingWindowRemaining(ages: [2.0])
        #expect(remaining == PortSummary.emarkerReadWindow - 2.0)
    }

    @Test("Multiple reading-window ports: the YOUNGEST (smallest age, largest remaining) governs")
    func youngestPortGovernsAmongMultiple() {
        // age 1.0 -> remaining 5.0 (youngest, latest to resolve)
        // age 4.0 -> remaining 2.0
        // nil, 7.0 -> not in the window at all
        let remaining = WidgetDataWriter.readingWindowRemaining(ages: [4.0, 1.0, nil, 7.0])
        #expect(remaining == PortSummary.emarkerReadWindow - 1.0)
    }

    @Test("A port exactly at the window boundary is post-window, not reading (age < window, not <=)")
    func boundaryAgeIsPostWindow() {
        let remaining = WidgetDataWriter.readingWindowRemaining(ages: [PortSummary.emarkerReadWindow])
        #expect(remaining == nil)
    }

    @Test("Just under the boundary is still reading")
    func justUnderBoundaryIsReading() {
        let age = PortSummary.emarkerReadWindow - 0.01
        let remaining = WidgetDataWriter.readingWindowRemaining(ages: [age])
        #expect(remaining != nil)
        #expect(remaining! > 0)
    }
}
