import XCTest
@testable import WhatCable

/// `updateMenuBarPresentation` runs on every `MenuBarContent` change, and that
/// includes the raw watts value ticking ~1 Hz while charging with the readout
/// on. `shouldReanchor` is what stops that tick from touching the popover's
/// `positioningRect` on every call: only a genuine width change should apply
/// (issue behind the v1.5.0-beta.2 popover-won't-close bug).
final class PopoverReanchorTests: XCTestCase {
    func testNeverAnchoredAlwaysReanchors() {
        // nil means the popover hasn't been anchored yet, so the first call
        // must always apply.
        XCTAssertTrue(AppDelegate.shouldReanchor(lastWidth: nil, currentWidth: 42))
    }

    func testUnchangedWidthDoesNotReanchor() {
        XCTAssertFalse(AppDelegate.shouldReanchor(lastWidth: 60, currentWidth: 60))
    }

    func testTinyFloatingPointDriftDoesNotReanchor() {
        // Layout can report a width a fraction of a point off from the last
        // anchor with nothing having actually moved; the epsilon absorbs that.
        XCTAssertFalse(AppDelegate.shouldReanchor(lastWidth: 60.0, currentWidth: 60.2))
    }

    func testRealWidthChangeReanchors() {
        // The watts readout turning on adds ~29pt, well past the epsilon.
        XCTAssertTrue(AppDelegate.shouldReanchor(lastWidth: 60, currentWidth: 89))
    }

    func testJustOverEpsilonReanchors() {
        XCTAssertTrue(AppDelegate.shouldReanchor(lastWidth: 60.0, currentWidth: 60.6))
    }

    func testShrinkingWidthReanchors() {
        // The readout turning off narrows the item; that's a real change too.
        XCTAssertTrue(AppDelegate.shouldReanchor(lastWidth: 89, currentWidth: 60))
    }
}
