import Testing
@testable import WhatCableCore

/// Unit tests for USBCPinMap model.
///
/// Test fixtures come from real IOKit probe data captured on Apple Silicon.
/// Each pin configuration dict matches an actual `ioreg` dump from the
/// probes/ directory.
@Suite("USB-C Pin Map")
struct USBCPinMapTests {

    // MARK: - Factory: nil for empty input

    @Test("Returns nil for empty dict")
    func returnsNilForEmptyDict() {
        let map = USBCPinMap.from(pinConfiguration: [:])
        #expect(map == nil)
    }

    // MARK: - All zeros (MagSafe / nothing connected)

    @Test("All zeros has no activity")
    func allZerosHasNoActivity() {
        let pins = allZeros
        let map = USBCPinMap.from(pinConfiguration: pins)!
        #expect(!map.hasActivity)
    }

    @Test("All zeros signal summary")
    func allZerosSignalSummary() {
        let map = USBCPinMap.from(pinConfiguration: allZeros)!
        #expect(map.signalSummary == "No data signals")
    }

    // MARK: - USB 3 pair A (probe: USB device port)

    @Test("USB3 pair A detected")
    func usb3PairADetected() {
        // From probe: tx1=1, rx1=2, all others zero.
        let map = USBCPinMap.from(pinConfiguration: usb3PairA)!
        #expect(map.hasActivity)

        // tx1 drives A2/A3
        #expect(map.topRow[1].signal == .usb3PairA)  // A2
        #expect(map.topRow[2].signal == .usb3PairA)  // A3

        // rx1 drives B10/B11
        #expect(map.bottomRow[1].signal == .usb3PairA)  // B11
        #expect(map.bottomRow[2].signal == .usb3PairA)  // B10

        // Everything else on data pins should be inactive
        #expect(map.topRow[9].signal == .inactive)   // A10 (rx2)
        #expect(map.bottomRow[10].signal == .inactive) // B2 (tx2)
    }

    @Test("USB3 pair A signal summary")
    func usb3PairASignalSummary() {
        let map = USBCPinMap.from(pinConfiguration: usb3PairA)!
        #expect(map.signalSummary == "USB 3")
    }

    // MARK: - USB 3 pair B (probe: dock port)

    @Test("USB3 pair B detected")
    func usb3PairBDetected() {
        // From probe: tx2=3, rx2=4, all others zero.
        let map = USBCPinMap.from(pinConfiguration: usb3PairB)!
        #expect(map.hasActivity)

        // tx2 drives B2/B3
        #expect(map.bottomRow[10].signal == .usb3PairB)  // B2
        #expect(map.bottomRow[9].signal == .usb3PairB)   // B3

        // rx2 drives A10/A11
        #expect(map.topRow[9].signal == .usb3PairB)   // A10
        #expect(map.topRow[10].signal == .usb3PairB)  // A11
    }

    // MARK: - 4-lane DisplayPort (probe: monitor port)

    @Test("Four lane DP detected")
    func fourLaneDPDetected() {
        // From probe: tx1=6, rx1=5, tx2=7, rx2=8, sbu1=2, sbu2=1
        let map = USBCPinMap.from(pinConfiguration: fourLaneDP)!
        #expect(map.hasActivity)

        // tx1 (value 6) = DP Lane 1 on A2/A3
        #expect(map.topRow[1].signal == .dpLane(1))
        #expect(map.topRow[2].signal == .dpLane(1))

        // rx1 (value 5) = DP Lane 0 on B10/B11
        #expect(map.bottomRow[1].signal == .dpLane(0))
        #expect(map.bottomRow[2].signal == .dpLane(0))

        // tx2 (value 7) = DP Lane 2 on B2/B3
        #expect(map.bottomRow[10].signal == .dpLane(2))
        #expect(map.bottomRow[9].signal == .dpLane(2))

        // rx2 (value 8) = DP Lane 3 on A10/A11
        #expect(map.topRow[9].signal == .dpLane(3))
        #expect(map.topRow[10].signal == .dpLane(3))

        // SBU pins carry DP AUX
        #expect(map.topRow[7].signal == .dpAux)     // A8 (sbu1)
        #expect(map.bottomRow[4].signal == .dpAux)   // B8 (sbu2)
    }

