import Foundation
import Testing
@testable import WhatCableCore
@testable import WhatCableDarwinBackend

@Suite("PortDiagnosticsWatcher port-key mapping")
struct PortDiagnosticsKeyMapTests {

    // Build a self-keyed PowerSource with a winning contract of `watts` mW.
    private func source(port: Int, type: Int = 2, watts: Int) -> PowerSource {
        PowerSource(
            id: UInt64(port), name: "USB-PD",
            parentPortType: type, parentPortNumber: port, options: [],
            winning: PowerOption(voltageMV: 20000, maxCurrentMA: 5000, maxPowerMW: watts)
        )
    }

    // Build a PortControllerInfo entry dict with the given max power.
    private func entry(maxPowerMW: Int) -> [String: Any] {
        ["PortControllerMaxPower": maxPowerMW]
    }

    // MARK: - Watts-based join for active-contract entries

    @Test("Charger entry maps to the source's port key regardless of array offset")
    func chargerMapsToSourcePort() {
        // Three entries: two idle ports flanking a 100 W charger at offset 2.
        let entries = [entry(maxPowerMW: 0), entry(maxPowerMW: 0), entry(maxPowerMW: 100_000)]
        let portKeys = ["2/1", "2/2", "2/3", "2/4"]
        let sources = [source(port: 4, watts: 100_000)]

        let map = PortDiagnosticsWatcher.portKeyMap(entries: entries, portKeys: portKeys, sources: sources)

        // Offset 2 (the charger) must map to "2/4" (the source's port), not "2/3"
        // (what the old array-offset code would have produced).
        #expect(map[2] == "2/4")
    }

    @Test("Idle entries fall back to positional HPM order (contiguous ports)")
    func idleEntriesUsePositionalFallback() {
        // Four idle ports, no active charge contract.
        let entries = [entry(maxPowerMW: 0), entry(maxPowerMW: 0),
                       entry(maxPowerMW: 0), entry(maxPowerMW: 0)]
        let portKeys = ["2/1", "2/2", "2/3", "2/4"]

        let map = PortDiagnosticsWatcher.portKeyMap(entries: entries, portKeys: portKeys, sources: [])

        // Positional fallback: offset N -> portKeys[N].
        #expect(map[0] == "2/1")
        #expect(map[1] == "2/2")
        #expect(map[2] == "2/3")
        #expect(map[3] == "2/4")
    }

    @Test("Non-contiguous layout: charger at offset 1 maps to port 4, not port 2")
    func nonContiguousChargerLandsOnCorrectPort() {
        // Simulates the bug this fix addresses: PortControllerInfo offset does
        // not match port numbering. The charger is at offset 1 in the array but
        // belongs to port 4 (a non-contiguous assignment).
        let entries = [entry(maxPowerMW: 0), entry(maxPowerMW: 60_000)]
        let portKeys = ["2/1", "2/2"]  // HPM traversal order (not necessarily port order)
        let sources = [source(port: 4, watts: 60_000)]

        let map = PortDiagnosticsWatcher.portKeyMap(entries: entries, portKeys: portKeys, sources: sources)

        // Old offset code: map[1] = portKeys[1] = "2/2" (wrong).
        // Watts join: map[1] = "2/4" (correct).
        #expect(map[1] == "2/4")
        // Idle port at offset 0 still uses positional fallback.
        #expect(map[0] == "2/1")
    }

    @Test("Every entry gets a key when the two signals agree")
    func everyEntryGetsAKey() {
        // Charger at offset 1 on port 2: the watts join and the positional
        // order say the same thing, so nothing is displaced.
        let entries = [entry(maxPowerMW: 0), entry(maxPowerMW: 45_000), entry(maxPowerMW: 0)]
        let portKeys = ["2/1", "2/2", "2/3"]
        let sources = [source(port: 2, watts: 45_000)]

        let map = PortDiagnosticsWatcher.portKeyMap(entries: entries, portKeys: portKeys, sources: sources)

        #expect(map.count == entries.count)
        #expect(map[0] == "2/1")
        #expect(map[1] == "2/2")
        #expect(map[2] == "2/3")
    }

    // MARK: - Collisions between the watts join and positional order

    @Test("A key claimed by the watts join is not handed to a second entry")
    func wattsMatchIsNotOverwrittenByPositionalEntry() {
        // The charger sits at offset 1 but its watts identify port 3, so the
        // watts join puts offset 1 on "2/3". Position would also put offset 2
        // on "2/3". Both cannot be right.
        //
        // Before issue #460 both offsets were written to "2/3" and the caller
        // wrote them into a dictionary in offset order, so offset 2 (a guess)
        // silently overwrote offset 1 (a content-based match). Now the watts
        // match holds the key and the contradicting entry is left unmapped.
        let entries = [entry(maxPowerMW: 0), entry(maxPowerMW: 45_000), entry(maxPowerMW: 0)]
        let portKeys = ["2/1", "2/2", "2/3"]
        let sources = [source(port: 3, watts: 45_000)]

        let map = PortDiagnosticsWatcher.portKeyMap(entries: entries, portKeys: portKeys, sources: sources)

        #expect(map[1] == "2/3")
        #expect(map[2] == nil)
        // The uncontested entry is unaffected.
        #expect(map[0] == "2/1")
    }

