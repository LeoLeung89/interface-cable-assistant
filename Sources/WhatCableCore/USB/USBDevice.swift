import Foundation

/// Which kind of Thunderbolt tunnel carried a tunnelled USB device to the
/// Mac. Two distinct hardware designs produce `isThunderboltTunnelled`:
///
/// - `.usbTunnel`: the fabric tunnels USB itself and the device enumerates
///   under the native tunnel controller (`AppleUSBXHCITR`). TB4/USB4 docks.
/// - `.pcieTunnel`: the dock or display brings its own PCIe xHCI controller
///   (`AppleUSBXHCIFL1100`, `AppleASMediaUSBXHCI`, ...) and the device
///   reaches the Mac over the PCIe tunnel. TB3-era docks and displays
///   (LG UltraFine 5K, CalDigit TS3+ class).
///
/// `nil` (absent) means unknown: fixtures or replays of captures that never
/// recorded the terminator. A nil carrier device enters neither
/// carrier-specific structural join in `ChainDeviceAttribution`; live
/// classification always sets one of the two cases for tunnelled devices.
public enum TunnelCarrier: String, Hashable, Sendable {
    case usbTunnel
    case pcieTunnel
}

public struct USBDevice: Identifiable, Hashable {
    public let id: UInt64
    public let locationID: UInt32
    public let vendorID: UInt16
    public let productID: UInt16
    public let vendorName: String?
    public let productName: String?
    public let serialNumber: String?
    public let usbVersion: String?
    public let speedRaw: UInt8?
    public let busPowerMA: Int?
    public let currentMA: Int?
    /// Index of the XHCI controller this device is attached to, derived from
    /// the upper byte of `locationID` (and confirmed by walking the IOKit
    /// parent chain to the `AppleT*USBXHCI` ancestor). Used to associate the
    /// device with its physical USB-C port. `nil` if the parent walk failed.
    public let busIndex: Int?
    /// Service name of the physical port this device's XHCI controller is
    /// wired to (e.g. "Port-USB-C@1"), parsed from the controller's
    /// `UsbIOPort` property. This is a direct mapping and is preferred over
    /// `busIndex` when available. `nil` on machines that don't expose
    /// `UsbIOPort` on the XHCI controller.
    public let controllerPortName: String?
    /// True when this device reached the Mac over a Thunderbolt tunnel rather
    /// than a native USB-C bus, i.e. it sits behind a Thunderbolt dock or
    /// display and enumerates under the tunnelled host controller
    /// (`AppleUSBXHCITR`) with no `UsbIOPort` ancestor. Such devices match no
    /// physical port (issue #274): there is no native port silicon between them
    /// and the controller, so `controllerPortName` is `nil` and the normal
    /// port correlation cannot place them.
    public let isThunderboltTunnelled: Bool
    /// Pure structural signal: this device reached a native USB host controller
    /// with no `Port-USB-C@N` (`UsbIOPort`) ancestor and was not Thunderbolt
    /// tunnelled. On a desktop Mac (mini, Studio, Pro) that means a plain-USB
    /// front-panel port wired to the internal Apple hub, which has no USB-C
    /// port-controller chip (issue #348). The Darwin backend sets it via
    /// `USBWatcher.classifyBehindInternalHub`.
    ///
    /// This flag does NOT itself mean "desktop". The desktop-only product policy
    /// (front ports exist only on desktops) is applied downstream, in one place:
    /// `TunnelledDeviceGrouping.group(isDesktopMac:)`, whose `internalHubDevices`
    /// result is empty on a laptop. Read that result, not this flag directly, to
    /// stay laptop-safe.
    public let isBehindInternalHub: Bool
    /// Count of `"pci-bridge"`-named ancestors between this device's
    /// tunnelled `AppleUSBXHCITR` controller and its `apciecN` PCIe-C host
    /// bridge root. Raw registry truth, captured only for
    /// `isThunderboltTunnelled` devices; `nil` for everything else, and `nil`
    /// when the walk didn't reach an `apciecN` root within its bound.
    /// `ChainDeviceAttribution` divides this by two to get the TB DROM
    /// `Depth` of the switch that owns the tunnel and joins the device to it
    /// structurally, in preference to name matching. See
    /// `research/usb-chain-attribution-identifiers.md` for the corpus
    /// evidence behind the formula.
    public let tunnelBridgeDepth: Int?
    /// The `apciecN` PCIe-C host bridge root name (e.g. `"apciec2"`) the
    /// bridge walk ended at. `nil` under the same conditions as
    /// `tunnelBridgeDepth`.
    public let tunnelRootName: String?
    /// Which tunnel kind carried this device (see `TunnelCarrier`). Only
    /// meaningful when `isThunderboltTunnelled`; `nil` means unknown (old
    /// fixtures/replays) and joins nothing structurally.
    public let tunnelCarrier: TunnelCarrier?
    /// Full IOService-plane registry path of the tunnel/dock controller this
    /// device sits behind, captured via `IORegistryEntryGetPath` at the
    /// moment the ancestor walk hits the controller (before the continuation
    /// walk advances toward `apciecN`). `nil` unless `tunnelCarrier != nil`.
    /// Internal join key for Stage B's PCI-Path-prefix attribution
    /// (the private design note "PCIe-tunnelled USB attribution"); never user-facing,
    /// like switch UIDs.
    public let tunnelControllerRegistryPath: String?
    /// Registry entry IDs of the controller and every ancestor between it and
    /// the `apciecN` root, in walk order, starting with the controller's own
    /// entry ID. Used to verify a Thunderbolt switch's PCIe up-adapter
    /// `pciEntryID` actually lands on THIS chain (instance identity, not just
    /// a matching path string, which is a reusable topology address). Empty
    /// unless `tunnelCarrier != nil`. Internal only.
    public let tunnelAncestorEntryIDs: [UInt64]
    /// USB device base class (`bDeviceClass`). `0x11` is the Billboard Device
    /// Class. `nil` when the property is absent.
    public let deviceClass: UInt8?
    /// The IOKit class the device enumerates as (e.g. "IOUSBHostDevice", or
    /// "AppleUSBHostBillboardDevice" for a Billboard device). Read from
    /// `IOObjectGetClass`. `nil` when unavailable.
    public let ioClassName: String?
    /// Parsed Billboard Capability Descriptor (BOS `0x0d`), when the device
    /// publishes one: the Alt Modes it advertises and their per-mode state.
    /// `nil` when the device has no Billboard capability or the BOS read failed.
    public let billboard: BillboardCapability?
    /// `kUSBContainerID` exactly as macOS publishes it. A hub chip's USB2 and
    /// USB3 halves carry the same value, but one product can hold several
    /// chips with different IDs, and some chip makers reuse one ID across
    /// products. `nil` when the device publishes none.
    public let containerID: String?
    public let rawProperties: [String: String]

