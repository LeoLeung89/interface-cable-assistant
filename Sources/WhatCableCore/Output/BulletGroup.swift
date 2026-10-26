import Foundation

/// One attributed section of a port card.
///
/// A port card's lines come from four different places with four different
/// reliabilities: the cable's e-marker (a claim), the charger's PDOs (a
/// claim), the Mac's own controllers (a measurement), and WhatCable's
/// bundled database (our records). Rendering them as one flat list of
/// equal-weight bullets made it impossible to tell which was which, and
/// let a claim read as a fact.
///
/// See the private design note "port-card source attribution".
public struct BulletGroup: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        /// The Mac's controllers. A measurement, wrong only if we misread
        /// the registry.
        case measured
        /// The cable's e-marker. A claim by the cable about itself.
        case emarker
        /// The charger's advertised capabilities. A claim by the charger.
        case charger
        /// WhatCable's bundled vendor / cable / certification data.
        case database
    }

    public let kind: Kind
    /// Group heading, e.g. "What your Mac measured".
    public let header: String
    /// State of the group as a whole, e.g. "Not read on this connection."
    /// This is where "we don't know" lives, so it is never mistaken for a
    /// value inside the group.
    public let subtitle: String?
    public let lines: [String]

    public init(kind: Kind, header: String, subtitle: String? = nil, lines: [String]) {
        self.kind = kind
        self.header = header
        self.subtitle = subtitle
        self.lines = lines
    }

    /// A group with nothing to say is dropped rather than rendered empty.
    public var isEmpty: Bool { lines.isEmpty && (subtitle?.isEmpty ?? true) }
}

extension PortSummary {
    /// The group of a given kind, or nil when it had nothing to say.
    public func group(_ kind: BulletGroup.Kind) -> BulletGroup? {
        groups.first { $0.kind == kind }
    }
}

extension BulletGroup.Kind {
    public var header: String {
        switch self {
        case .measured:
            return String(localized: "What your Mac measured", bundle: _coreLocalizedBundle)
        case .emarker:
            return String(localized: "What the cable's e-marker reports", bundle: _coreLocalizedBundle)
        case .charger:
            return String(localized: "What the charger reports", bundle: _coreLocalizedBundle)
        case .database:
            return String(localized: "What WhatCable knows", bundle: _coreLocalizedBundle)
        }
    }
}
