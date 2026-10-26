import Foundation
import Testing
@testable import WhatCableDarwinBackend
import WhatCableCore

// MARK: - HPMControllerClassGateTests
//
// These tests exist because a claim about M1/M2 port UUIDs was got WRONG TWICE,
// in opposite directions, by reading code instead of executing it:
//
//   Attempt 1: "M1/M2 have the UUID, so the @N fallback is dead code."
//   Attempt 2: "The power path can't see M1/M2 UUIDs, so widen HPMPortUUIDMap."
//
// Both were prose in a doc, so neither could fail. This file converts the claim
// into assertions that go red when they are wrong. If a future change breaks the
// M1/M2 join, you find out here rather than in a research doc six weeks later.
//
// THE CLAIM UNDER TEST, stated so it is falsifiable:
//
//   1. The HPM controller-class gate accepts the M1/M2 base class
//      (`AppleHPMDevice`), not just the M3+ subclass (`AppleHPMDeviceHAL*`).
//   2. Therefore a port whose UUID came from an M1/M2 controller flows through
//      the PRODUCTION join (`HPMPortUUIDMap.from(ports:)`) and lands in the map.
//   3. `HPMPortUUIDMap.current()` really is subclass-gated (it is the startup
//      fallback), so it is NOT the path that carries M1/M2. Both facts are true
//      at once; conflating them is what caused the two wrong conclusions.
//
// WHAT THESE TESTS CANNOT PROVE, stated honestly:
//
//   * No test here runs on an M1/M2 Mac. They prove the class gate and the join
//     logic accept M1/M2-shaped input, and (in the corpus sweep) that real M1/M2
//     hardware in the corpus publishes the UUID. They do NOT prove live M1/M2
//     runtime behaviour. The open M1/M2 question is still the SMC `DxUI` side
//     (probe 34), untouched by this.
//   * Neither does anything here exercise the IOKit ancestor WALK. That needs a
//     live `io_service_t` and has no replay seam, so only the class PREDICATE it
//     consults is pinned (this file), plus the join that consumes its output.
//
// WHERE THE GUARANTEE ACTUALLY LIVES (Codex review, #403): probe 35 has ZERO
// git-tracked files, so `HPMPortUUIDMapCorpusSweepTests`' corpus assertions SKIP
// on a fresh clone and in CI. They are a dev-machine check, not an enforceable CI
// invariant, and must not be described as one. The always-on guarantee is THIS
// file: it is pure fixtures, no corpus, so it asserts everywhere.
@Suite("HPM controller class gate - the M1/M2 join must not silently narrow")
struct HPMControllerClassGateTests {

    // MARK: - 1. The class gate itself

    @Test("The class gate accepts the M1/M2 base class, not just the M3+ subclass")
    func classGateAcceptsBaseAndSubclass() {
        // M1/M2. THE load-bearing case. If this ever returns false, every M1/M2
        // machine silently drops out of the port join and it looks like the
        // hardware has no UUID. The 206-machine corpus says otherwise:
        // 295/295 AppleHPMDevice ports carry one.
        #expect(wcIsHPMControllerClass("AppleHPMDevice"),
                "M1/M2 base class must be accepted: 295/295 AppleHPMDevice ports in the corpus carry a UUID")

