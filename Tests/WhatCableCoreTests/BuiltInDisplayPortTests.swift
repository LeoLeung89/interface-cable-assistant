import Foundation
import Testing
@testable import WhatCableCore

@Suite("Built-in display port grouping")
struct BuiltInDisplayPortTests {

    /// Matches the real corpus shape: `ParentPortBuiltIn` is NOT set on
    /// `IOPortTransportStateDisplayPort` nodes for native HDMI ports (0 of
    /// 79 corpus blocks emit it), so the fixture leaves it at its default
    /// `false`. The grouping function must not rely on it.
    private func makeDP(
        parentPortTypeDescription: String?,
        parentPortNumber: Int,
        tunneled: Bool = false
    ) -> IOPortTransportStateDisplayPort {
        IOPortTransportStateDisplayPort(
            link: DisplayPortLink(
                active: true, laneCount: 4, maxLaneCount: 4, linkRate: 4,
                linkRateDescription: "8.1 Gbps (HBR3)", tunneled: tunneled, hpdState: 1
            ),
            monitor: nil,
            parentPortType: parentPortTypeDescription == "HDMI" ? 6 : 2,
            parentPortTypeDescription: parentPortTypeDescription,
            parentPortNumber: parentPortNumber
        )
    }

    @Test("Groups one DP node per native HDMI port (the M3 Max MBP case)")
    func groupsSingleHDMIPort() {
        let dp = makeDP(parentPortTypeDescription: "HDMI", parentPortNumber: 1)
        let ports = BuiltInDisplayPort.group(from: [dp])
        #expect(ports.count == 1)
        let port = try? #require(ports.first)
        #expect(port?.portType == "HDMI")
        #expect(port?.portNumber == 1)
        #expect(port?.serviceName == "Port-HDMI@1")
        #expect(port?.displays.count == 1)
    }

    @Test("Excludes USB-C parents: those already have an AppleHPMInterface")
    func excludesUSBCParents() {
        let dp = makeDP(parentPortTypeDescription: "USB-C", parentPortNumber: 2)
        let ports = BuiltInDisplayPort.group(from: [dp])
        #expect(ports.isEmpty)
    }

    @Test("Excludes inactive DP nodes (idle HDMI port with nothing plugged in)")
    func excludesInactiveLinks() {
        // Real corpus shape: a Mac with a native HDMI port and nothing
        // attached emits an `IOPortTransportStateDisplayPort` node with
        // `Active = false`. The port entity must not be created from that
        // (the contract is "show only when a display is plugged in") and
        // the synthesized headline / iconography can then assume a real
        // display is present.
        let dp = IOPortTransportStateDisplayPort(
            link: DisplayPortLink(
                active: false, laneCount: 0, maxLaneCount: 4, linkRate: 0,
                linkRateDescription: "No Link", tunneled: false, hpdState: 1
            ),
            monitor: nil,
            parentPortType: 6,
            parentPortTypeDescription: "HDMI",
            parentPortNumber: 1
        )
        #expect(BuiltInDisplayPort.group(from: [dp]).isEmpty)
    }

    @Test("Excludes tunnelled DP nodes: those sit downstream of a USB-C port")
    func excludesTunnelled() {
        // Belt-and-braces: even if a hypothetical future tunnelled node
        // reported a non-USB-C parent type, the tunnel flag must keep it out
        // of the native-port set.
        let dp = makeDP(parentPortTypeDescription: "HDMI", parentPortNumber: 1, tunneled: true)
        let ports = BuiltInDisplayPort.group(from: [dp])
        #expect(ports.isEmpty)
    }

    @Test("Active and inactive nodes on the same port keep only the active one")
    func mixedActiveInactiveKeepsOnlyActive() {
        // A real corner case (M2 Ultra Mac Studio has two HDMI ports, one
        // could be idle while the other carries a display): the grouping
        // function must not drop the port entry just because a sibling
        // inactive node exists at the same parentPortNumber, and must not
        // include the inactive node in the displays list.
        let active = makeDP(parentPortTypeDescription: "HDMI", parentPortNumber: 1)
        let inactive = IOPortTransportStateDisplayPort(
            link: DisplayPortLink(
                active: false, laneCount: 0, maxLaneCount: 4, linkRate: 0,
                linkRateDescription: "No Link", tunneled: false, hpdState: 1
            ),
            monitor: nil,
            parentPortType: 6,
            parentPortTypeDescription: "HDMI",
            parentPortNumber: 1
        )
        let ports = BuiltInDisplayPort.group(from: [inactive, active])
        #expect(ports.count == 1)
        #expect(ports.first?.displays.count == 1)
        #expect(ports.first?.displays.first?.link.active == true)
    }

    @Test("Multiple DP nodes on the same HDMI port (MST split) group into one entry")
    func groupsByPortNumber() {
        // Two DP nodes with the same parentPortNumber: one HDMI port driving
        // two monitors. The grouping yields a single port entry with both
        // displays attached, mirroring how a USB-C dock fan-out is rendered.
        let dp1 = makeDP(parentPortTypeDescription: "HDMI", parentPortNumber: 1)
        let dp2 = makeDP(parentPortTypeDescription: "HDMI", parentPortNumber: 1)
        let ports = BuiltInDisplayPort.group(from: [dp1, dp2])
        #expect(ports.count == 1)
        #expect(ports.first?.displays.count == 2)
    }

    @Test("Two HDMI ports on the same machine (theoretical: not on any current Mac) yield two entries")
    func twoHDMIPortsGroupSeparately() {
        let dp1 = makeDP(parentPortTypeDescription: "HDMI", parentPortNumber: 1)
        let dp2 = makeDP(parentPortTypeDescription: "HDMI", parentPortNumber: 2)
        let ports = BuiltInDisplayPort.group(from: [dp1, dp2])
        #expect(ports.count == 2)
        #expect(Set(ports.map(\.portNumber)) == Set([1, 2]))
    }

    @Test("Empty input yields empty output")
    func emptyInputEmptyOutput() {
        let ports = BuiltInDisplayPort.group(from: [])
        #expect(ports.isEmpty)
    }
}
