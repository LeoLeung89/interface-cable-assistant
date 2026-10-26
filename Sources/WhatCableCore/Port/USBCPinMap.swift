import Foundation

/// Maps IOKit's `Pin Configuration` dictionary to the 24 physical pins
/// of a USB-C connector.
///
/// USB-C has two rows of 12 pins each (A1-A12 on top, B1-B12 on bottom
/// when looking at the receptacle face-on). Most pins have fixed roles
/// (ground, VBUS, CC, USB 2.0), but 10 pins carry high-speed signals
/// whose assignment changes depending on what protocol is active.
///
/// IOKit reports the current routing via six keys: `tx1`, `rx1`, `tx2`,
/// `rx2`, `sbu1`, `sbu2`. Each key maps to a physical pin pair (or
/// single pin for SBU), and the integer value tells us which protocol
/// signal is routed through those pins.
///
/// Confirmed values from IOKit probe data on Apple Silicon:
/// - 0: inactive (no signal routed)
/// - 1-2: USB 3 SuperSpeed pair A
/// - 3-4: USB 3 SuperSpeed pair B
/// - 5-8: DisplayPort Alt Mode lanes 0-3
/// - SBU 1-2: DP AUX sideband channel
public struct USBCPinMap: Hashable, Sendable {

    /// What signal is currently routed through a pin.
    public enum Signal: Hashable, Sendable {
        case inactive
        case ground
        case vbus
        case cc
        case usb2
        case usb3PairA
        case usb3PairB
        case dpLane(Int)   // 0-3
        case dpAux
        case unknown(Int)

        /// Short label for this signal type.
        public var label: String {
            switch self {
            case .inactive: return "Inactive"
            case .ground: return "GND"
            case .vbus: return "VBUS"
            case .cc: return "CC"
            case .usb2: return "USB 2.0"
            case .usb3PairA, .usb3PairB: return "USB 3"
            case .dpLane(let n): return "DP Lane \(n)"
            case .dpAux: return "DP AUX"
            case .unknown(let v): return "Signal \(v)"
            }
        }

        /// True when this signal is a dynamic high-speed protocol
        /// (USB 3, DisplayPort, or sideband), not a fixed connector pin.
        public var isDynamic: Bool {
            switch self {
            case .usb3PairA, .usb3PairB, .dpLane, .dpAux: return true
            default: return false
            }
        }
    }

    /// A single physical pin on the connector.
    public struct Pin: Hashable, Sendable, Identifiable {
        /// Pin label, e.g. "A1", "B12".
        public let id: String
        /// What signal is currently on this pin.
        public let signal: Signal
    }

    /// Top row: A1 through A12 (left to right, looking at receptacle).
    public let topRow: [Pin]
    /// Bottom row: B12 through B1 (left to right, looking at receptacle).
    /// Reversed from the spec numbering so the visual layout lines up
    /// with the top row (pin 1 at opposite ends).
    public let bottomRow: [Pin]
    /// Plug orientation from IOKit. 0 = unknown, 1 = normal, 2 = flipped.
    public let orientation: Int

    /// All 24 pins across both rows.
    public var allPins: [Pin] { topRow + bottomRow }

    /// True when at least one pin carries a dynamic signal.
    public var hasActivity: Bool { allPins.contains { $0.signal.isDynamic } }

    /// Short label for the plug orientation.
    public var orientationLabel: String {
        switch orientation {
        case 1: return "Normal"
        case 2: return "Flipped"
        default: return "Unknown"
        }
    }

    /// Summary of active protocols on this connector.
    /// Returns something like "USB 3 + DP (4 lanes)" or "USB 3 only".
    public var signalSummary: String {
        let signals = Set(allPins.map(\.signal))
        let hasUSB3 = signals.contains(.usb3PairA) || signals.contains(.usb3PairB)
        let dpLanes = signals.compactMap { signal -> Int? in
            if case .dpLane(let n) = signal { return n }
            return nil
        }
        let hasDP = !dpLanes.isEmpty

        switch (hasUSB3, hasDP) {
        case (true, true):
            return "USB 3 + DP (\(dpLanes.count) lane\(dpLanes.count == 1 ? "" : "s"))"
        case (true, false):
            return "USB 3"
        case (false, true):
            return "DP (\(dpLanes.count) lane\(dpLanes.count == 1 ? "" : "s"))"
        case (false, false):
            return "No data signals"
        }
    }
}

