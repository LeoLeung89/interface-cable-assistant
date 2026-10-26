import Foundation

/// One physical port, identified the way every part of the app agrees to
/// identify one: a type code and a number.
///
/// Until this type existed the "type/number" key was built by hand in four
/// places, from three different inputs, with three different fallback rules.
/// They happened to agree on every machine in the probe corpus (1070 USB-C
/// ports reporting type 2 and 313 MagSafe ports reporting type 17, with no
/// third value anywhere), so this consolidation is not fixing a live bug. It
/// is removing the four-way drift that let one of them be wrong without the
/// other three noticing, which is how a port's data ended up under another
/// port's name more than once in this codebase's history.
///
/// The string form (`key`) is unchanged, so nothing downstream had to move.
public struct PortIdentity: Hashable, Codable, Sendable, Comparable {

    /// USB-C. Apple reports this as `PortType` 2 on every machine in the corpus.
    public static let usbCTypeCode = 0x2
    /// MagSafe 3. Apple reports this as `PortType` 17 (0x11).
    public static let magSafeTypeCode = 0x11

    /// The raw `PortType` Apple reports for this connector.
    public let typeCode: Int
    /// The `@N` port number. 1-based, and not an array index: a Mac can publish
    /// USB-C@2 and USB-C@4 with no @1 or @3.
    public let number: Int

    public init(typeCode: Int, number: Int) {
        self.typeCode = typeCode
        self.number = number
    }

    /// The canonical string key, e.g. `"2/1"` or `"17/1"`.
    ///
    /// This is a join key, not a label. It appears in snapshots and sample
    /// records; it is never shown to anyone.
    public var key: String { "\(typeCode)/\(number)" }

    /// What a person calls this connector.
    ///
    /// Anything that is not MagSafe reads as USB-C, which matches what the four
    /// hand-built sites did. It is a deliberate simplification rather than a
    /// complete mapping: if a Mac ever ships a third connector type this will
    /// call it USB-C, and the corpus sweep asserting `typeCode` against Apple's
    /// own `PortTypeDescription` is what would catch that. Prefer the port's own
    /// reported `portTypeDescription` when you have it.
    public var typeDescription: String {
        typeCode == Self.magSafeTypeCode ? "MagSafe 3" : "USB-C"
    }

    public var isMagSafe: Bool { typeCode == Self.magSafeTypeCode }

    /// Parses the `"type/number"` string form. Returns nil for anything else,
    /// so a malformed key becomes "no port" rather than port 0.
    public init?(key: String) {
        let parts = key.split(separator: "/")
        guard parts.count == 2,
              let typeCode = Int(parts[0]),
              let number = Int(parts[1])
        else { return nil }
        self.typeCode = typeCode
        self.number = number
    }

    /// Parses a key the way the old hand-written display code did: take the
    /// first component as the type and the second as the number, and ignore
    /// anything else.
    ///
    /// Kept separate from `init?(key:)` on purpose. The strict form is right
    /// for a join key, where a malformed string means "no port" and silently
    /// half-reading it would attribute one port's data to another. This form is
    /// right for the one place that only wants a LABEL and already has its own
    /// fallback for the number: rejecting `"17/2/extra"` there turns a MagSafe
    /// card into a USB-C card, which is worse than tolerating the odd shape.
    ///
    /// Found by the Codex review: the consolidation had replaced the tolerant
    /// parser with the strict one and called it identical. Nothing produces a
    /// three-part key today, so it was latent, but the two are not the same
    /// function and now they are not the same call.
    ///
    /// The two components are read INDEPENDENTLY, which the first version of
    /// this function got wrong: it bailed out entirely when the type component
    /// failed to parse, throwing away a perfectly good port number with it. The
    /// original computed them separately, so `"USB-C/1"` gave a USB-C label AND
    /// port 1, where the first rewrite gave USB-C and the caller's fallback
    /// index. Caught by running both implementations side by side rather than
    /// reading them, which is how it should have been checked the first time.
    ///
    /// Never returns nil: an unreadable type is USB-C, the same default the
    /// original fell back to, and an unreadable number becomes
    /// `fallbackNumber`.
    ///
    /// The fallback is a PARAMETER rather than a sentinel, and that is the
    /// second correction this function has needed. The previous version
    /// returned 0 to mean "no usable number" and left the caller to substitute,
    /// which quietly made a real port number of 0 indistinguishable from a
    /// missing one: the original's `Optional(0) ?? fallback` is 0, not the
    /// fallback. Nothing emits a port 0 today (numbers are 1-based), so it was
    /// unreachable, but it is the third time in this file's short life that
    /// folding two decisions into one value has lost information. Doing the
    /// whole computation here, exactly as the original did, removes the seam
    /// that keeps producing these.
    public static func lenient(key: String, fallbackNumber: Int) -> PortIdentity {
        let parts = key.split(separator: "/")
        let typeCode = parts.first.flatMap { Int($0) } ?? usbCTypeCode
        let number = (parts.count > 1 ? Int(parts[1]) : nil) ?? fallbackNumber
        return PortIdentity(typeCode: typeCode, number: number)
    }

    /// Builds an identity from what Apple reports about a port.
    ///
    /// This is the single place the type-code rule lives:
    ///
    /// - A description starting with "MagSafe" is MagSafe, whatever else is
    ///   reported. MagSafe is the case where getting it wrong is worst (a
    ///   charge-only connector shown as a data port), and the description is
    ///   the more reliable signal of the two.
    /// - Otherwise the reported `PortType` is trusted as-is, so a connector
    ///   this code has never seen keeps its own identity instead of being
    ///   flattened into USB-C. The A18 Pro machines in the corpus publish a
    ///   `Port-Inductive` node, which is exactly that case.
    /// - With no reported type, USB-C is the fallback.
    ///
    /// - Parameters:
    ///   - typeDescription: Apple's `PortTypeDescription`, e.g. "USB-C".
    ///   - reportedTypeCode: Apple's `PortType`, when the caller has it. Pass
    ///     nil when the source does not publish it.
    ///   - number: the `@N` port number.
    public static func from(typeDescription: String?, reportedTypeCode: Int?, number: Int) -> PortIdentity {
        if typeDescription?.hasPrefix("MagSafe") == true {
            return PortIdentity(typeCode: magSafeTypeCode, number: number)
        }
        return PortIdentity(typeCode: reportedTypeCode ?? usbCTypeCode, number: number)
    }

    /// Builds an identity from a registry node name like `"Port-MagSafe 3@1"`.
    ///
    /// Separate from ``from(typeDescription:reportedTypeCode:number:)`` because
    /// the input really is different: a node name is matched with `contains`
    /// rather than `hasPrefix` (the name is prefixed with "Port-"), and a caller
    /// walking the registry by name has no `PortType` property to read.
    public static func from(serviceName: String, number: Int) -> PortIdentity {
        PortIdentity(
            typeCode: serviceName.contains("MagSafe") ? magSafeTypeCode : usbCTypeCode,
            number: number
        )
    }

    /// Sorts MagSafe and USB-C into stable groups, then by port number. Used
    /// wherever ports are listed, so two surfaces cannot disagree on order.
    public static func < (lhs: PortIdentity, rhs: PortIdentity) -> Bool {
        if lhs.typeCode != rhs.typeCode { return lhs.typeCode < rhs.typeCode }
        return lhs.number < rhs.number
    }
}
