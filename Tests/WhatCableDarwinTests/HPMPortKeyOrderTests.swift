import Foundation
import Testing
@testable import WhatCableDarwinBackend

// Unit coverage for `PowerService.orderedPortKeys(_:)`, the pure
// ordering rule behind `hpmPortKeys()`. The corpus evidence that RID order is
// the RIGHT rule lives in `HPMPortKeyOrderCorpusSweepTests`; this file only
// pins the mechanics (does it sort, and does it refuse to sort when the data
// can't support it).
@Suite("hpmPortKeys ordering")
struct HPMPortKeyOrderTests {

    @Test("Ports come back in RID order, not the order they were found in")
    func sortsByRID() {
        // The live layout on a 14" M5: IOKit hands back USB-C@4 first because
        // it walks AppleHPMInterfaceType10 before Type11, and within Type10 in
        // whatever order the registry supplies. RIDs put it third.
        let found: [(key: String, rid: Int?)] = [
            ("2/4", 3), ("2/1", 0), ("2/2", 1), ("17/1", 5)
        ]

        #expect(PowerService.orderedPortKeys(found) == ["2/1", "2/2", "2/4", "17/1"])
    }

    @Test("Already-ordered input is left alone")
    func alreadyOrdered() {
        let found: [(key: String, rid: Int?)] = [("2/1", 0), ("2/2", 1), ("17/1", 5)]

        #expect(PowerService.orderedPortKeys(found) == ["2/1", "2/2", "17/1"])
    }

    @Test("A missing RID refuses to answer rather than guessing")
    func missingRIDReturnsEmpty() {
        // Returning the input order would hand back the very order this change
        // exists to stop trusting, and the caller could not tell it apart from
        // a real answer. Sorting only the ports that do have an RID would be
        // worse still: some reordered, some not.
        let found: [(key: String, rid: Int?)] = [("2/4", 3), ("2/1", nil), ("2/2", 1)]

        #expect(PowerService.orderedPortKeys(found).isEmpty)
    }

    @Test("Duplicate RIDs refuse to answer rather than guessing")
    func duplicateRIDReturnsEmpty() {
        // Two ports reporting the same controller RID means the RID isn't
        // identifying a port here, so it can't be used to order them.
        let found: [(key: String, rid: Int?)] = [("2/4", 1), ("2/1", 0), ("2/2", 1)]

        #expect(PowerService.orderedPortKeys(found).isEmpty)
    }

    @Test("Empty and single-port machines are handled")
    func degenerateCases() {
        #expect(PowerService.orderedPortKeys([]).isEmpty)
        #expect(PowerService.orderedPortKeys([("2/1", 0)]) == ["2/1"])
        // One port with no RID is still a refusal. A single-element array is
        // trivially "in order", but the caller cannot tell that apart from a
        // machine whose controllers publish no RID at all, and on the next
        // machine with two ports it would be a guess.
        #expect(PowerService.orderedPortKeys([("2/1", nil)]).isEmpty)
    }

    @Test("RIDs need not be contiguous")
    func nonContiguousRIDs() {
        // Real machines skip values: a 14" M5 uses 0, 1, 3, 5.
        let found: [(key: String, rid: Int?)] = [("17/1", 5), ("2/4", 3), ("2/1", 0), ("2/2", 1)]

        #expect(PowerService.orderedPortKeys(found) == ["2/1", "2/2", "2/4", "17/1"])
    }
}