    public init(
        id: UInt64,
        locationID: UInt32,
        vendorID: UInt16,
        productID: UInt16,
        vendorName: String?,
        productName: String?,
        serialNumber: String?,
        usbVersion: String?,
        speedRaw: UInt8?,
        busPowerMA: Int?,
        currentMA: Int?,
        busIndex: Int? = nil,
        controllerPortName: String? = nil,
        isThunderboltTunnelled: Bool = false,
        isBehindInternalHub: Bool = false,
        tunnelBridgeDepth: Int? = nil,
        tunnelRootName: String? = nil,
        tunnelCarrier: TunnelCarrier? = nil,
        tunnelControllerRegistryPath: String? = nil,
        tunnelAncestorEntryIDs: [UInt64] = [],
        deviceClass: UInt8? = nil,
        ioClassName: String? = nil,
        billboard: BillboardCapability? = nil,
        containerID: String? = nil,
        rawProperties: [String: String]
    ) {
        self.id = id
        self.locationID = locationID
        self.vendorID = vendorID
        self.productID = productID
        self.vendorName = vendorName
        self.productName = productName
        self.serialNumber = serialNumber
        self.usbVersion = usbVersion
        self.speedRaw = speedRaw
        self.busPowerMA = busPowerMA
        self.currentMA = currentMA
        self.busIndex = busIndex
        self.controllerPortName = controllerPortName
        self.isThunderboltTunnelled = isThunderboltTunnelled
        self.isBehindInternalHub = isBehindInternalHub
        self.tunnelBridgeDepth = tunnelBridgeDepth
        self.tunnelRootName = tunnelRootName
        self.tunnelCarrier = tunnelCarrier
        self.tunnelControllerRegistryPath = tunnelControllerRegistryPath
        self.tunnelAncestorEntryIDs = tunnelAncestorEntryIDs
        self.deviceClass = deviceClass
        self.ioClassName = ioClassName
        self.billboard = billboard
        self.containerID = containerID
        self.rawProperties = rawProperties
    }