    @Test("Four lane DP signal summary")
    func fourLaneDPSignalSummary() {
        let map = USBCPinMap.from(pinConfiguration: fourLaneDP)!
        #expect(map.signalSummary == "DP (4 lanes)")
    }

    // MARK: - Static pins always present

    @Test("Static pins are correct")
    func staticPinsAreCorrect() {
        let map = USBCPinMap.from(pinConfiguration: allZeros)!

        // Ground pins
        #expect(map.topRow[0].signal == .ground)     // A1
        #expect(map.topRow[11].signal == .ground)    // A12
        #expect(map.bottomRow[0].signal == .ground)  // B12
        #expect(map.bottomRow[11].signal == .ground) // B1

        // VBUS pins
        #expect(map.topRow[3].signal == .vbus)       // A4
        #expect(map.topRow[8].signal == .vbus)       // A9
        #expect(map.bottomRow[3].signal == .vbus)    // B9
        #expect(map.bottomRow[8].signal == .vbus)    // B4

        // CC pins
        #expect(map.topRow[4].signal == .cc)         // A5
        #expect(map.bottomRow[7].signal == .cc)      // B5

        // USB 2.0 pins
        #expect(map.topRow[5].signal == .usb2)       // A6
        #expect(map.topRow[6].signal == .usb2)       // A7
        #expect(map.bottomRow[5].signal == .usb2)    // B7
        #expect(map.bottomRow[6].signal == .usb2)    // B6
    }

    @Test("Static pins are not dynamic")
    func staticPinsAreNotDynamic() {
        let map = USBCPinMap.from(pinConfiguration: allZeros)!
        #expect(!USBCPinMap.Signal.ground.isDynamic)
        #expect(!USBCPinMap.Signal.vbus.isDynamic)
        #expect(!USBCPinMap.Signal.cc.isDynamic)
        #expect(!USBCPinMap.Signal.usb2.isDynamic)
        #expect(!USBCPinMap.Signal.inactive.isDynamic)
        // Confirm no static pin is flagged as dynamic
        #expect(!map.topRow[0].signal.isDynamic)   // GND
        #expect(!map.topRow[3].signal.isDynamic)   // VBUS
    }

    // MARK: - Pin IDs and row sizes

    @Test("Row sizes")
    func rowSizes() {
        let map = USBCPinMap.from(pinConfiguration: allZeros)!
        #expect(map.topRow.count == 12)
        #expect(map.bottomRow.count == 12)
        #expect(map.allPins.count == 24)
    }

    @Test("Top row pin IDs")
    func topRowPinIDs() {
        let map = USBCPinMap.from(pinConfiguration: allZeros)!
        let ids = map.topRow.map(\.id)
        #expect(ids == ["A1","A2","A3","A4","A5","A6","A7","A8","A9","A10","A11","A12"])
    }

    @Test("Bottom row pin IDs")
    func bottomRowPinIDs() {
        let map = USBCPinMap.from(pinConfiguration: allZeros)!
        let ids = map.bottomRow.map(\.id)
        // Reversed: B12 down to B1 for visual layout
        #expect(ids == ["B12","B11","B10","B9","B8","B7","B6","B5","B4","B3","B2","B1"])
    }

    // MARK: - Orientation

    @Test("Orientation normal")
    func orientationNormal() {
        let map = USBCPinMap.from(pinConfiguration: allZeros, plugOrientation: 1)!
        #expect(map.orientation == 1)
        #expect(map.orientationLabel == "Normal")
    }

    @Test("Orientation flipped")
    func orientationFlipped() {
        let map = USBCPinMap.from(pinConfiguration: allZeros, plugOrientation: 2)!
        #expect(map.orientation == 2)
        #expect(map.orientationLabel == "Flipped")
    }

    @Test("Orientation unknown")
    func orientationUnknown() {
        let map = USBCPinMap.from(pinConfiguration: allZeros, plugOrientation: nil)!
        #expect(map.orientation == 0)
        #expect(map.orientationLabel == "Unknown")
    }

    // MARK: - Signal labels

