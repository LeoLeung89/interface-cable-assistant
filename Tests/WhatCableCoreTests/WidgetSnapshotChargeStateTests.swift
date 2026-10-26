import Foundation
import Testing
@testable import WhatCableCore

/// The app writes its decided, debounced charge state into the App Group
/// snapshot; the widget prefers it while the snapshot is fresh.
@Suite("Widget snapshot charge state")
struct WidgetSnapshotChargeStateTests {
    private func roundTrip(_ s: WidgetSnapshot) throws -> WidgetSnapshot {
        try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(s))
    }

    @Test("chargeState survives an encode and decode")
    func roundTripKeepsState() throws {
        let s = WidgetSnapshot(ports: [], timestamp: Date(timeIntervalSince1970: 1_000), chargeState: .chargeLimitReached)
        let back = try roundTrip(s)
        #expect(back == s)
        #expect(back.chargeState == "chargeLimitReached")
        #expect(back.batteryChargeState == .chargeLimitReached)
    }

    @Test("A file written before the field existed decodes with no state")
    func oldFileDecodes() throws {
        let json = #"{"ports":[],"timestamp":0}"#
        let s = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(json.utf8))
        #expect(s.chargeState == nil && s.batteryChargeState == nil)
    }

    @Test("An unknown raw value decodes, and reads as no state")
    func unknownRawValue() throws {
        let json = #"{"ports":[],"timestamp":0,"chargeState":"somethingNewer"}"#
        let s = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(json.utf8))
        #expect(s.chargeState == "somethingNewer")
        #expect(s.batteryChargeState == nil)
    }

    @Test("A fresh snapshot's state wins, nil included; stale, future or missing means read live")
    func preference() {
        let now = Date(timeIntervalSince1970: 10_000)
        func cached(age: TimeInterval, _ state: BatteryChargeState?) -> WidgetSnapshot {
            WidgetSnapshot(ports: [], timestamp: now.addingTimeInterval(-age), chargeState: state)
        }
        #expect(WidgetSnapshot.chargeStateSource(cached: cached(age: 30, .runningOnBattery), now: now) == .app(.runningOnBattery))
        #expect(WidgetSnapshot.chargeStateSource(cached: cached(age: 120, .charging), now: now) == .app(.charging))
        // The app decided "no state" (no keys, or not yet published): respect it.
        #expect(WidgetSnapshot.chargeStateSource(cached: cached(age: 30, nil), now: now) == .app(nil))
        #expect(WidgetSnapshot.chargeStateSource(cached: cached(age: 120.5, .charging), now: now) == .live)
        #expect(WidgetSnapshot.chargeStateSource(cached: cached(age: -5, .charging), now: now) == .live)
        #expect(WidgetSnapshot.chargeStateSource(cached: nil, now: now) == .live)
    }
}
