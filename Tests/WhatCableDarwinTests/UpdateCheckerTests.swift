import Testing
@testable import WhatCableCore

@Suite("Update Checker")
struct UpdateCheckerTests {
    @Test("Remote is newer")
    func remoteIsNewer() {
        #expect(AppInfo.isNewer(remote: "0.4.0", current: "0.3.1"))
        #expect(AppInfo.isNewer(remote: "0.3.2", current: "0.3.1"))
        #expect(AppInfo.isNewer(remote: "1.0.0", current: "0.99.99"))
    }

    @Test("Remote is older or equal")
    func remoteIsOlderOrEqual() {
        #expect(!AppInfo.isNewer(remote: "0.3.0", current: "0.3.1"))
        #expect(!AppInfo.isNewer(remote: "0.3.1", current: "0.3.1"))
        #expect(!AppInfo.isNewer(remote: "0.2.9", current: "0.3.0"))
    }

    @Test("Different lengths")
    func differentLengths() {
        #expect(!AppInfo.isNewer(remote: "0.4", current: "0.4.0"))
        #expect(!AppInfo.isNewer(remote: "0.4.0", current: "0.4"))
        #expect(AppInfo.isNewer(remote: "0.4.1", current: "0.4"))
    }

    @Test("Dev fallback")
    func devFallback() {
        #expect(AppInfo.isNewer(remote: "0.3.0", current: "dev"))
    }

    @Test("Stable beats its own beta")
    func stableBeatsOwnBeta() {
        #expect(AppInfo.isNewer(remote: "1.2.0", current: "1.2.0-beta.1"))
    }

    @Test("Beta does not beat its own stable")
    func betaDoesNotBeatOwnStable() {
        #expect(!AppInfo.isNewer(remote: "1.2.0-beta.1", current: "1.2.0"))
    }

    @Test("Later beta beats earlier beta")
    func laterBetaBeatsEarlierBeta() {
        #expect(AppInfo.isNewer(remote: "1.2.0-beta.2", current: "1.2.0-beta.1"))
    }

    @Test("Same beta is not newer")
    func sameBetaIsNotNewer() {
        #expect(!AppInfo.isNewer(remote: "1.2.0-beta.1", current: "1.2.0-beta.1"))
    }

    @Test("Beta of a later version beats an older stable")
    func betaOfLaterVersionBeatsOlderStable() {
        #expect(AppInfo.isNewer(remote: "1.2.0-beta.1", current: "1.1.9"))
    }

    @Test("Older stable does not beat a beta of a later version")
    func olderStableDoesNotBeatBetaOfLaterVersion() {
        #expect(!AppInfo.isNewer(remote: "1.1.9", current: "1.2.0-beta.1"))
    }

    @Test("Next stable beats a beta of the previous version")
    func nextStableBeatsBetaOfPreviousVersion() {
        #expect(AppInfo.isNewer(remote: "1.2.1", current: "1.2.0-beta.1"))
    }
}
