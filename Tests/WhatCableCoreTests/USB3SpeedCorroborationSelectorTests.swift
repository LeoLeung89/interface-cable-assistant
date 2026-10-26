import Testing
@testable import WhatCableCore

/// Unit coverage for `USB3SpeedCorroboration.selectedTransport`'s tie
/// policy (issue #181, round-5 fix: match STRENGTH first, then a total
/// ordering). Every case is run in BOTH array orders and must pick the
/// same winner, per the spec's requirement. Complements
/// `USB3SelectorCharacterisationTests` (which covers tunnelled vs direct
/// exclusion) with the strength/UUID-validity dimension a review pass
/// found untested: identical UUID+portKey, exact-UUID vs nil-UUID sharing
/// a portKey, and exact-UUID vs invalid-UUID sharing a portKey.
@Suite("USB3SpeedCorroboration selector: tie policy")
struct USB3SpeedCorroborationSelectorTests {

    private let validUUID = "12345678-1234-1234-1234-123456789ABC"

    private func port(uuid: String? = nil) -> AppleHPMInterface {
        AppleHPMInterface(
            id: 1,
            serviceName: "Port-USB-C@1",
            className: "AppleHPMInterfaceType10",
            portDescription: nil,
            portTypeDescription: "USB-C",
            portNumber: 1,
            connectionActive: true,
            activeCable: nil,
            opticalCable: nil,
            usbActive: nil,
            superSpeedActive: nil,
            usbModeType: nil,
            usbConnectString: nil,
            transportsSupported: ["CC", "USB2", "USB3"],
            transportsActive: ["USB3"],
            transportsProvisioned: [],
            plugOrientation: nil,
            plugEventCount: nil,
            connectionCount: nil,
            overcurrentCount: nil,
            pinConfiguration: [:],
            powerCurrentLimits: [],
            firmwareVersion: nil,
            bootFlagsHex: nil,
            hpmControllerUUID: uuid,
            rawProperties: [:]
        )
    }

    // MARK: - Identical UUID + portKey pair

    @Test("Identical UUID+portKey pair: lower registry id wins, both array orders")
    func identicalUUIDAndPortKeyPairLowerIDWins() {
        let a = USB3Transport(
            id: 10, portKey: "2/1", signaling: 1,
            signalingDescription: "Gen 1", dataRole: "host",
            hpmControllerUUID: validUUID
        )
        let b = USB3Transport(
            id: 20, portKey: "2/1", signaling: 2,
            signalingDescription: "Gen 2", dataRole: "host",
            hpmControllerUUID: validUUID
        )
        let p = port(uuid: validUUID)

        let order1 = USB3SpeedCorroboration.selectedTransport(for: p, in: [a, b])
        let order2 = USB3SpeedCorroboration.selectedTransport(for: p, in: [b, a])

        #expect(order1?.id == 10, "expected the lower registry id to win, got \(String(describing: order1?.id))")
        #expect(order2?.id == 10, "expected the lower registry id to win, got \(String(describing: order2?.id))")
        #expect(order1?.id == order2?.id, "order must not change the winner")
    }

    // MARK: - Exact-UUID vs nil-UUID, sharing a portKey

    @Test("Exact-UUID beats nil-UUID sharing a portKey, both array orders")
    func exactUUIDBeatsNilUUIDSharingPortKey() {
        let exact = USB3Transport(
            id: 30, portKey: "2/1", signaling: 1,
            signalingDescription: "Gen 1", dataRole: "host",
            hpmControllerUUID: validUUID
        )
        let noUUID = USB3Transport(
            id: 31, portKey: "2/1", signaling: 2,
            signalingDescription: "Gen 2", dataRole: "host",
            hpmControllerUUID: nil
        )
        let p = port(uuid: validUUID)

        let order1 = USB3SpeedCorroboration.selectedTransport(for: p, in: [exact, noUUID])
        let order2 = USB3SpeedCorroboration.selectedTransport(for: p, in: [noUUID, exact])

        #expect(order1?.id == 30, "expected the exact-UUID match to win, got \(String(describing: order1?.id))")
        #expect(order2?.id == 30, "expected the exact-UUID match to win, got \(String(describing: order2?.id))")
    }

    // MARK: - Exact-UUID vs invalid-UUID, sharing a portKey