    @Test("No two entries ever share a port key")
    func keysAreUnique() {
        let entries = [entry(maxPowerMW: 0), entry(maxPowerMW: 45_000),
                       entry(maxPowerMW: 0), entry(maxPowerMW: 0)]
        let portKeys = ["2/1", "2/2", "2/4", "17/1"]
        let sources = [source(port: 4, watts: 45_000)]

        let map = PortDiagnosticsWatcher.portKeyMap(entries: entries, portKeys: portKeys, sources: sources)

        #expect(Set(map.values).count == map.count)
    }

    @Test("Overflow fallback keys never collide with a real port key")
    func overflowKeyDoesNotCollide() {
        // Two known ports, three entries. The overflow key for offset 2 is
        // "2/3" by construction, which here is also a real port key already
        // taken positionally... except it isn't in portKeys, so it is free.
        // The collision case is offset 1 being pinned to "2/3" by watts.
        let entries = [entry(maxPowerMW: 0), entry(maxPowerMW: 30_000), entry(maxPowerMW: 0)]
        let portKeys = ["2/1", "2/2"]
        let sources = [source(port: 3, watts: 30_000)]

        let map = PortDiagnosticsWatcher.portKeyMap(entries: entries, portKeys: portKeys, sources: sources)

        #expect(map[1] == "2/3")
        // Offset 2's overflow key would be "2/3", already claimed, so it is
        // dropped rather than clobbering the watts match.
        #expect(map[2] == nil)
        #expect(Set(map.values).count == map.count)
    }

    @Test("Overflow entries beyond known HPM ports get a best-effort fallback key")
    func overflowEntriesGetFallbackKey() {
        // Two HPM port keys but three PortControllerInfo entries.
        let entries = [entry(maxPowerMW: 0), entry(maxPowerMW: 0), entry(maxPowerMW: 0)]
        let portKeys = ["2/1", "2/2"]

        let map = PortDiagnosticsWatcher.portKeyMap(entries: entries, portKeys: portKeys, sources: [])

        #expect(map[0] == "2/1")
        #expect(map[1] == "2/2")
        // Offset 2 exceeds portKeys: gets "2/3" (1-based fallback).
        #expect(map[2] == "2/3")
    }

    // MARK: - No trustworthy port order

    @Test("With no port order, only the wattage-matched entry is placed")
    func noPortOrderPlacesOnlyTheWattsMatch() {
        // An empty portKeys list is `hpmPortKeysRIDOrdered()` refusing to
        // answer, because it could not establish the order Apple built
        // PortControllerInfo in. The charger can still be placed: that comes
        // from wattage, not position. Everything else must be left alone.
        let entries = [entry(maxPowerMW: 0), entry(maxPowerMW: 60_000), entry(maxPowerMW: 0)]
        let sources = [source(port: 2, watts: 60_000)]

        let map = PortDiagnosticsWatcher.portKeyMap(entries: entries, portKeys: [], sources: sources)

        #expect(map[1] == "2/2")
        // No invented "2/1" / "2/3" keys: real counters under a fabricated port
        // name are indistinguishable from a real reading.
        #expect(map[0] == nil)
        #expect(map[2] == nil)
        #expect(map.count == 1)
    }

    @Test("With no port order and no charger, nothing is placed")
    func noPortOrderNoChargerPlacesNothing() {
        let entries = [entry(maxPowerMW: 0), entry(maxPowerMW: 0)]

        let map = PortDiagnosticsWatcher.portKeyMap(entries: entries, portKeys: [], sources: [])

        #expect(map.isEmpty)
    }

    @Test("Empty entries produce an empty map")
    func emptyEntriesEmptyMap() {
        let map = PortDiagnosticsWatcher.portKeyMap(entries: [], portKeys: ["2/1"], sources: [])
        #expect(map.isEmpty)
    }

    @Test("Ambiguous wattage (two ports at same watts) falls back to positional")
    func ambiguousWattsFallsBackToPositional() {
        // Two ports both receiving 60 W: watts-join is ambiguous and omits the
        // entry. The positional fallback should still assign a key.
        let entries = [entry(maxPowerMW: 60_000)]
        let portKeys = ["2/1"]
        let sources = [source(port: 1, watts: 60_000), source(port: 2, watts: 60_000)]

        let map = PortDiagnosticsWatcher.portKeyMap(entries: entries, portKeys: portKeys, sources: sources)

        // Watts join skips the ambiguous entry; positional fallback covers it.
        #expect(map[0] == "2/1")
    }
}
