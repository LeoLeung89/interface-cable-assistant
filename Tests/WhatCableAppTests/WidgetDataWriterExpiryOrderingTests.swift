import Testing
@testable import WhatCable

/// Regression test for a gate finding (Codex): `performScheduledWrite()`'s
/// expiry-scheduling call used to sit AFTER the structural-signature dedup
/// early return. A replug during the e-marker read window restamps the
/// connection session (a fresh age) but can render a subtitle byte-identical
/// to what's already cached ("Reading cable details..." both times), so the
/// dedup fires and the write is skipped. With scheduling gated on the same
/// early return, the earlier session's now-stale pending expiry task would
/// fire, find nothing changed (same dedup), and schedule nothing further:
/// the widget cache could show "Reading..." until the next 60s heartbeat
/// instead of the new session's own, earlier expiry.
///
/// The fix moves `scheduleExpiryWriteIfNeeded(remaining:)` before the dedup
/// check, unconditional on its outcome, so the bookkeeping always reflects
/// the freshest computed age even when the write itself is skipped.
///
/// `writeToDefaults` always fails in the test process (no App Group
/// entitlement), so `lastSnapshot` never gets set by a real write. This test
/// primes it directly via `primeLastSnapshotForTesting(_:)` with a REAL
/// snapshot from `buildSnapshot()`, so `performScheduledWrite()`'s own dedup
/// branch (`snapshot.structuralSignature == lastSnapshot?.structuralSignature`)
/// is the one actually exercised, not a reimplementation of it.
@MainActor
@Suite("WidgetDataWriter expiry scheduling ordering (gate finding regression)")
struct WidgetDataWriterExpiryOrderingTests {

    struct FixedPresenceChecker: WidgetPresenceChecking {
        let installed: Bool
        func hasInstalledWidgets() async -> Bool { installed }
    }

    @Test("A structurally-deduped write still runs the expiry bookkeeping")
    func dedupedWriteStillReschedulesExpiry() {
        let writer = WidgetDataWriter(presenceChecker: FixedPresenceChecker(installed: true))

        // Prime the cache with a snapshot structurally identical to what
        // performScheduledWrite() is about to build (same empty port list
        // in the test environment), so its dedup check fires.
        let (primedSnapshot, _) = writer.buildSnapshot()
        writer.primeLastSnapshotForTesting(primedSnapshot)

        let wrote = writer.performScheduledWrite()

        #expect(!wrote, "Fixture setup check: an identical structural signature must hit the dedup early return")
        #expect(
            writer.scheduleExpiryWriteCallCountForTesting == 1,
            "Expiry bookkeeping must run even though the write itself was deduped away"
        )
    }
}