// MARK: - Factory

extension USBCPinMap {

    /// Build a pin map from IOKit's `Pin Configuration` dictionary and
    /// plug orientation. Returns nil if the pin config is empty (no data
    /// to show).
    ///
    /// The pin config dict uses string keys ("tx1", "rx1", etc.) with
    /// stringified integer values ("0", "6", etc.). These come from
    /// `AppleHPMInterface.pinConfiguration`, which stringifies the raw NSNumber
    /// values from IOKit.
    public static func from(
        pinConfiguration: [String: String],
        plugOrientation: Int? = nil
    ) -> USBCPinMap? {
        guard !pinConfiguration.isEmpty else { return nil }

        let tx1 = dataSignal(from: pinConfiguration["tx1"])
        let rx1 = dataSignal(from: pinConfiguration["rx1"])
        let tx2 = dataSignal(from: pinConfiguration["tx2"])
        let rx2 = dataSignal(from: pinConfiguration["rx2"])
        let sbu1 = sbuSignal(from: pinConfiguration["sbu1"])
        let sbu2 = sbuSignal(from: pinConfiguration["sbu2"])

        // Top row: A1 through A12.
        // tx1 drives A2/A3 (SuperSpeed TX pair 1).
        // rx2 drives A10/A11 (SuperSpeed RX pair 2).
        // sbu1 drives A8.
        let topRow: [Pin] = [
            Pin(id: "A1",  signal: .ground),
            Pin(id: "A2",  signal: tx1),
            Pin(id: "A3",  signal: tx1),
            Pin(id: "A4",  signal: .vbus),
            Pin(id: "A5",  signal: .cc),
            Pin(id: "A6",  signal: .usb2),
            Pin(id: "A7",  signal: .usb2),
            Pin(id: "A8",  signal: sbu1),
            Pin(id: "A9",  signal: .vbus),
            Pin(id: "A10", signal: rx2),
            Pin(id: "A11", signal: rx2),
            Pin(id: "A12", signal: .ground),
        ]

        // Bottom row: B12 down to B1 (visual left-to-right).
        // tx2 drives B2/B3 (SuperSpeed TX pair 2).
        // rx1 drives B10/B11 (SuperSpeed RX pair 1).
        // sbu2 drives B8.
        let bottomRow: [Pin] = [
            Pin(id: "B12", signal: .ground),
            Pin(id: "B11", signal: rx1),
            Pin(id: "B10", signal: rx1),
            Pin(id: "B9",  signal: .vbus),
            Pin(id: "B8",  signal: sbu2),
            Pin(id: "B7",  signal: .usb2),
            Pin(id: "B6",  signal: .usb2),
            Pin(id: "B5",  signal: .cc),
            Pin(id: "B4",  signal: .vbus),
            Pin(id: "B3",  signal: tx2),
            Pin(id: "B2",  signal: tx2),
            Pin(id: "B1",  signal: .ground),
        ]

        return USBCPinMap(
            topRow: topRow,
            bottomRow: bottomRow,
            orientation: plugOrientation ?? 0
        )
    }

    // MARK: - Value decoding

    /// Decode a high-speed data pin value (tx1/rx1/tx2/rx2).
    private static func dataSignal(from str: String?) -> Signal {
        guard let str, let value = Int(str) else { return .inactive }
        switch value {
        case 0: return .inactive
        case 1, 2: return .usb3PairA
        case 3, 4: return .usb3PairB
        case 5: return .dpLane(0)
        case 6: return .dpLane(1)
        case 7: return .dpLane(2)
        case 8: return .dpLane(3)
        default: return .unknown(value)
        }
    }

    /// Decode an SBU pin value (sbu1/sbu2).
    private static func sbuSignal(from str: String?) -> Signal {
        guard let str, let value = Int(str) else { return .inactive }
        switch value {
        case 0: return .inactive
        case 1, 2: return .dpAux
        default: return .unknown(value)
        }
    }
}
