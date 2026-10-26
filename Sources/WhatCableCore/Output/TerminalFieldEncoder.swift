/// Encodes untrusted, single-field text before it is embedded in terminal
/// output. Hardware descriptors and IOKit properties can contain C0/C1
/// controls, including ESC/OSC sequences and embedded line breaks. Rendering
/// those bytes verbatim lets a device alter terminal state or forge rows.
///
/// Formatter-owned ANSI sequences and newlines must be added after this
/// encoder runs. Structured JSON deliberately does not use this representation.
public enum TerminalFieldEncoder {
    /// Replaces C0/C1 control scalars and Unicode bidi controls with visible
    /// Unicode escape sequences.
    ///
    /// The bidi set (U+061C, U+200E/F, U+202A-202E, U+2066-2069) cannot
    /// inject terminal sequences, but an RTL override in a device name can
    /// visually reorder the name and the formatter's own suffix, spoofing
    /// what the user reads. Hardware identifiers have no legitimate need for
    /// invisible directional formatting, so these are escaped too. RTL
    /// *letters* (Hebrew, Arabic text) pass through untouched. Zero-width
    /// joiners are deliberately NOT escaped: they are load-bearing inside
    /// emoji sequences, which are legitimate in device names.
    public static func encode(_ value: String) -> String {
        var encoded = ""
        encoded.reserveCapacity(value.utf8.count)

        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x00...0x1F, 0x7F...0x9F,
                 0x061C, 0x200E...0x200F, 0x202A...0x202E, 0x2066...0x2069:
                let hex = String(scalar.value, radix: 16, uppercase: true)
                encoded += "\\u{\(hex)}"
            default:
                encoded.unicodeScalars.append(scalar)
            }
        }

        return encoded
    }
}
