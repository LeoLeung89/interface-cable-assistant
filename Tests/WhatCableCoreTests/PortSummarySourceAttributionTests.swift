import Foundation
import Testing
@testable import WhatCableCore

/// Pins the source-attribution rework: every line is attributed to where it
/// came from, and the three bugs the flat list allowed can no longer be
/// expressed. See the private design note "port-card source attribution".
@Suite("Port card source attribution")
struct PortSummarySourceAttributionTests {

    private func makePort(
        active: [String] = [],
        supported: [String] = ["CC", "USB2"]
    ) -> USBCPort {
        USBCPort(
            id: 1,
            serviceName: "Port-USB-C@1",
            className: "AppleHPMInterfaceType10",
            portDescription: "Port-USB-C@1",
            portTypeDescription: "USB-C",
            portNumber: 1,
            connectionActive: true,
            activeCable: nil,
            opticalCable: nil,
            usbActive: nil,
            superSpeedActive: nil,
            usbModeType: nil,
            usbConnectString: nil,
            transportsSupported: supported,
            transportsActive: active,
            transportsProvisioned: [],
            plugOrientation: nil,
            plugEventCount: nil,
            connectionCount: nil,
            overcurrentCount: nil,
            pinConfiguration: [:],
            powerCurrentLimits: [],
            firmwareVersion: nil,
            bootFlagsHex: nil,
            rawProperties: [:]
        )
    }

    /// An e-marker endpoint that responded but sent no VDOs: present, unread.
    private func unreadEmarker() -> USBPDSOP {
        USBPDSOP(
            id: 99, endpoint: .sopPrime,
            parentPortType: 2, parentPortNumber: 1,
            vendorID: 0, productID: 0, bcdDevice: 0,
            vdos: [], specRevision: 0
        )
    }

    private func charger(amps: Int) -> PowerSource {
        let winning = PowerOption(
            voltageMV: 20_000,
            maxCurrentMA: amps * 1000,
            maxPowerMW: amps * 20_000
        )
        return PowerSource(
            id: 10, name: "USB-PD", parentPortType: 2, parentPortNumber: 1,
            options: [winning], winning: winning
        )
    }

    // MARK: - Bug A

    // The card advised "needs above 3A or Thunderbolt" as static text, on a
    // port that was negotiating 5 A, and again on a port with a live
    // Thunderbolt link. Observed on the owner's M5, 2026-08-10.
    //
    // The advice is now conditioned on the very signals that made it wrong,
    // so a port already meeting the read conditions cannot be told to meet
    // them.