    /// A USB Billboard device. The USB-C spec uses one to report the Alternate
    /// Modes a device supports, and in particular to flag when an Alt Mode
    /// (such as DisplayPort) was advertised but isn't fully entered. Detected
    /// with three independent signals, any of which is sufficient:
    ///   - `bDeviceClass == 0x11` (the spec-defined Billboard Device Class),
    ///   - the IOKit class is Apple's Billboard device class, or
    ///   - the product name macOS assigns ("Generic Billboard Device").
    ///
    /// On signal quality: `bDeviceClass == 0x11` is the *primary* signal. It
    /// was confirmed across the customer-probe corpus (46 machines as of
    /// 2026-06, M1 through M5, macOS 15 and 26; see `corpus.jsonl` for the
    /// current count), and it catches real Billboard devices whose product
    /// names contain no hint of "Billboard" at all (Apple's "USB Type-C Digital
    /// AV Adapter", "Anker USB-C Hub Device", "Belkin USB HDMI", and similar).
    /// The IOKit class match is the second durable signal. The product-name
    /// string is kept only as a harmless last-resort fallback: it is fragile
    /// (a macOS-supplied label Apple can rename on any OS bump) and, as the
    /// corpus shows, it would miss many devices `0x11` catches, so it must not
    /// be treated as the real detector. It is not removed because the inverse
    /// (a device named "billboard" that does not report `0x11`) has not been
    /// ruled out.
    ///
    /// Naming a Billboard device is always safe; any *diagnosis* from its
    /// presence is gated separately in `DisplayDiagnostic`.
    /// A USB hub (`bDeviceClass == 0x09`).
    ///
    /// Hubs are the plumbing between the Mac and the things a user cares
    /// about. On a docked setup they dominate: 576 of 1222 devices across the
    /// probe-38 corpus are hubs, and a UGreen TB5 dock alone contributes eight,
    /// so a full tree buries the display and the Ethernet adapter among rows
    /// the user has no decision to make about.
    public var isHub: Bool { deviceClass == 0x09 }

    public var isBillboardDevice: Bool {
        if deviceClass == 0x11 { return true }
        if let cls = ioClassName, cls.localizedCaseInsensitiveContains("BillboardDevice") { return true }
        if let name = productName, name.localizedCaseInsensitiveContains("Billboard") { return true }
        return false
    }

    /// The Billboard device's product name when it adds information beyond the
    /// generic "Billboard device" label, else `nil`. Many Billboard endpoints
    /// report a name that is itself just a "billboard" variant ("Generic
    /// Billboard Device", "USB 2.0 BILLBOARD"), which tells the user nothing new,
    /// so callers fall back to the plain "Billboard device present" phrasing.
    /// Names like "Anker USB-C Hub Device" or "Belkin USB HDMI" do add
    /// information and are returned as-is.
    public var billboardInformativeName: String? {
        guard let name = productName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty,
              !name.localizedCaseInsensitiveContains("billboard") else { return nil }
        return name
    }

    /// Inline label for a Billboard device on a port: names it when the name
    /// adds information, else the generic presence phrase. Shared by the CLI
    /// (`TextFormatter`) and the menu-bar popover so their wording can't drift.
    /// Pass the caller's localized bundle (Core's vs the app's).
    public func billboardPresenceLabel(bundle: Bundle) -> String {
        if let name = billboardInformativeName {
            return String(localized: "Billboard device: \(name)", bundle: bundle)
        }
        return String(localized: "Billboard device present", bundle: bundle)
    }

