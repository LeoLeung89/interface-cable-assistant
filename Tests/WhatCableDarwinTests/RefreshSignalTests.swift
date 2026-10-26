import Testing
import Combine
@testable import WhatCableAppKit

@Suite("RefreshSignal")
struct RefreshSignalTests {
    private var signal: RefreshSignal
    private var cancellables: Set<AnyCancellable>

    init() {
        signal = RefreshSignal()
        cancellables = []
    }

    @Test("initial state")
    func initialState() {
        #expect(signal.tick == 0)
        #expect(signal.optionHeld == false)
        #expect(signal.showSettings == false)
    }

    @Test("bump increments tick")
    mutating func bumpIncrementsTick() {
        signal.bump()
        #expect(signal.tick == 1)
        signal.bump()
        #expect(signal.tick == 2)
    }

    @Test("showSettings toggle")
    mutating func showSettingsToggle() {
        var observedValue = false
        let cancellable = signal.$showSettings
            .dropFirst()
            .sink { observedValue = $0 }
        signal.showSettings = true
        #expect(signal.showSettings == true)
        #expect(observedValue == true)
        _ = cancellable
    }

    @Test("optionHeld toggle")
    mutating func optionHeldToggle() {
        signal.optionHeld = true
        #expect(signal.optionHeld == true)
        signal.optionHeld = false
        #expect(signal.optionHeld == false)
    }
}
