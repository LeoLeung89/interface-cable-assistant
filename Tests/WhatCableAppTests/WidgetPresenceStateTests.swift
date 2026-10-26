import Testing
@testable import WhatCable

/// Tests for `WidgetPresenceState`, the pure gate `WidgetDataWriter` uses to
/// decide whether the widget cache file needs writing at all.
///
/// The file's only consumers are widget extension processes (see
/// `CableTimelineProvider`, `PowerTimelineProvider`, `PortChoice`, all
/// read-only). When nothing is installed there is nobody to read it, so the
/// writer should skip both the file write and the WidgetKit reload.
@Suite("WidgetPresenceState")
struct WidgetPresenceStateTests {

    @Test("Before any presence check has completed, writes proceed (fail-safe default)")
    func unknownDefaultsToWrite() {
        let state = WidgetPresenceState()
        #expect(state.installed == nil)
        #expect(state.shouldWrite)
    }

    @Test("A confirmed 'widgets installed' result allows writes")
    func installedAllowsWrite() {
        var state = WidgetPresenceState()
        state.update(installed: true)
        #expect(state.shouldWrite)
    }

    @Test("A confirmed 'no widgets installed' result blocks writes")
    func noneInstalledBlocksWrite() {
        var state = WidgetPresenceState()
        state.update(installed: false)
        #expect(!state.shouldWrite)
    }

    @Test("The first presence result, even 'false', is not reported as a flip")
    func firstResultIsNeverAFlip() {
        var state = WidgetPresenceState()
        let flippedFalse = state.update(installed: false)
        #expect(!flippedFalse)

        var state2 = WidgetPresenceState()
        let flippedTrue = state2.update(installed: true)
        #expect(!flippedTrue)
    }

    @Test("Going from known-none-installed to installed is reported as a flip")
    func noneToSomeIsAFlip() {
        var state = WidgetPresenceState()
        state.update(installed: false)
        let flipped = state.update(installed: true)
        #expect(flipped)
        #expect(state.shouldWrite)
    }

    @Test("Going from installed to none is not a 'flip to installed'")
    func someToNoneIsNotAFlipToInstalled() {
        var state = WidgetPresenceState()
        state.update(installed: true)
        let flipped = state.update(installed: false)
        #expect(!flipped)
        #expect(!state.shouldWrite)
    }

    @Test("Repeating the same result never reports a flip")
    func repeatingSameResultIsNotAFlip() {
        var state = WidgetPresenceState()
        state.update(installed: true)
        let flippedAgain = state.update(installed: true)
        #expect(!flippedAgain)

        var state2 = WidgetPresenceState()
        state2.update(installed: false)
        let flippedAgain2 = state2.update(installed: false)
        #expect(!flippedAgain2)
    }
}