    /// Vendor label for the detail view: the device-reported `USB Vendor Name`
    /// when present, else the bundled USB-IF database name for the VID, always
    /// suffixed with `0xVID:0xPID`. Falls back to bare hex when no name is
    /// known. Mirrors `VendorDB.label(for:)` so the vendor wording can't drift
    /// from the cable view, and adds the PID the per-device view wants.
    ///
    /// Only the two sentinel VIDs are excluded from the database fallback. For
    /// VID 0 and 0xFFFF, `VendorDB.name(for:)` returns explanatory sentences
    /// ("No vendor reported", "No vendor ID assigned …") written for the cable
    /// view, which would read here as a vendor literally called "No vendor
    /// reported".
    ///
    /// Deliberately not gated on `VendorDB.isRegistered`, which is narrower
    /// than this view wants: by its own definition it excludes community
    /// `usb.ids` entries, which resolve to perfectly good vendor names. The
    /// JSON `vendorName` field does use that stricter gate, because it is a
    /// machine-readable field where "present" should mean a real registration.
    /// Here the goal is to show the user the best name available.
    public var vendorDisplay: String {
        let ids = String(format: "0x%04X:0x%04X", vendorID, productID)
        let name = vendorName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty {
            return "\(name) (\(ids))"
        }
        if vendorID != 0, vendorID != 0xFFFF, let dbName = VendorDB.name(for: Int(vendorID)) {
            return "\(dbName) (\(ids))"
        }
        return ids
    }

    public var speedLabel: String {
        // IOUSBHostDevice "Device Speed" enum values
        switch speedRaw {
        case 0: return "Low Speed (1.5 Mbps)"
        case 1: return "Full Speed (12 Mbps)"
        case 2: return "High Speed (480 Mbps)"
        case 3: return "Super Speed (5 Gbps)"
        case 4: return "Super Speed+ (10 Gbps)"
        case 5: return "Super Speed+ Gen 2x2 (20 Gbps)"
        default: return "Unknown speed"
        }
    }

    /// The device name to show in trees and lists: the product name with the
    /// maker in parentheses when it adds information. The maker is skipped when
    /// the product name already names the brand, so a self-branded product like
    /// "UGREEN Dock" doesn't become "UGREEN Dock (UGREEN)". Falls back to a
    /// localized "Unknown" when there is no product name.
    ///
    /// This is the source of truth for the connected-device *tree row* labels:
    /// the CLI text output, the menu bar app's trees, and the dashboard list all
    /// call it, so those rows name devices identically. It exists because a stack
    /// of hub chips (a dock plus a daisy-chained display) otherwise renders as
    /// several identical, anonymous "USB2.0 Hub" rows; the maker disambiguates
    /// them. Surfaces that already show the maker on their own line (the Pro
    /// Diagnostics device list) keep `productName` + `vendorName` separate on
    /// purpose and are not routed through here.
    public var displayName: String {
        let product = productName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let product, !product.isEmpty else {
            return String(localized: "Unknown", bundle: _coreLocalizedBundle)
        }
        guard let maker = vendorName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !maker.isEmpty,
              !Self.productName(product, alreadyNames: maker)
        else { return product }
        return "\(product) (\(maker))"
    }

    /// Whether `product` already names `maker`'s brand, so appending the maker
    /// would be redundant. Matches on whole words, not raw substrings: the
    /// maker's brand token (its first word, e.g. "Apple" from "Apple Inc.",
    /// "VIA" from "VIA Labs, Inc.") must appear as a complete word in the
    /// product name. Whole-word matching avoids two failure modes a plain
    /// `contains` hits: hiding a short maker that happens to sit inside an
    /// unrelated product word ("LG" inside "Elgato"), and appending a redundant
    /// suffix when the brand is already present ("Apple Keyboard (Apple Inc.)").
    /// Words split on any non-alphanumeric character so punctuation in either
    /// string (the "," in "VIA Labs, Inc.", the "." in "USB2.0") is ignored.
    private static func productName(_ product: String, alreadyNames maker: String) -> Bool {
        let isBoundary: (Character) -> Bool = { !$0.isLetter && !$0.isNumber }
        guard let brand = maker.split(whereSeparator: isBoundary).first, brand.count >= 2
        else { return false }
        return product
            .split(whereSeparator: isBoundary)
            .contains { $0.compare(brand, options: .caseInsensitive) == .orderedSame }
    }

    /// Whether this device is directly attached to the host controller port
    /// (not behind a USB hub). LocationID bits 31-24 are the bus/controller
    /// index; bits 23-0 are hub-path nibbles (left-to-right, each nibble is
    /// one hop). A root device has exactly one non-zero nibble in the path.
    /// This encoding is an undocumented Apple convention, stable since at
    /// least Snow Leopard but not guaranteed by any public API.
    public var isRootDevice: Bool {
        let hubPath = locationID & 0x00FF_FFFF
        var nonZeroNibbles = 0
        for shift in stride(from: 0, to: 24, by: 4) {
            if (hubPath >> shift) & 0xF != 0 { nonZeroNibbles += 1 }
        }
        return nonZeroNibbles == 1
    }

