import Foundation

#if DEBUG
/// Formats a `DiagnosticContract` for the internal diagnostic screen.
///
/// This is the whole of Swift's involvement in the reasoning: formatting. Every
/// value is read straight from the contract. Nothing is inferred: a suspect's
/// state comes from the contract's authoritative `status`, confidence is only the
/// contract's number rendered as a percentage, and provenance is preserved in
/// contract order with faithful labels.
///
/// `validationIssues` is the visible-failure boundary: an internally inconsistent
/// or malformed contract is reported, never rendered as if it were sound.
public struct DiagnosticPresentation: Sendable, Equatable {
    public let contract: DiagnosticContract
    public init(_ contract: DiagnosticContract) { self.contract = contract }

    private var d: DiagnosticContract.Diagnosis { contract.diagnosis }

    // MARK: Validation (fail visibly, never partially)

    /// Cross-field invariants. Non-empty means the contract must NOT be rendered
    /// as a normal diagnosis; the view shows these instead.
    public var validationIssues: [String] {
        var issues: [String] = []
        if contract.schemaVersion != DiagnosticContract.supportedSchemaVersion {
            issues.append("unsupported schema version \(contract.schemaVersion)")
        }
        if d.matched {
            if d.conclusion == nil { issues.append("matched but no conclusion") }
            if !hasValidConfidence { issues.append("matched but confidence is missing or out of range") }
        } else if d.rejection == nil {
            issues.append("rejected but no rejection detail")
        }
        for s in d.suspects {
            if !Self.knownStatuses.contains(s.status) {
                issues.append("suspect '\(s.name)' has unrecognised status '\(s.status)'")
            }
            if (s.status == "localised_drop") != s.localisedDrop {
                issues.append("suspect '\(s.name)' status and localisedDrop disagree")
            }
            if s.status == "localised_drop", s.capabilityIn == nil || s.capabilityOut == nil {
                issues.append("suspect '\(s.name)' claims a drop without both capabilities")
            }
        }
        for p in d.provenance where !Self.knownLayers.contains(p.layer) {
            issues.append("unknown provenance layer '\(p.layer)'")
        }
        for c in d.trace.claims where !(c.confidence.isFinite && (0.0...1.0).contains(c.confidence)) {
            issues.append("claim '\(c.claim)' confidence out of range")
        }
        return issues
    }

    public var isValid: Bool { validationIssues.isEmpty }

    private var hasValidConfidence: Bool {
        guard let c = d.confidence else { return false }
        return c.isFinite && (0.0...1.0).contains(c)
    }

    private static let knownStatuses: Set<String> = ["unknown", "localised_drop"]
    private static let knownLayers: Set<String> = ["measured", "demonstrated", "inferred"]

    // MARK: 1, Outcome

    public var outcomeTitle: String {
        d.matched ? "Connection-path restriction detected" : "No diagnosis produced"
    }

    /// The contract's confidence rendered as a percentage, attached to the claim
    /// it measures (the endpoint-elimination inference), NOT the existence of a
    /// restriction (which is measured, and certain). Nil unless finite and in range.
    public var confidenceLabel: String? {
        guard hasValidConfidence, let c = d.confidence else { return nil }
        return "Confidence the endpoint is not the limit: \(Int((c * 100).rounded()))%"
    }

    public var isSynthetic: Bool { contract.synthetic }

    public var syntheticBanner: String? {
        contract.synthetic ? "SYNTHETIC: a constructed counterexample, not real evidence" : nil
    }

    // MARK: 2, Explanation

    public var explanation: String {
        d.matched ? (d.conclusion ?? "") : (d.rejection?.explanation ?? "")
    }

    /// The honest limit. Only claims a localised drop when the contract supplies one.
    public var limitNote: String? {
        guard d.matched else { return nil }
        return suspects.contains(where: { $0.state == .localisedDrop })
            ? "The measured capability drops at the hop marked below."
            : "Available evidence cannot yet distinguish the remaining suspects."
    }

    // MARK: Rejection (surfaced, not buried)

    public var isRejected: Bool { !d.matched }

    public var rejection: (precondition: String, explanation: String)? {
        d.rejection.map { ($0.precondition, $0.explanation) }
    }

    // MARK: 3, Ruled out

    public var ruledOut: [(name: String, reason: String)] {
        d.eliminated.map { ($0.name, $0.reason) }
    }

    // MARK: 4, Remaining suspects

    public enum SuspectState: String, Sendable, Equatable { case unknown, localisedDrop }

    public struct SuspectRow: Sendable, Equatable {
        public let name: String
        public let visibility: String
        public let state: SuspectState
        /// Present ONLY for a supplied localised drop with both capabilities.
        public let capabilityLine: String?
    }

    public var suspects: [SuspectRow] {
        d.suspects.map { s in
            // State comes from the authoritative status. A drop is honoured only
            // when the status says so AND both capabilities are present; anything
            // else degrades to unknown (the conservative, no-false-certainty side).
            let isDrop = s.status == "localised_drop" && s.capabilityIn != nil && s.capabilityOut != nil
            let capabilityLine: String? = isDrop
                ? "\(Self.fmt(s.capabilityIn!)) to \(Self.fmt(s.capabilityOut!))"
                : nil
            return SuspectRow(name: s.name, visibility: s.visibility,
                              state: isDrop ? .localisedDrop : .unknown,
                              capabilityLine: capabilityLine)
        }
    }

    // MARK: 5, Evidence and provenance

    public var evidence: [(kind: String, detail: String)] { d.evidence.map { ($0.kind, $0.detail) } }

    public struct ProvenanceRow: Sendable, Equatable {
        public let label: String
        public let detail: String
        public let known: Bool
    }

    /// Provenance in contract order, with faithful labels. Unknown layers are kept
    /// (never dropped) and marked, so nothing vanishes silently.
    public var provenanceRows: [ProvenanceRow] {
        d.provenance.map { p in
            switch p.layer {
            case "measured":     return ProvenanceRow(label: "Measured on this Mac", detail: p.detail, known: true)
            case "demonstrated": return ProvenanceRow(label: "Demonstrated in the corpus", detail: p.detail, known: true)
            case "inferred":     return ProvenanceRow(label: "Inferred", detail: p.detail, known: true)
            default:             return ProvenanceRow(label: "Layer: \(p.layer)", detail: p.detail, known: false)
            }
        }
    }

    // MARK: 6, Reasoning trace

    public var preconditions: [(name: String, passed: Bool, evidence: String)] {
        d.trace.preconditions.map { ($0.name, $0.passed, $0.evidence) }
    }

    /// Claim confidence is pre-formatted as a safe percentage here, so no view
    /// does a raw `Int(Double)` that could trap on a non-finite value.
    public var claims: [(claim: String, support: [String], confidencePercent: Int)] {
        d.trace.claims.map { c in
            let clamped = c.confidence.isFinite ? min(max(c.confidence, 0), 1) : 0
            return (c.claim, c.support, Int((clamped * 100).rounded()))
        }
    }

    private static func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }
}
#endif
