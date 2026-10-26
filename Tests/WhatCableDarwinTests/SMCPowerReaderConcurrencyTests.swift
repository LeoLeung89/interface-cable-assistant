import Foundation
import Testing
@testable import WhatCableDarwinBackend

@Suite struct SMCPowerReaderConcurrencyTests {
    /// Run under TSan to see the race: the shared reader is now read from the
    /// hub's background task while the Power Monitor reads it on main.
    @Test func concurrentReadsDoNotRace() async {
        let reader = SMCPowerReader()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<25 {
                        _ = reader.readSystemPowerInput()
                        _ = reader.readPortContracts()
                        // Close each time so open and close race on every
                        // iteration, not just the first lazy open.
                        reader.close()
                    }
                }
            }
        }
        reader.close()
    }
}
