import Foundation
import Testing

/// Guards the free/Pro boundary on the connected-devices tree.
///
/// The free tree answers "what is plugged in": device name, speed, hierarchy.
/// Per-device INSPECTION (vendor, serial number, USB version, device class,
/// power requested and available, raw IOKit properties) is what the Pro Cable
/// Diagnostics screen sells, and that screen already shows all of it.
///
/// This exists because the boundary was crossed once without anyone noticing.
/// Between v1.2.1 and the 1.3.0 betas the free row grew an expandable detail
/// panel (#451) and the maker inline in the name (#424). The result was a free
/// tree strictly RICHER than the Pro screen's own device card: free had the
/// hierarchy AND the per-device detail, Pro had a flat list. It took four PRs
/// (#351, #411, #451, #452), each a reasonable-looking increment, and nothing
/// compared the two surfaces along the way. Caught and pulled before it reached
/// a stable release, so no shipped build ever had it.
///
/// A source-level check, for the same reason `SharedWatcherOwnershipTests` is
/// one: the thing worth preventing is a line of code being typed, not a runtime
/// value. Rendering a SwiftUI row in a test would need a host app and would
/// still not answer "is this field allowed to be here".
///
/// **This is a product decision, not a technical one.** If you are deliberately
/// moving a field into the free tier, change the list below and say why in the
/// commit. The test is here to make that a decision rather than an accident.
@Suite("Free device tree stays shallower than the Pro card")
struct FreeDeviceTreeDepthTests {

    /// Fields that belong to Pro's per-device inspection, spelled as they would
    /// appear in the free row's source.
    private static let proOnlyFields = [
        "serialNumber",
        "usbVersion",
        "deviceClass",
        "busPowerMA",
        "currentMA",
        "rawProperties",
        // NOT listed: `vendorName` / `displayName`. The maker is identification
        // and is deliberately shown; see `rowNamesTheMaker`.
    ]

    private static let contentViewSource: String = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WhatCableAppTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/WhatCable/Views/ContentView.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    /// The body of `struct USBDeviceRow`, from its declaration to the next
    /// top-level `struct`. Scoped tightly so a mention of these fields
    /// elsewhere in the file (the Pro-adjacent cards, the port summary) does
    /// not trip the check.
    private static func usbDeviceRowSource() -> String? {
        let source = contentViewSource
        guard let start = source.range(of: "struct USBDeviceRow: View {") else { return nil }
        let rest = source[start.upperBound...]
        guard let end = rest.range(of: "\nstruct ") else { return String(rest) }
        return String(rest[..<end.lowerBound])
    }

    @Test("The free device row is found and parsed, so this suite is not asserting on nothing")
    func rowSourceIsReachable() throws {
        #expect(!Self.contentViewSource.isEmpty, "Could not read ContentView.swift; the path has moved and this guard is dead")
        let row = try #require(Self.usbDeviceRowSource(), "Could not locate `struct USBDeviceRow: View {` in ContentView.swift")
        #expect(row.contains("speedLabel"), "Found a USBDeviceRow that does not render a speed; the parser is probably matching the wrong region")
        #expect(row.count > 100, "The extracted USBDeviceRow body is implausibly short (\(row.count) chars)")
    }