    /// USB-IF style label for SuperSpeed and above, matching the format
    /// used by USB3Transport.speedLabel. Returns nil for USB 2.0 and below
    /// or when speedRaw is unavailable.
    public var usb3SpeedLabel: String? {
        switch speedRaw {
        case 3: return "USB 3.2 Gen 1 (5 Gbps)"
        case 4: return "USB 3.2 Gen 2 (10 Gbps)"
        case 5: return "USB 3.2 Gen 2x2 (20 Gbps)"
        default: return nil
        }
    }

    /// First directly-attached SuperSpeed device on this port (one non-zero
    /// locationID nibble, `speedRaw >= 3`). The conservative primary signal
    /// for labelling a USB-C port's negotiated link.
    public static func rootSuperSpeed(in devices: [USBDevice]) -> USBDevice? {
        devices.first { $0.isRootDevice && ($0.speedRaw ?? 0) >= 3 }
    }

    public static func parentLocationID(_ locID: UInt32) -> UInt32? {
        let hubPath = locID & 0x00FF_FFFF
        guard hubPath != 0 else { return nil }
        for shift in stride(from: 0, to: 24, by: 4) {
            if (hubPath >> shift) & 0xF != 0 {
                let cleared = locID & ~(UInt32(0xF) << shift)
                return (cleared & 0x00FF_FFFF) == 0 ? nil : cleared
            }
        }
        return nil
    }

    /// The hub port `child` sits on under `parent`, or `nil` when `child` is
    /// not directly (one hop) under `parent`. Same nibble-walk as
    /// `parentLocationID(_:)`: the nibble that walk clears to climb from
    /// `child` to its parent IS the hub port the child is plugged into, so
    /// this reuses the identical walk and additionally checks the climb
    /// actually lands on `parent`.
    ///
    /// Verified against a real capture
    /// (the private notes (tree-attribution, json-dock.json)): a UGreen TBT5
    /// dock's tunnel hub sits at locationID `0x03210000`, directly under a
    /// Studio Display's tunnel hub at `0x03200000`.
    /// `childHubPort(parent: 0x03200000, child: 0x03210000)` returns `1`,
    /// matching the route-string formula's independently-derived hub port
    /// for that same dock (the private design note "TB5 tunnel-hub attribution"
    /// section 2 point 3).
    public static func childHubPort(parent: UInt32, child: UInt32) -> Int? {
        let hubPath = child & 0x00FF_FFFF
        guard hubPath != 0 else { return nil }
        for shift in stride(from: 0, to: 24, by: 4) {
            let nibble = (hubPath >> shift) & 0xF
            guard nibble != 0 else { continue }
            let cleared = child & ~(UInt32(0xF) << shift)
            return cleared == parent ? Int(nibble) : nil
        }
        return nil
    }

    /// Highest-speed SuperSpeed device matched to this port by name
    /// (`controllerPortName`, sourced from IOKit's `UsbIOPort` mapping).
    /// Use only as a last-resort fallback when both `rootSuperSpeed(in:)`
    /// and the HPM transport label are unavailable: on Apple Silicon front
    /// USB-C ports the controller sits behind an internal virtual root
    /// that inflates locationID nibbles, so directly-attached devices fail
    /// `isRootDevice` even though their named port mapping is intact.
    ///
    /// Deliberately excludes devices that matched only by `busIndex`: those
    /// can include peripherals several hubs deep whose `Device Speed` could
    /// overstate the port's upstream link.
    public static func portMatchedSuperSpeed(in devices: [USBDevice]) -> USBDevice? {
        devices
            .filter { $0.controllerPortName != nil && ($0.speedRaw ?? 0) >= 3 }
            .max { ($0.speedRaw ?? 0) < ($1.speedRaw ?? 0) }
    }
}

// MARK: - Device tree

/// Equatable is a full value comparison, children included, not identity by
/// `id`. Two snapshots of the same IOKit entry can legitimately carry the same
/// entry ID with different contents (a device re-read after a change, or a
/// hand-built test fixture), and callers comparing nodes want to know the
/// contents differ, not just that the IDs match.
public struct USBDeviceNode: Identifiable, Equatable {
    public let device: USBDevice
    public let depth: Int
    public let children: [USBDeviceNode]