    @Test("Signal labels")
    func signalLabels() {
        #expect(USBCPinMap.Signal.ground.label == "GND")
        #expect(USBCPinMap.Signal.vbus.label == "VBUS")
        #expect(USBCPinMap.Signal.cc.label == "CC")
        #expect(USBCPinMap.Signal.usb2.label == "USB 2.0")
        #expect(USBCPinMap.Signal.usb3PairA.label == "USB 3")
        #expect(USBCPinMap.Signal.usb3PairB.label == "USB 3")
        #expect(USBCPinMap.Signal.dpLane(2).label == "DP Lane 2")
        #expect(USBCPinMap.Signal.dpAux.label == "DP AUX")
        #expect(USBCPinMap.Signal.inactive.label == "Inactive")
        #expect(USBCPinMap.Signal.unknown(99).label == "Signal 99")
    }

    // MARK: - Unknown values preserved

    @Test("Unknown data value")
    func unknownDataValue() {
        let pins = ["tx1": "42", "rx1": "0", "tx2": "0", "rx2": "0", "sbu1": "0", "sbu2": "0"]
        let map = USBCPinMap.from(pinConfiguration: pins)!
        #expect(map.topRow[1].signal == .unknown(42))
        #expect(map.topRow[1].signal.isDynamic == false)
    }

    @Test("Unknown SBU value")
    func unknownSBUValue() {
        let pins = ["tx1": "0", "rx1": "0", "tx2": "0", "rx2": "0", "sbu1": "7", "sbu2": "0"]
        let map = USBCPinMap.from(pinConfiguration: pins)!
        #expect(map.topRow[7].signal == .unknown(7))
    }

    // MARK: - Mixed signals (hypothetical 2-lane DP + USB3)

    @Test("Two lane DP plus USB3 summary")
    func twoLaneDPPlusUSB3Summary() {
        // 2 DP lanes on tx1/rx1, USB3 pair B on tx2/rx2
        let pins = ["tx1": "6", "rx1": "5", "tx2": "3", "rx2": "4", "sbu1": "2", "sbu2": "1"]
        let map = USBCPinMap.from(pinConfiguration: pins)!
        #expect(map.signalSummary == "USB 3 + DP (2 lanes)")
    }

    // MARK: - Hashable / Equatable

    @Test("Equatable")
    func equatable() {
        let a = USBCPinMap.from(pinConfiguration: usb3PairA, plugOrientation: 1)!
        let b = USBCPinMap.from(pinConfiguration: usb3PairA, plugOrientation: 1)!
        #expect(a == b)
    }

    @Test("Not equal when different config")
    func notEqualWhenDifferentConfig() {
        let a = USBCPinMap.from(pinConfiguration: usb3PairA)!
        let b = USBCPinMap.from(pinConfiguration: fourLaneDP)!
        #expect(a != b)
    }

    // MARK: - Fixtures from probe data

    /// MagSafe port or port with nothing connected. All data pins inactive.
    private var allZeros: [String: String] {
        ["tx1": "0", "rx1": "0", "tx2": "0", "rx2": "0", "sbu1": "0", "sbu2": "0"]
    }

    /// USB device connected, using SuperSpeed pair A.
    /// From probe: ConnectionCount=35, IOAccessoryUSBConnectType=0.
    private var usb3PairA: [String: String] {
        ["tx1": "1", "rx1": "2", "tx2": "0", "rx2": "0", "sbu1": "0", "sbu2": "0"]
    }

    /// Dock connected, using SuperSpeed pair B.
    /// From probe: ConnectionCount=5, IOAccessoryUSBConnectType=0.
    private var usb3PairB: [String: String] {
        ["tx1": "0", "rx1": "0", "tx2": "3", "rx2": "4", "sbu1": "0", "sbu2": "0"]
    }

    /// Monitor connected with 4-lane DisplayPort alt mode.
    /// From probe: ConnectionCount=75, IOAccessoryUSBConnectType=4,
    /// PlugOrientation=2, TransportsActive=["CC","DisplayPort"].
    private var fourLaneDP: [String: String] {
        ["tx1": "6", "rx1": "5", "tx2": "7", "rx2": "8", "sbu1": "2", "sbu2": "1"]
    }
}