    @Test("The free device row shows no per-device inspection fields")
    func rowHasNoProFields() throws {
        let row = try #require(Self.usbDeviceRowSource())
        var found: [String] = []
        for field in Self.proOnlyFields where row.contains(field) {
            found.append(field)
        }
        #expect(found.isEmpty, """
            The free connected-devices row references Pro inspection field(s): \(found.joined(separator: ", ")).

            That tree answers "what is plugged in". Vendor, serial, USB version, device class and \
            power figures are what the Pro Cable Diagnostics screen sells, and it already shows \
            them all. Adding one here makes the free surface richer than the paid one, which is \
            exactly what happened across #451 and #424 and had to be pulled.

            If this IS a deliberate tier change, update `proOnlyFields` and justify it in the commit.
            """)
    }

    @Test("The free device row keeps the maker in the name")
    func rowNamesTheMaker() throws {
        // The maker is IDENTIFICATION, not inspection, and it stays.
        //
        // It was briefly removed along with the detail panel, on the reasoning
        // that both arrived in the same unreleased PRs. That went too far, and
        // the app itself showed why: on a UGreen TB5 dock four rows collapsed
        // to the byte-identical "USB2.0 Hub - High Speed (480 Mbps)" with
        // nothing to tell Fresco Logic, Apple and two VIA Labs hubs apart.
        //
        // The line that matters is diagnosis, not identification. A maker is
        // printed on the device and sits in `--json`; a serial number, device
        // class and power figures are what the Pro card sells.
        let row = try #require(Self.usbDeviceRowSource())
        #expect(row.contains("device.displayName"),
            "The free row should use `displayName`, which includes the maker. Without it, sibling hubs on a dock render identically and the tree cannot be read.")
    }

    @Test("The row renders the label the row builder gave it")
    func rowHonoursTheSuppliedLabel() throws {
        // The failure this prevents: `ConnectedDeviceTree` computes an
        // annotated label ("... via 3 hubs") and the view throws it away,
        // rebuilding its own text from the device. That shipped through a full
        // Core test suite because those tests assert on `Row.label`, which was
        // correct the whole time. Nothing checked that anyone rendered it.
        let row = try #require(Self.usbDeviceRowSource())
        #expect(row.contains("label ??"),
            "USBDeviceRow should prefer a caller-supplied label and only fall back to rebuilding one. Without that, anything the row builder adds is silently dropped.")
    }

    @Test("The Thunderbolt row tree passes its labels through to the row")
    func rowTreePassesLabels() throws {
        // The other half of the same bug: the row can honour a label and still
        // never receive one.
        let source = Self.contentViewSource
        #expect(!source.isEmpty)
        guard let start = source.range(of: "private func rowTree(") else {
            Issue.record("Could not locate rowTree in ContentView.swift; this guard is dead")
            return
        }
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    /// ") ?? rest.range(of: "\n    private func ")
        let body = String(end.map { rest[..<$0.lowerBound] } ?? rest.prefix(4000))
        #expect(body.contains("label: row.label"),
            "rowTree must hand `row.label` to USBDeviceRow, or the annotations it builds are never seen.")
    }

    @Test("The app actually asks for the collapsed view")
    func portCardDefaultsToEndpointsOnly() throws {
        // Proven exploitable by an adversarial pass: hardcoding `hubs: .all` at
        // this call site silently disables collapse-by-default and the full
        // 1572-test suite stays green. Same shape as the bug where the row
        // ignored its label: the feature works in Core and nobody asks for it.
        let source = Self.contentViewSource
        #expect(!source.isEmpty)
        #expect(source.contains("hubs: showHubs ? .all : .endpointsOnly"),
            "PortCard must request .endpointsOnly unless the user asked for hubs. Hardcoding .all here disables the collapse with no test failing.")
    }

    @Test("The app actually passes the display depth to the row")
    func portCardPassesDisplayDepth() throws {
        // Also proven exploitable: dropping `displayDepth:` reintroduces the
        // "↳" connector regression this PR fixes, with 0 test failures, because
        // the row falls back to `node.depth`.
        let source = Self.contentViewSource
        #expect(source.contains("USBDeviceRow(node: node, displayDepth: row.depth"),
            "The Thunderbolt row tree must pass `displayDepth: row.depth`, or a subtree-rooting hub loses its connector again.")
    }

    @Test("The free device row has no disclosure affordance")
    func rowHasNoDisclosure() throws {
        // The DisclosureGroup was not only tier leakage, it was misleading: it
        // expanded that device's DETAILS while the children were pre-flattened
        // and always visible, so the chevron sat where a tree toggle lives and
        // did something else entirely.
        let row = try #require(Self.usbDeviceRowSource())
        #expect(!row.contains("DisclosureGroup"),
            "The free device row has a DisclosureGroup again. Its children are pre-flattened by `USBDeviceNode.flatten`, so a chevron here reads as 'collapse this subtree' and does not do that.")
    }
}