    public var id: UInt64 { device.id }

    public static func buildTree(from devices: [USBDevice]) -> [USBDeviceNode] {
        guard !devices.isEmpty else { return [] }

        let byLocation = Dictionary(
            devices.map { ($0.locationID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var childrenOf: [UInt32: [USBDevice]] = [:]
        var topLevel: [USBDevice] = []

        for device in devices {
            if device.locationID == 0 {
                topLevel.append(device)
                continue
            }
            if let parentLoc = USBDevice.parentLocationID(device.locationID),
               byLocation[parentLoc] != nil {
                childrenOf[parentLoc, default: []].append(device)
            } else {
                topLevel.append(device)
            }
        }

        func build(_ device: USBDevice, depth: Int) -> USBDeviceNode {
            let kids = (childrenOf[device.locationID] ?? [])
                .sorted { $0.locationID < $1.locationID }
                .map { build($0, depth: depth + 1) }
            return USBDeviceNode(device: device, depth: depth, children: kids)
        }

        return topLevel
            .sorted { $0.locationID < $1.locationID }
            .map { build($0, depth: 0) }
    }

    public static func flatten(_ nodes: [USBDeviceNode]) -> [USBDeviceNode] {
        var result: [USBDeviceNode] = []
        for node in nodes {
            result.append(node)
            result.append(contentsOf: flatten(node.children))
        }
        return result
    }

    /// One group of top-level devices sharing a USB controller.
    public struct BusGroup {
        /// Upper byte of the controller's `locationID`, e.g. `0x21`.
        public let bus: Int
        /// Top-level nodes on this controller, each with its hub children.
        public let roots: [USBDeviceNode]
    }

    /// Top-level nodes grouped by the USB controller they enumerate on, in
    /// first-seen order.
    ///
    /// A dock spreads its downstream devices across the several USB
    /// controllers inside it, and which devices share a bus is the difference
    /// between diagnosing a bandwidth problem and guessing at it.
    ///
    /// Returns `nil` when the devices span fewer than two buses, or when any
    /// device has no `busIndex`: callers render their plain tree then. A lone
    /// group header would add a level of indentation and no information, and a
    /// partial grouping would imply a device sits on a bus we could not read.
    ///
    /// The completeness check covers every device in the tree, not just the
    /// roots. A hub child with no readable bus index would otherwise render
    /// under its parent's header, silently claiming a controller assignment
    /// nothing established.
    ///
    /// Grouping itself is by top-level node, because everything behind a hub
    /// reaches the Mac through the same controller as the hub itself.
    public static func groupedByBus(from devices: [USBDevice]) -> [BusGroup]? {
        let tree = buildTree(from: devices)
        guard flatten(tree).allSatisfy({ $0.device.busIndex != nil }) else { return nil }

        var order: [Int] = []
        var byBus: [Int: [USBDeviceNode]] = [:]
        for root in tree {
            guard let bus = root.device.busIndex else { return nil }
            if byBus[bus] == nil { order.append(bus) }
            byBus[bus, default: []].append(root)
        }
        guard order.count > 1 else { return nil }
        return order.map { BusGroup(bus: $0, roots: byBus[$0] ?? []) }
    }

    /// "USB bus 0x21", the header shown above a `BusGroup`. The hex identifier
    /// is kept as-is: it is raw registry truth and the join key people use
    /// when comparing against `system_profiler` output.
    public static func busLabel(_ bus: Int) -> String {
        let word = String(localized: "USB bus", bundle: _coreLocalizedBundle)
        return "\(word) \(String(format: "0x%02X", bus))"
    }

    /// A flat list of (name, speed, depth) tuples for the device tree rooted
    /// at `devices`, ready for rendering. Depth 0 = top-level device;
    /// depth N > 0 = device behind N hubs. Mirrors the loop in TextFormatter
    /// so CLI and TUI show the same content without duplicating tree logic.
    public static func deviceRows(from devices: [USBDevice]) -> [(name: String, speed: String, depth: Int)] {
        flatten(buildTree(from: devices)).map { node in
            (name: node.device.displayName, speed: node.device.speedLabel, depth: node.depth)
        }
    }
}