    @Test("Bug A: a port negotiating above 3A is never told it needs above 3A")
    func above3ANeverAdvisedToExceed3A() {
        let summary = PortSummary(
            port: makePort(active: ["USB2"]),
            sources: [charger(amps: 5)],
            identities: [unreadEmarker()]
        )
        let subtitle = summary.group(.emarker)?.subtitle
        #expect(subtitle?.contains("not read on this connection") == true,
                "expected the not-read state, got: \(String(describing: subtitle))")
        #expect(subtitle?.contains("above 3A") != true,
                "a port at 5 A must not be told it needs above 3 A, got: \(String(describing: subtitle))")
    }

    @Test("Bug A: a Thunderbolt port is never told it needs Thunderbolt")
    func thunderboltPortNeverAdvisedToUseThunderbolt() {
        let summary = PortSummary(
            port: makePort(active: ["CIO"], supported: ["CC", "USB2", "CIO"]),
            identities: [unreadEmarker()]
        )
        let subtitle = summary.group(.emarker)?.subtitle
        #expect(subtitle?.contains("not read on this connection") == true,
                "expected the not-read state, got: \(String(describing: subtitle))")
        #expect(subtitle?.contains("Thunderbolt") != true,
                "a live Thunderbolt port must not be told to use Thunderbolt, got: \(String(describing: subtitle))")
    }

    // MARK: - Retired strings

    @Test("The retired read-state and passive wording never comes back")
    func readStateStringsAreNoLongerBullets() {
        // The exact old strings. Verbatim, not fragments: the new subtitles
        // deliberately reuse some of the same phrasing ("No e-marker read",
        // "can't read cable details"), so a fragment match would fail on the
        // replacement wording and prove nothing. What must never come back is
        // one of these sentences, whole.
        let retired = [
            "Cable has an e-marker chip (advertises its capabilities)",
            "Cable has an e-marker chip, not read on this connection (needs above 3A or Thunderbolt, or try reconnecting the cable)",
            "This port can't read cable details (USB-only port, no Power Delivery)",
            "No e-marker detected. This cable doesn't advertise its capabilities.",
            "No e-marker detected. The cable may have one, but macOS only reads it above 3A or with Thunderbolt.",
        ]
        // The two passive explanations bug C retired. These are the ones that
        // said something false about the cable, so they matter most.
        let retiredPassiveWording = [
            "active electronics handle Thunderbolt",
            "Thunderbolt is negotiated separately by the controller",
        ]
        // Four read states, exercised through the real init.
        let summaries = [
            // present and read
            PortSummary(port: makePort(active: ["USB2"]), identities: [
                USBPDSOP(id: 1, endpoint: .sopPrime, parentPortType: 2, parentPortNumber: 1,
                         vendorID: 0x05AC, productID: 0, bcdDevice: 0,
                         vdos: [(3 << 27), 0, 0, 0b011 | (2 << 5) | (1 << 13)], specRevision: 3),
            ]),
            // present, unread
            PortSummary(port: makePort(active: ["USB2"]), identities: [unreadEmarker()]),
            // absent, PD-capable
            PortSummary(port: makePort(active: ["USB2"]), sources: [charger(amps: 3)]),
            // absent, port has no PD at all
            PortSummary(port: makePort(active: ["USB3"], supported: ["USB2", "USB3"]),
                        sources: [charger(amps: 3)]),
        ]
        for summary in summaries {
            // Lines AND subtitles. Scanning lines alone would let a retired
            // sentence come back as a subtitle unnoticed, which is exactly the
            // coverage this test gave up when it moved off `bullets`.
            let allText = summary.groups.flatMap { $0.lines + ($0.subtitle.map { [$0] } ?? []) }
            for text in allText {
                for phrase in retired + retiredPassiveWording {
                    #expect(!text.contains(phrase),
                            "retired wording is back: \(text)")
                }
            }
        }
    }

    // MARK: - The passive line, deliberately widened

    /// Before this rework the "passive" wording only appeared on a live
    /// Thunderbolt link. It now states the e-marker's own claim on every read
    /// cable, Thunderbolt or not, because it is a fact the cable reported and
    /// the group reads as incomplete without it. Owner decision, 2026-08-10.
    /// 154 of 157 cables in the corpus are passive, so this line is on almost
    /// every card: pin it here so the widening stays conscious.
    @Test("A passive cable says so on an ordinary USB port, not just Thunderbolt")
    func passiveLineAppearsWithoutThunderbolt() {
        let summary = PortSummary(
            port: makePort(active: ["USB3"], supported: ["CC", "USB2", "USB3"]),
            identities: [
                USBPDSOP(id: 1, endpoint: .sopPrime, parentPortType: 2, parentPortNumber: 1,
                         vendorID: 0x2EC8, productID: 0, bcdDevice: 0,
                         // ID header product type 3 = passive cable.
                         vdos: [(3 << 27) | 0x2EC8, 0, 0, 0b010 | (1 << 5) | (1 << 13)], specRevision: 3),
            ]
        )
        #expect(summary.bullets.contains { $0.contains("Passive (no signal-conditioning electronics)") },
                "expected the passive line on a non-Thunderbolt port, got: \(summary.bullets)")
    }

    // MARK: - Partial e-marker

    /// An e-marker that answered but sent nothing we can decode: an ID header
    /// alone, zero vendor, no Cable VDO, no certification. Every line in the
    /// group comes from one of those, so without a subtitle the group would be
    /// empty and the filter would drop it, leaving the user with no mention of
    /// the cable at all. The old flat list said "Cable has an e-marker chip".
    @Test("An e-marker that answers with nothing decodable still says so")
    func partialEmarkerStillExplainsItself() {
        let summary = PortSummary(
            port: makePort(active: ["USB2"]),
            identities: [
                USBPDSOP(id: 1, endpoint: .sopPrime, parentPortType: 2, parentPortNumber: 1,
                         vendorID: 0, productID: 0, bcdDevice: 0,
                         vdos: [(3 << 27)], specRevision: 3),
            ]
        )
        let group = summary.group(.emarker)
        #expect(group != nil, "the e-marker group must not be dropped, got: \(summary.groups)")
        #expect(group?.lines.isEmpty == true)
        #expect(group?.subtitle?.contains("no capability data") == true,
                "expected an explanation, got: \(String(describing: group?.subtitle))")
    }

    // MARK: - The read state has to actually reach the user

    /// `bullets` cannot carry a subtitle, so a renderer that reads only
    /// `bullets` shows nothing at all on a port whose e-marker was not read.
    /// That is the regression this pair of tests exists to catch: it is not
    /// enough for the model to hold the explanation, the output has to print
    /// it. Both formatters are checked because they are the two surfaces that
    /// ship text outside the app process.
    @Test("The CLI prints the e-marker read state, not just the lines")
    func cliRendersTheReadState() {
        let port = makePort(active: ["USB2"])
        let out = TextFormatter.render(
            ports: [port],
            sources: [],
            identities: [unreadEmarker()],
            showRaw: false
        )
        #expect(out.contains("not read on this connection"),
                "the CLI must print the read state, got: \(out)")
        #expect(out.contains("What the cable's e-marker reports"),
                "the CLI must print the group headers, got: \(out)")
    }

    @Test("The JSON carries the e-marker read state under bulletGroups")
    func jsonCarriesTheReadState() throws {
        let port = makePort(active: ["USB2"])
        let json = try JSONFormatter.render(
            ports: [port], sources: [], identities: [unreadEmarker()], showRaw: false
        )
        let obj = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let portJSON = try #require((obj["ports"] as? [[String: Any]])?.first)
        let groups = try #require(portJSON["bulletGroups"] as? [[String: Any]])
        let emarker = try #require(groups.first { $0["source"] as? String == "emarker" })
        #expect((emarker["state"] as? String)?.contains("not read on this connection") == true,
                "expected the read state in the JSON, got: \(emarker)")
        // The legacy key stays, so existing scripts keep working.
        #expect(portJSON["bullets"] as? [String] != nil)
    }

    // MARK: - Flattening

    /// The desktop widget shows `bullets.first` as its one line of detail
    /// (`WidgetSnapshot.PortEntry.topBullet`, and the same expression in
    /// `WidgetDataWriter`). Grouping changed what "first" means, so pin it:
    /// the widget must lead with something the Mac measured, never with a
    /// claim the cable or charger made about itself.
    ///
    /// The widget runs in a separate process doing its own IOKit reads, so
    /// both sites must agree. They share this expression, which is why one
    /// test covers both.
    @Test("The widget's top bullet comes from the measured group")
    func topBulletIsAMeasurement() {
        let summary = PortSummary(
            port: makePort(active: ["USB3"], supported: ["CC", "USB2", "USB3"]),
            sources: [charger(amps: 5)],
            identities: [
                USBPDSOP(id: 1, endpoint: .sopPrime, parentPortType: 2, parentPortNumber: 1,
                         vendorID: 0x05AC, productID: 0, bcdDevice: 0,
                         vdos: [(3 << 27) | 0x05AC, 0, 0, 0b011 | (2 << 5) | (1 << 13)], specRevision: 3),
            ]
        )
        let top = summary.topLine
        #expect(top != nil)
        #expect(summary.group(.measured)?.lines.first == top,
                "the widget must lead with a measurement when there is one, got: \(String(describing: top))")
        // The charger and the cable both have plenty to say on this fixture,
        // so leading with a measurement is a real choice, not the only option.
        #expect(summary.group(.charger)?.lines.isEmpty == false)
        #expect(summary.group(.emarker)?.lines.isEmpty == false)
    }

    /// The case the test above cannot reach: nothing is negotiating and no
    /// transport is active, so the measured group is empty and gets dropped.
    /// The widget's line is then a read state, not a measurement.
    ///
    /// That is intended, not a gap. It is the only useful thing to say on such
    /// a port, and it is what the widget showed before the lines were
    /// attributed, when the read state was an ordinary bullet that happened to
    /// sort first. The test above asserts a measurement comes first WHEN THERE
    /// IS ONE; this one pins what happens when there isn't, so the pair
    /// describes the whole behaviour rather than implying a guarantee that
    /// does not hold.
    @Test("With nothing measured, the widget falls back rather than going blank")
    func topBulletFallsBackWhenNothingWasMeasured() {
        let summary = PortSummary(
            port: makePort(active: [], supported: ["CC", "USB2"]),
            identities: [unreadEmarker()]
        )
        #expect(summary.group(.measured) == nil, "this fixture must have nothing measured")
        #expect(summary.topLine?.contains("not read on this connection") == true,
                "expected the read state as the fallback, got: \(String(describing: summary.topLine))")
    }

    /// Within a group, order is still meaningful: the measured group reads
    /// link, then what is plugged in, then the power contract. The old flat
    /// list had an ordering test; grouping replaced the cross-group half of
    /// it, but the within-group half still needs guarding.
    @Test("The measured group reads link, then device, then contract")
    func measuredGroupKeepsItsOrder() {
        // issue #181: corroborate with a TRM-restricted, no-precise-signaling
        // transport so the "SuperSpeed USB" generic line this test pins
        // (ordering within the measured group) actually appears.
        let corroboratingTransport = USB3Transport(
            id: 9000, portKey: "2/1", signaling: nil,
            signalingDescription: nil, dataRole: "host",
            transportRestricted: true
        )
        let summary = PortSummary(
            port: makePort(active: ["USB3"], supported: ["CC", "USB2", "USB3"]),
            sources: [charger(amps: 5)],
            identities: [
                USBPDSOP(id: 2, endpoint: .sop, parentPortType: 2, parentPortNumber: 1,
                         vendorID: 0x05AC, productID: 0, bcdDevice: 0,
                         vdos: [(2 << 27) | 0x05AC], specRevision: 3),
            ],
            usb3Transports: [corroboratingTransport]
        )
        let lines = summary.group(.measured)?.lines ?? []
        func idx(_ needle: String) -> Int? { lines.firstIndex { $0.contains(needle) } }
        guard let speed = idx("SuperSpeed USB"),
              let device = idx("Connected device"),
              let contract = idx("Currently negotiated") else {
            Issue.record("expected all three measured lines, got: \(lines)")
            return
        }
        #expect(speed < device, "link speed comes before what is plugged in")
        #expect(device < contract, "what is plugged in comes before the power contract")
    }

    /// `ContentView` renders the groups with `ForEach(summary.groups, id: \.kind)`,
    /// so two groups sharing a kind would hand SwiftUI duplicate identities and
    /// its diffing would be undefined. One group per kind holds today because
    /// the array is hand-built with one literal each, but nothing enforces it
    /// structurally, so pin it here.
    @Test("A summary never carries two groups of the same kind")
    func groupKindsAreUnique() {
        let summaries = [
            PortSummary(port: makePort(active: ["USB2"]), sources: [charger(amps: 5)], identities: [
                USBPDSOP(id: 1, endpoint: .sopPrime, parentPortType: 2, parentPortNumber: 1,
                         vendorID: 0x05AC, productID: 0, bcdDevice: 0,
                         vdos: [(3 << 27) | 0x05AC, 0, 0, 0b011 | (2 << 5) | (1 << 13)], specRevision: 3),
            ]),
            PortSummary(port: makePort(active: ["CIO"], supported: ["CC", "USB2", "CIO"]),
                        identities: [unreadEmarker()]),
            PortSummary(port: makePort(active: ["USB3"], supported: ["USB2", "USB3"])),
        ]
        for summary in summaries {
            let kinds = summary.groups.map(\.kind)
            #expect(kinds.count == Set(kinds).count, "duplicate group kind in \(kinds)")
        }
    }

    @Test("bullets is the groups flattened, read state first within each group")
    func bulletsMatchGroups() {
        let summary = PortSummary(
            port: makePort(active: ["USB2"]),
            sources: [charger(amps: 5)],
            identities: [
                USBPDSOP(id: 1, endpoint: .sopPrime, parentPortType: 2, parentPortNumber: 1,
                         vendorID: 0x05AC, productID: 0, bcdDevice: 0,
                         vdos: [(3 << 27) | 0x05AC, 0, 0, 0b011 | (2 << 5) | (1 << 13)], specRevision: 3),
            ]
        )
        #expect(summary.bullets == summary.groups.flatMap(\.lines))
        #expect(!summary.groups.contains { $0.isEmpty }, "empty groups must be dropped")

        // A group carrying only a read state must still put that text into
        // `bullets`. This is what keeps the JSON `bullets` key and the widget
        // seeing everything they saw before the lines were attributed: a
        // script grepping for the read state would otherwise silently stop
        // matching.
        let unread = PortSummary(port: makePort(active: ["USB2"]), identities: [unreadEmarker()])
        let state = try? #require(unread.group(.emarker)?.subtitle)
        #expect(unread.bullets.contains { $0 == state })
        #expect(unread.bullets == unread.groups.flatMap { g in
            (g.subtitle.map { [$0] } ?? []) + g.lines
        })
    }
}
