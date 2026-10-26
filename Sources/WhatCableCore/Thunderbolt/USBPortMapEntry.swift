import Foundation

/// One entry from a Thunderbolt switch's `USB Port Map` property:
/// pairs a downstream USB4 port with the switch's own USB3 adapter number.
///
/// The raw property is `Data`, read into triplets of three bytes each:
/// `(USB4 port, unknown byte, 0x80 | USB3 adapter number)`. Reference capture
/// (a UGreen TBT5 dock, JHL9580 silicon; the private notes, tree-attribution,
/// dock-switch5-raw.txt):
///
/// ```
/// <018194028295038396048497050000>
/// ```
///
/// which chunks into five triplets:
///
/// | usb4Port | unknownByte | third byte | decoded          |
/// |----------|-------------|------------|------------------|
/// | 1        | 0x81        | 0x94       | adapter 20 (0x14)|
/// | 2        | 0x82        | 0x95       | adapter 21 (0x15)|
/// | 3        | 0x83        | 0x96       | adapter 22 (0x16)|
/// | 4        | 0x84        | 0x97       | adapter 23 (0x17)|
/// | 5        | 0x00        | 0x00       | unmapped, skipped|
///
/// matching the switch's own `USB Adapter` port numbers 20-23 exactly
/// (verified 160/160 switch instances corpus-wide, per
/// the private design note "TB5 tunnel-hub attribution" section 2 point 4). The
/// second byte of each triplet is not decoded by anything here: it is kept
/// on `unknownByte` for forward visibility, never interpreted.
public struct USBPortMapEntry: Equatable, Sendable {
    /// The USB4 (Thunderbolt) downstream port number, 1-based, straight from
    /// the triplet's first byte.
    public let usb4Port: Int
    /// The triplet's middle byte. Undecoded; observed values 0x80...0x84 in
    /// the corpus. Kept, not interpreted.
    public let unknownByte: Int
    /// The USB3 adapter (port) number this USB4 port pairs with, decoded from
    /// the triplet's third byte with the `0x80` marker bit stripped.
    public let usb3Adapter: Int

    /// Parses a raw `USB Port Map` property into its mapped entries.
    ///
    /// Rules (spec section 8 phase 1):
    /// - chunk into 3-byte groups; an incomplete trailing group (fewer than 3
    ///   bytes left) is dropped, not treated as a partial entry;
    /// - the third byte must have bit `0x80` set to count as a real mapping
    ///   (the low 7 bits are then the USB3 adapter number); a third byte of
    ///   `0x00` (no `0x80` bit) means "no USB3 mapping for this USB4 port"
    ///   and that triplet is skipped, not returned as a nil-adapter entry;
    /// - a truncated map (a zero-downstream box publishing only its own
    ///   entry, e.g. an Envoy Ultra's single `018194`) parses to a short
    ///   list, never an error: `nil`/empty `Data` parses to an empty list.
    public static func parse(_ data: Data?) -> [USBPortMapEntry] {
        guard let data, !data.isEmpty else { return [] }
        let bytes = [UInt8](data)
        var entries: [USBPortMapEntry] = []
        var index = 0
        while index + 3 <= bytes.count {
            let usb4Port = bytes[index]
            let unknownByte = bytes[index + 1]
            let marker = bytes[index + 2]
            if marker & 0x80 != 0 {
                entries.append(
                    USBPortMapEntry(
                        usb4Port: Int(usb4Port),
                        unknownByte: Int(unknownByte),
                        usb3Adapter: Int(marker & 0x7F)
                    )
                )
            }
            index += 3
        }
        return entries
    }
}
