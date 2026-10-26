import Foundation
import WhatCableCore

/// Watches each live port's fault counters across one connection and turns
/// rises into `ConnectionDiagnostic` banners for the `PortCard`. This is the
/// stateful half of the mid-session fault banner: `SessionDelta` /
/// `ConnectionDiagnostic` are pure
/// and clock-free in `WhatCableCore`; this object owns the per-port baseline
/// (snapshot when a port goes live) and the clock, and resets when the port
/// goes idle. No persistence: a discarded baseline is gone.
///
/// `@MainActor` because it is observed by SwiftUI and only ever touched from
/// the main run loop's refresh tick. Marking the whole class `@MainActor` is
/// the Swift way of saying "all of this runs on the main thread", which is
/// what an `ObservableObject` driving the UI wants.
@MainActor
final class ConnectionFaultTracker: ObservableObject {
    private struct Baseline {
        let counters: ConnectionCounters
        let start: Date
    }

    /// The current banner per port key. Published so the `PortCard` updates the
    /// moment a fault appears or clears.
    @Published private(set) var diagnostics: [String: ConnectionDiagnostic] = [:]

    private var baselines: [String: Baseline] = [:]
    /// Injectable clock so tests can drive elapsed time without sleeping.
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Fold one refresh tick.
    ///
    /// - Parameters:
    ///   - ports: every port the watchers currently see.
    ///   - liveKeys: the port keys the app considers genuinely connected (its
    ///     authoritative `isPortLive` signal, stricter than the raw
    ///     `connectionActive` flag). A port not in `liveKeys` has its baseline
    ///     discarded, which is the spec's "reset on `connectionActive` false".
    func ingest(ports: [AppleHPMInterface], liveKeys: Set<String>) {
        var nextDiagnostics: [String: ConnectionDiagnostic] = [:]
        var presentKeys: Set<String> = []

        for port in ports {
            guard let key = port.portKey else { continue }
            presentKeys.insert(key)
            let current = ConnectionCounters(port: port)

            guard liveKeys.contains(key) else {
                // Port idle: drop its baseline so the next connection starts
                // clean and two cables never share counter history.
                baselines[key] = nil
                continue
            }

            guard let baseline = baselines[key] else {
                // First live tick for this connection: this reading is the
                // baseline, never itself a fault.
                baselines[key] = Baseline(counters: current, start: now())
                continue
            }

            let delta = SessionDelta(baseline: baseline.counters, current: current)
            let elapsed = now().timeIntervalSince(baseline.start)
            // Same MagSafe predicate `isPortLive` and `AppleHPMInterface.from`
            // use, so all three agree on what counts as a MagSafe port.
            let isMagSafe = port.portTypeDescription?.hasPrefix("MagSafe") == true
            if let diagnostic = ConnectionDiagnostic(
                delta: delta,
                elapsedSeconds: elapsed,
                isMagSafe: isMagSafe
            ) {
                nextDiagnostics[key] = diagnostic
            }
        }

        // Forget baselines for ports that vanished entirely (an unplug can
        // remove the IOKit node), so the dictionary can't grow without bound.
        baselines = baselines.filter { presentKeys.contains($0.key) }

        // Only republish when the banners actually changed. Between minute
        // boundaries a steady fault produces an identical diagnostic, so this
        // skips the reassignment and the view stays put. When the "in the last
        // N minutes" window does tick over, the detail string changes and we
        // republish on purpose, so the window stays current.
        if nextDiagnostics != diagnostics {
            diagnostics = nextDiagnostics
        }
    }

    func diagnostic(for portKey: String?) -> ConnectionDiagnostic? {
        guard let portKey else { return nil }
        return diagnostics[portKey]
    }
}