    @Test("Exact-UUID beats invalid-UUID sharing a portKey, both array orders")
    func exactUUIDBeatsInvalidUUIDSharingPortKey() {
        let exact = USB3Transport(
            id: 40, portKey: "2/1", signaling: 1,
            signalingDescription: "Gen 1", dataRole: "host",
            hpmControllerUUID: validUUID
        )
        // "invalid" here means malformed once dashes are stripped: not 32
        // hex characters (too short, and contains a non-hex character).
        // `canonicallyMatches` falls back to portKey equality for this
        // entry (no valid UUID on its side), so it still canonically
        // matches the port; the tie policy is what decides which wins.
        let invalid = USB3Transport(
            id: 41, portKey: "2/1", signaling: 2,
            signalingDescription: "Gen 2", dataRole: "host",
            hpmControllerUUID: "not-a-real-uuid-zzz"
        )
        let p = port(uuid: validUUID)

        let order1 = USB3SpeedCorroboration.selectedTransport(for: p, in: [exact, invalid])
        let order2 = USB3SpeedCorroboration.selectedTransport(for: p, in: [invalid, exact])

        #expect(order1?.id == 40, "expected the exact-UUID match to win, got \(String(describing: order1?.id))")
        #expect(order2?.id == 40, "expected the exact-UUID match to win, got \(String(describing: order2?.id))")
    }

    // MARK: - Invalid-UUID sorts as invalid, not as a comparable real value

    @Test("A malformed 32-character UUID is treated as invalid, same as absent")
    func malformed32CharacterUUIDTreatedAsInvalid() {
        // 32 characters, but not hex (contains 'g' and other non-hex
        // letters): must NOT validate as a UUID. Before this fix, only the
        // length was checked, so a 32-character non-hex string would have
        // been accepted as a "valid" UUID and could have won a strength
        // comparison it should have lost.
        let malformed = USB3Transport(
            id: 50, portKey: "2/1", signaling: 1,
            signalingDescription: "Gen 1", dataRole: "host",
            hpmControllerUUID: "gggggggggggggggggggggggggggggggg"
        )
        let exact = USB3Transport(
            id: 51, portKey: "2/1", signaling: 2,
            signalingDescription: "Gen 2", dataRole: "host",
            hpmControllerUUID: validUUID
        )
        let p = port(uuid: validUUID)

        let order1 = USB3SpeedCorroboration.selectedTransport(for: p, in: [malformed, exact])
        let order2 = USB3SpeedCorroboration.selectedTransport(for: p, in: [exact, malformed])

        #expect(order1?.id == 51, "expected the exact-UUID match to beat the malformed one, got \(String(describing: order1?.id))")
        #expect(order2?.id == 51, "expected the exact-UUID match to beat the malformed one, got \(String(describing: order2?.id))")
    }

    // MARK: - Malformed UUID must sort LAST, same as absent, not by its own literal text

    @Test("A malformed UUID ranks with nil-UUID entries, not by its own literal string value")
    func malformedUUIDRanksWithNilNotByLiteralText() {
        // Both candidates are strength-1 (portKey-fallback: neither has a
        // UUID matching the port's), so the tie-break falls to ascending
        // normalised UUID, where nil/invalid sorts LAST via the sentinel.
        // Before validating hex, a malformed-but-32-character UUID would
        // have sorted by its own literal text instead of the sentinel,
        // and "gggg..." sorts BEFORE the sentinel character alphabetically,
        // so the malformed entry would have WRONGLY won the tie over the
        // genuinely-nil one. Neither should win by UUID here (both are
        // "invalid" from the selector's point of view); the tie-break must
        // fall through to portKey/id, which is what actually distinguishes
        // this pair.
        let malformed = USB3Transport(
            id: 60, portKey: "2/1", signaling: 1,
            signalingDescription: "Gen 1", dataRole: "host",
            hpmControllerUUID: "gggggggggggggggggggggggggggggggg"
        )
        let nilUUID = USB3Transport(
            id: 59, portKey: "2/1", signaling: 2,
            signalingDescription: "Gen 2", dataRole: "host",
            hpmControllerUUID: nil
        )
        // Port has NO UUID of its own, so both candidates are strength-1
        // (portKey fallback only) regardless of what they carry.
        let p = port(uuid: nil)

        let order1 = USB3SpeedCorroboration.selectedTransport(for: p, in: [malformed, nilUUID])
        let order2 = USB3SpeedCorroboration.selectedTransport(for: p, in: [nilUUID, malformed])

        // Both entries are "invalid UUID" (nil counts, malformed counts),
        // so they tie on the UUID field and the tie-break falls to id:
        // the lower id (59, nilUUID) wins, in BOTH array orders.
        #expect(order1?.id == 59, "expected the lower id to win once both UUIDs are treated as invalid, got \(String(describing: order1?.id))")
        #expect(order2?.id == 59, "expected the lower id to win once both UUIDs are treated as invalid, got \(String(describing: order2?.id))")
    }
}