        // M3+ subclasses.
        #expect(wcIsHPMControllerClass("AppleHPMDeviceHALType3"))
        #expect(wcIsHPMControllerClass("AppleHPMDeviceHALType1"))
        #expect(wcIsHPMControllerClass("AppleHPMDeviceHAL"))
    }

    @Test("The class gate rejects non-controller HPM-adjacent classes")
    func classGateRejectsNonControllers() {
        // These live in the same subtree and are easy to grab by accident. The
        // port node itself is NOT the controller node and carries no UUID.
        #expect(!wcIsHPMControllerClass("AppleHPMInterfaceType10"))
        #expect(!wcIsHPMControllerClass("AppleHPMInterfaceType11"))
        #expect(!wcIsHPMControllerClass("AppleHPMARMSPMI"))
        #expect(!wcIsHPMControllerClass("IOPortTransportStateCC"))
        #expect(!wcIsHPMControllerClass(""))

        // Prefix-matching must not be so loose that an unrelated class starting
        // with "AppleHPMDevice" but not the HAL family sneaks in... note that it
        // legitimately would (hasPrefix("AppleHPMDeviceHAL")), so assert the
        // boundary we actually rely on: "AppleHPMDeviceFoo" is NOT accepted.
        #expect(!wcIsHPMControllerClass("AppleHPMDeviceFoo"))
    }

    // MARK: - 2. The production join accepts an M1/M2-sourced port

    /// Build a port the way the watcher does, with the UUID it stamped from an
    /// HPM controller. `className` here is the PORT node's class (what
    /// `AppleHPMInterface.from` sees), which is an `AppleHPMInterface*` type on
    /// every generation; the controller class is upstream and is what
    /// `wcIsHPMControllerClass` gates on. The distinction matters and is exactly
    /// what the old sweep blurred by hardcoding "AppleHPMDeviceHALType3" here.
    private static func makePort(
        portNumber: Int,
        isMagSafe: Bool = false,
        uuid: String?,
        entryID: UInt64
    ) -> AppleHPMInterface? {
        let props: [String: Any] = [
            "PortTypeDescription": isMagSafe ? "MagSafe 3" : "USB-C",
            "PortNumber": NSNumber(value: portNumber),
            "PortType": NSNumber(value: isMagSafe ? 0x11 : 0x2),
        ]
        return AppleHPMInterface.from(
            entryID: entryID,
            serviceName: isMagSafe ? "Port-MagSafe 3@\(portNumber)" : "Port-USB-C@\(portNumber)",
            className: "AppleHPMInterfaceType10",
            read: { props[$0] },
            hpmControllerUUID: uuid
        )
    }

    @Test("A port whose UUID came from an M1/M2 controller lands in the production join map")
    func m1m2SourcedPortJoinsThroughProductionMap() throws {
        // An M1/M2 machine: two USB-C ports plus MagSafe, each stamped with the
        // UUID the class-agnostic ancestor walk read off an `AppleHPMDevice`
        // controller. This is the shape `AppleHPMInterfaceWatcher` produces and
        // that `PowerService.updatePorts(_:)` feeds to the join.
        let ports = [
            Self.makePort(portNumber: 1, uuid: "AAAAAAAA-1111-2222-3333-444444444444", entryID: 1),
            Self.makePort(portNumber: 2, uuid: "BBBBBBBB-1111-2222-3333-444444444444", entryID: 2),
            Self.makePort(portNumber: 1, isMagSafe: true, uuid: "CCCCCCCC-1111-2222-3333-444444444444", entryID: 3),
        ].compactMap { $0 }
        #expect(ports.count == 3)

        let map = HPMPortUUIDMap.from(ports: ports)

        // The whole point: NOT empty on M1/M2.
        #expect(!map.isEmpty,
                "M1/M2-sourced ports must produce a non-empty join map; an empty map here means the power join silently drops every M1/M2 machine")
        #expect(map.count == 3)
        #expect(map[HPMPortUUIDMap.normalise("AAAAAAAA-1111-2222-3333-444444444444")] == "2/1")
        #expect(map[HPMPortUUIDMap.normalise("BBBBBBBB-1111-2222-3333-444444444444")] == "2/2")
        // MagSafe@1 and USB-C@1 share @N but must not collide (issue #195).
        #expect(map[HPMPortUUIDMap.normalise("CCCCCCCC-1111-2222-3333-444444444444")] == "17/1")
    }

    @Test("The fallback is real: a port with no controller UUID yields no map entry")
    func portWithoutUUIDYieldsNoEntry() throws {
        // This pins the OTHER half. The `@N`/positional fallback is not dead
        // code: it serves ports that carry no UUID (e.g. the startup window
        // before `updatePorts` runs, or anything relying on `current()` alone).
        // Claiming the fallback is dead was wrong attempt #1.
        let port = try #require(Self.makePort(portNumber: 2, uuid: nil, entryID: 1))
        #expect(HPMPortUUIDMap.from(ports: [port]).isEmpty,
                "a port with no controller UUID must not appear in the join map")
    }

    @Test("A malformed UUID is rejected rather than producing a junk key")
    func malformedUUIDIsRejected() throws {
        // Wrong length.
        let short = try #require(Self.makePort(portNumber: 1, uuid: "not-a-uuid", entryID: 1))
        #expect(HPMPortUUIDMap.from(ports: [short]).isEmpty,
                "a short/garbage UUID must be dropped, not keyed on")

        // Right length, WRONG alphabet. Production used to check length only, so
        // a 32-char non-hex string became a join key (Codex review, #403). It now
        // validates hex too, via HPMPortUUIDMap.isValidNormalised.
        let thirtyTwoNonHex = String(repeating: "z", count: 32)
        #expect(thirtyTwoNonHex.count == 32)   // the test is only meaningful if this holds
        let junk = try #require(Self.makePort(portNumber: 2, uuid: thirtyTwoNonHex, entryID: 2))
        #expect(HPMPortUUIDMap.from(ports: [junk]).isEmpty,
                "a 32-char non-hex string must be rejected: length alone is not a valid UUID check")
    }

    @Test("isValidNormalised: 32 hex chars only")
    func isValidNormalisedChecksHexAndLength() {
        #expect(HPMPortUUIDMap.isValidNormalised(String(repeating: "a", count: 32)))
        #expect(HPMPortUUIDMap.isValidNormalised("0123456789abcdef0123456789abcdef"))
        #expect(!HPMPortUUIDMap.isValidNormalised(String(repeating: "a", count: 31)))
        #expect(!HPMPortUUIDMap.isValidNormalised(String(repeating: "a", count: 33)))
        #expect(!HPMPortUUIDMap.isValidNormalised(String(repeating: "z", count: 32)))
        #expect(!HPMPortUUIDMap.isValidNormalised(""))

        // NON-ASCII. `Character.isHexDigit` is Unicode-aware and accepts
        // full-width forms, so 32 full-width "Ａ" (U+FF21) passed the original
        // length+isHexDigit check and would have become a join key. The SMC side
        // only ever produces ASCII hex, so anything else is junk. Codex, #403.
        let fullWidthA = String(repeating: "\u{FF21}", count: 32)
        let isThirtyTwo = fullWidthA.count == 32
        let unicodeHexAcceptsIt = fullWidthA.allSatisfy { $0.isHexDigit }
        #expect(isThirtyTwo)               // the test only bites if this holds...
        #expect(unicodeHexAcceptsIt)       // ...and only if isHexDigit really does accept it
        #expect(!HPMPortUUIDMap.isValidNormalised(fullWidthA),
                "32 full-width hex characters must be rejected: the join key must be ASCII hex")
    }
}
