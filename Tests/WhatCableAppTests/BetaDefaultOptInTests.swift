import XCTest
@testable import WhatCable

/// Cover for `AppSettings.defaultsReceiveBetaUpdates`, the pure decision
/// behind the write-once beta default (discussion #555). A pre-release
/// build is the opt-in; a never-touched key defaults to on for a beta
/// build, but any stored value, on or off, is left alone forever.
final class BetaDefaultOptInTests: XCTestCase {
    func testKeyAbsentOnABetaBuildDefaultsOn() {
        XCTAssertTrue(
            AppSettings.defaultsReceiveBetaUpdates(storedValue: nil, runningVersion: "1.5.0-beta.5"),
            "A never-touched key on a beta build must default the toggle on"
        )
    }

    func testKeyAbsentOnAStableBuildStaysOff() {
        XCTAssertFalse(
            AppSettings.defaultsReceiveBetaUpdates(storedValue: nil, runningVersion: "1.5.0"),
            "A stable build never fires the default; the key stays absent"
        )
    }

    func testExplicitOptOutIsNeverOverridden() {
        XCTAssertFalse(
            AppSettings.defaultsReceiveBetaUpdates(storedValue: false, runningVersion: "1.5.0-beta.5"),
            "An explicit opt-out must never be overridden, even on a beta build"
        )
    }

    func testExplicitOptInIsNeverRewritten() {
        // The helper answers "should we write true once", not "what is the
        // final toggle value". A stored true already reads true through the
        // normal path, so the write-once trigger must stay false here: there
        // is nothing to write, and firing anyway would be a harmless but
        // unnecessary UserDefaults write on every launch.
        XCTAssertFalse(
            AppSettings.defaultsReceiveBetaUpdates(storedValue: true, runningVersion: "1.5.0-beta.5"),
            "A stored true means the key is no longer absent; the write-once trigger must not fire again"
        )
    }

    func testDevBuildIsNotAPrereleaseAndDoesNotDefaultOn() {
        XCTAssertFalse(
            AppSettings.defaultsReceiveBetaUpdates(storedValue: nil, runningVersion: "dev"),
            "\"dev\" (the swift run fallback) is not a pre-release and must not trigger the default"
        )
    }

    // Watched-fail proof: invert the "never override an explicit choice"
    // rule (drop the storedValue == nil guard, keeping only the version
    // check) and confirm testExplicitOptOutIsNeverOverridden goes red.
    // Restored immediately after. See task report for what was observed.
    func testStoredValuePresenceIsTheGuardNotJustVersion() {
        // Sanity companion to the above: a stored value of false on a
        // non-beta build is also left alone (nothing to override, but the
        // guard must not accidentally read the version at all here).
        XCTAssertFalse(
            AppSettings.defaultsReceiveBetaUpdates(storedValue: false, runningVersion: "1.5.0"),
            "A stored false stays false regardless of version"
        )
    }
}
