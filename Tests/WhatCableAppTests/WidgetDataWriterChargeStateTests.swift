import Foundation
import Testing
import WhatCableCore
import WhatCableDarwinBackend
@testable import WhatCable

/// The widget writer carries the power watcher's published SMC charge state
/// into the App Group snapshot, and a change to that state alone pushes a
/// write.
///
/// The widget extension prefers the app's decided state while the snapshot is
/// fresh, so a writer that dropped it would leave the widget on its own
/// single, undebounced read. The flags in `powerState` must also follow the
/// state, the same way every other surface resolves them.
///
/// Synchronous on the main actor: the shared watcher is set, read and reset
/// with no suspension point between, so no other main-actor test can observe
/// the injected state.
@MainActor
@Suite("Widget writer follows the published charge state")
struct WidgetDataWriterChargeStateTests {

    struct FixedPresenceChecker: WidgetPresenceChecking {
        let installed: Bool
        func hasInstalledWidgets() async -> Bool { installed }
    }

    @Test("The snapshot carries the published state and resolves the flags from it")
    func snapshotCarriesPublishedState() {
        let watcher = WatcherHub.shared.powerWatcher
        let writer = WidgetDataWriter(presenceChecker: FixedPresenceChecker(installed: true))
        defer { watcher.applyChargeState(nil) }

        watcher.applyChargeState(.charging)
        let charging = writer.buildSnapshot().snapshot
        #expect(charging.batteryChargeState == .charging)
        #expect(charging.powerState?.isCharging == true)
        #expect(charging.powerState?.fullyCharged == false)

        watcher.applyChargeState(.chargeLimitReached)
        let limit = writer.buildSnapshot().snapshot
        #expect(limit.batteryChargeState == .chargeLimitReached)
        #expect(limit.powerState?.isCharging == false)
        #expect(limit.powerState?.fullyCharged == false)
    }

    @Test("A change to the charge state alone schedules a write")
    func subscribesToChargeState() {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WhatCableAppTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/WhatCable/Services/WidgetDataWriter.swift")
        let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        #expect(!source.isEmpty, "Could not read WidgetDataWriter.swift; the path has drifted")
        #expect(source.contains("WatcherHub.shared.powerWatcher.$batteryChargeState"),
            "A charge-state change with nothing else changing must push a write, not wait for the heartbeat")
    }
}
