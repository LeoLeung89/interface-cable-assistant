import Foundation
import IOKit
import WhatCableCore

/// Watches `IOPortTransportComponentCCUSBPDSOP` (port partner) and
/// `IOPortTransportComponentCCUSBPDSOPp` (cable e-marker SOP') services.
/// macOS exposes these as separate IOKit classes, so we have to match both.
/// Some hardware also exposes SOP'' as a third class.
///
/// Issue #573 part 2: also watches `IOPortTransportStateCC`, the class that
/// carries a MagSafe 3 charge cable's chip VID/PID (`Vendor ID (SOP1)` /
/// `Product ID (SOP1)`). MagSafe never gets a `IOPortTransportComponentCC
/// USBPDSOPp` node at all (no VDO array exists for it to answer with), so
/// without this second source no MagSafe cable identity is ever produced.
/// StateCC is a DIFFERENT data source from the SOP-component classes above
/// (different ancestry, different keys, and -- critically -- the node
/// persists across plug/unplug instead of being added/removed each time),
/// so it gets its own dedicated matching, candidate/parse, and interest
/// machinery below, never the generic `parseIdentity` path. See
/// `research/thunderbolt-fabric.md`-style corpus notes in the #573 spec for
/// the measured split (`isStateCCMagSafeCandidate`/`parseStateCCIdentity`'s
/// doc comments carry the numbers).
@MainActor
public final class USBPDSOPWatcher: ObservableObject {
    /// Bumped on every change to the published state, from any path (apply,
    /// match/terminate handlers, drain, stop). The hub compares it before and
    /// after its background read so a stale read never overwrites newer state.
    public private(set) var refreshGeneration = 0
    @Published public private(set) var identities: [USBPDSOP] = [] {
        didSet { refreshGeneration &+= 1 }
    }

    /// One complete read: every identity to publish, and the entry IDs of
    /// the StateCC MagSafe candidates still in the registry, which the apply
    /// registers change alerts for and prunes against.
    public struct Reading: Sendable, Equatable {
        public let identities: [USBPDSOP]
        public let stateCCEntryIDs: Set<UInt64>
    }

    nonisolated private static let matchedClasses = [
        "IOPortTransportComponentCCUSBPDSOP",
        "IOPortTransportComponentCCUSBPDSOPp",
        "IOPortTransportComponentCCUSBPDSOPpp",
    ]

    /// Matched separately from `matchedClasses` above: it needs its own
    /// candidate/parse rules and interest-notification lifecycle, never the
    /// generic SOP-component handling.
    nonisolated private static let stateCCClassName = "IOPortTransportStateCC"

    private var notifyPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []

    /// StateCC interest-notification handles, keyed by registry entry ID so
    /// registration is idempotent across repeated candidate sightings (the
    /// same node is re-seen on every `refresh()`). Released in `stop()` and
    /// pruned whenever termination fires or a `refresh()` no longer finds
    /// the service, mirroring `AppleHPMInterfaceWatcher`'s pattern for its
    /// own per-port interest notifications.
    ///
    /// The bookkeeping (which entry IDs currently hold a handle, and which
    /// stop being live) is factored into `StateCCInterestBookkeeping` below,
    /// generic over the handle type, specifically so it can be tested with
    /// plain Swift values (design review, Codex required finding: the
    /// lifecycle tests exercised the identity reducer but not this
    /// bookkeeping, so removing a release call left every test green). The
    /// real `IOObjectRelease` call stays here, in production code only:
    /// a fabricated `io_object_t` is a Mach port name, and handing one to a
    /// real IOKit release call from a test is not something to fake.
    private var stateCCInterest = StateCCInterestBookkeeping<io_object_t>()

    /// Injected so the StateCC interest-handle cleanup wiring below (`stop()`,
    /// `pruneStateCCInterest(liveEntryIDs:)`, `removeStateCCEntry(entryID:)`)
    /// can be pinned by a test end to end, through the REAL call sites,
    /// without a live IOKit service. Defaults to the real `IOObjectRelease`
    /// call in production. `internal`, not `private`, exactly so a test can
    /// substitute a recording/no-op closure; a test must never seed a
    /// fabricated `io_object_t` and then leave this at its default, since
    /// handing a fabricated Mach port name to the real `IOObjectRelease` is
    /// not something to do from a test.
    ///
    /// Design review (round 6, Codex required finding): the earlier
    /// bookkeeping tests called `StateCCInterestBookkeeping` directly, which
    /// pinned the struct but left the WATCHER's wiring into it unpinned --
    /// deleting the `stop()` / refresh-prune / termination call sites below
    /// left every test green. This property, plus the two methods after it,
    /// are the seam that closes that.
    internal var releaseHandle: (io_object_t) -> Void = { IOObjectRelease($0) }

    /// Injected the same way as `releaseHandle` above, for the same reason:
    /// `handleStateCCRemoved(_:)`'s own call into `removeStateCCEntry(entryID:)`
    /// (design review round 7, required finding) was still unpinned even
    /// after `releaseHandle` and the factored-out methods, because nothing
    /// could drive `handleStateCCRemoved(_:)` itself without a real
    /// `io_iterator_t` from a genuine `kIOTerminatedNotification`. This is
    /// the drain step that currently wraps `wcDrainAllRetrying`/
    /// `IOIteratorNext`, factored out so a test can substitute one that
    /// ignores its `io_iterator_t` argument entirely and returns a seeded
    /// entry ID instead, letting `handleStateCCRemoved(_:)` run for real
    /// against a harmless placeholder iterator value (`0`) that is never
    /// touched. Defaults to the real drain in production.
    internal var drainStateCCTerminatedEntryIDs: (io_iterator_t) -> [UInt64?] = { iter in
        wcDrainAllRetrying(iter) { service -> UInt64? in
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { return nil }
            return entryID
        }
    }

    public init() {}

    public func start() {
        guard notifyPort == nil else { return }
        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        notifyPort = port

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let added: IOServiceMatchingCallback = { refcon, iter in
            guard let refcon else { return }
            let w = Unmanaged<USBPDSOPWatcher>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor [weak w] in w?.handleAdded(iter) }
        }
        let removed: IOServiceMatchingCallback = { refcon, iter in
            guard let refcon else { return }
            let w = Unmanaged<USBPDSOPWatcher>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor [weak w] in w?.handleRemoved(iter) }
        }

        for className in Self.matchedClasses {
            var addedIter: io_iterator_t = 0
            if IOServiceAddMatchingNotification(port, kIOMatchedNotification,
                IOServiceMatching(className),
                added, selfPtr, &addedIter) == KERN_SUCCESS {
                handleAdded(addedIter)
                iterators.append(addedIter)
            }

            var removedIter: io_iterator_t = 0
            if IOServiceAddMatchingNotification(port, kIOTerminatedNotification,
                IOServiceMatching(className),
                removed, selfPtr, &removedIter) == KERN_SUCCESS {
                handleRemoved(removedIter)
                iterators.append(removedIter)
            }
        }

        // StateCC: separate matching, separate handlers (`handleStateCC*`,
        // never `handleAdded`/`handleRemoved` above). The initial matched
        // iterator is drained immediately, same as every other class here,
        // which is what gets an ALREADY-INACTIVE MagSafe node subscribed for
        // interest at launch: candidacy (and therefore the interest
        // registration inside `handleStateCCAdded`) never depends on
        // `Active` or the SOP1 keys, only on the port type. Without this, a
        // Mac that starts up unplugged would never hear the later plug event
        // except through the 30 s idle poll.
        let addedStateCC: IOServiceMatchingCallback = { refcon, iter in
            guard let refcon else { return }
            let w = Unmanaged<USBPDSOPWatcher>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor [weak w] in w?.handleStateCCAdded(iter) }
        }
        let removedStateCC: IOServiceMatchingCallback = { refcon, iter in
            guard let refcon else { return }
            let w = Unmanaged<USBPDSOPWatcher>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor [weak w] in w?.handleStateCCRemoved(iter) }
        }

        var stateCCAddedIter: io_iterator_t = 0
        if IOServiceAddMatchingNotification(port, kIOMatchedNotification,
            IOServiceMatching(Self.stateCCClassName),
            addedStateCC, selfPtr, &stateCCAddedIter) == KERN_SUCCESS {
            handleStateCCAdded(stateCCAddedIter)
            iterators.append(stateCCAddedIter)
        }
        var stateCCRemovedIter: io_iterator_t = 0
        if IOServiceAddMatchingNotification(port, kIOTerminatedNotification,
            IOServiceMatching(Self.stateCCClassName),
            removedStateCC, selfPtr, &stateCCRemovedIter) == KERN_SUCCESS {
            handleStateCCRemoved(stateCCRemovedIter)
            iterators.append(stateCCRemovedIter)
        }
    }

    public func stop() {
        for iter in iterators where iter != 0 { IOObjectRelease(iter) }
        iterators.removeAll()
        releaseAllStateCCInterest()
        if let p = notifyPort { IONotificationPortDestroy(p); notifyPort = nil }
        identities.removeAll()
    }

    public func refresh() { apply(Self.readIdentities()) }

    public func apply(_ reading: Reading) {
        // Change alerts need a live service handle, which the background
        // read cannot hand over. Look one up only for a candidate not yet
        // registered, so the steady tick does no extra IOKit work.
        for entryID in reading.stateCCEntryIDs where stateCCInterest.shouldRegister(entryID: entryID) {
            guard let service = wcService(forEntryID: entryID) else { continue }
            registerStateCCInterest(for: service, entryID: entryID)
            IOObjectRelease(service)
        }
        // Prune interest handles for StateCC services no longer present.
        // Same pattern as `AppleHPMInterfaceWatcher.apply(_:)`'s own prune:
        // only kIOMatchedNotification/kIOTerminatedNotification are matching
        // notifications here, so without this, stale io_object_t handles
        // would accumulate without limit across plug/unplug cycles. A node
        // that is merely INACTIVE (still present, no current identity)
        // stays in `stateCCEntryIDs` and keeps its handle; only a node
        // genuinely gone from the registry is pruned here.
        pruneStateCCInterest(liveEntryIDs: reading.stateCCEntryIDs)

        if reading.identities != identities { identities = reading.identities }
    }

    /// The registry walk behind `refresh()`, with no notification
    /// registration and no published state, so it can run off the main
    /// thread.
    nonisolated public static func readIdentities() -> Reading {
        // Build locally and assign once so subscribers never see a transient
        // empty list mid-refresh. See issue #227.
        var rebuilt: [USBPDSOP] = []
        for className in matchedClasses {
            var iter: io_iterator_t = 0
            if IOServiceGetMatchingServices(kIOMainPortDefault,
                IOServiceMatching(className), &iter) == KERN_SUCCESS {
                defer { IOObjectRelease(iter) }
                let found = wcDrainAllRetrying(iter) { service in makeIdentity(from: service) }
                for identity in found {
                    guard let identity, !rebuilt.contains(where: { $0.id == identity.id }) else { continue }
                    rebuilt.append(identity)
                }
            }
        }

        // StateCC: this is the backstop for the interest-notification path
        // (issue #573 design review: "refresh() remains the backstop"), and
        // also where a candidate found only here (e.g. the very first
        // refresh, before any interest notification has fired even once)
        // still gets registered, idempotently (by the apply, from
        // `stateCCEntryIDs`). `readStateCCService`
        // returns nil for a non-candidate (USB-C StateCC), so those never
        // touch `liveStateCCEntryIDs`, never get an interest registration,
        // and never contribute an identity.
        var liveStateCCEntryIDs: Set<UInt64> = []
        var stateCCIter: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault,
            IOServiceMatching(Self.stateCCClassName), &stateCCIter) == KERN_SUCCESS {
            defer { IOObjectRelease(stateCCIter) }
            let found = wcDrainAllRetrying(stateCCIter) { service in readStateCCService(service) }
            for result in found {
                guard let (entryID, identity) = result else { continue }
                liveStateCCEntryIDs.insert(entryID)
                guard let identity, !rebuilt.contains(where: { $0.id == identity.id }) else { continue }
                rebuilt.append(identity)
            }
        }
        return Reading(identities: rebuilt, stateCCEntryIDs: liveStateCCEntryIDs)
    }

    private func handleAdded(_ iter: io_iterator_t) {
        let found = wcDrainAllRetrying(iter) { service in Self.makeIdentity(from: service) }
        for identity in found {
            guard let identity, !identities.contains(where: { $0.id == identity.id }) else { continue }
            identities.append(identity)
        }
    }

    private func handleRemoved(_ iter: io_iterator_t) {
        let removedEntryIDs = wcDrainAllRetrying(iter) { service -> UInt64? in
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { return nil }
            return entryID
        }
        for entryID in removedEntryIDs {
            guard let entryID else { continue }
            identities.removeAll { $0.id == entryID }
        }
    }

    // MARK: - StateCC (MagSafe cable identity)

    /// Drains the initial (or a future) StateCC matched-notification
    /// iterator: for every candidate, registers interest (regardless of
    /// whether it currently emits) and folds any produced identity into
    /// `identities` through the pure reducer, so a repeated sighting of the
    /// same node never duplicates and a changed identity replaces rather
    /// than appends.
    private func handleStateCCAdded(_ iter: io_iterator_t) {
        let found = wcDrainAllRetrying(iter) { service -> (entryID: UInt64, identity: USBPDSOP?)? in
            guard let result = Self.readStateCCService(service) else { return nil }
            // Registered here, with the service this drain already holds, so
            // an already-inactive candidate is subscribed at launch.
            registerStateCCInterest(for: service, entryID: result.entryID)
            return result
        }
        for result in found {
            guard let (entryID, identity) = result else { continue }
            identities = Self.reduceStateCCIdentities(identities, entryID: entryID, identity: identity)
        }
    }

    /// Drains a StateCC terminated-notification iterator (via the injected
    /// `drainStateCCTerminatedEntryIDs`, the real IOKit walk in production):
    /// removes any identity for the terminated node and releases its
    /// interest handle. The node is documented to persist across ordinary
    /// plug/unplug (see the type doc comment), so this fires rarely if ever
    /// in practice, but stays correct (and keeps `stop()`'s release list
    /// accurate) if a future macOS ever does tear the node down, e.g. across
    /// a driver reload. `internal`, not `private`, so a test can call it
    /// directly with a harmless placeholder iterator value once
    /// `drainStateCCTerminatedEntryIDs` has been substituted (see that
    /// property's doc comment).
    internal func handleStateCCRemoved(_ iter: io_iterator_t) {
        let removedEntryIDs = drainStateCCTerminatedEntryIDs(iter)
        for entryID in removedEntryIDs {
            guard let entryID else { continue }
            removeStateCCEntry(entryID: entryID)
        }
    }

    /// The release step of the refresh-prune path: releases (and
    /// un-registers) every StateCC interest handle whose entry ID is not in
    /// `liveEntryIDs`. Factored out of `refresh()` (design review round 6)
    /// so a test can drive the SAME code `refresh()` calls with a fabricated
    /// live-entry-ID set, rather than depending on whatever real StateCC
    /// hardware happens to be attached to the machine running the test.
    internal func pruneStateCCInterest(liveEntryIDs: Set<UInt64>) {
        for (_, n) in stateCCInterest.pruneStale(live: liveEntryIDs) {
            releaseHandle(n)
        }
    }

    /// Removes the identity for one entry ID (if any) and releases its
    /// StateCC interest handle (if any). This is the shared removal+release
    /// step `handleStateCCRemoved(_:)` calls for each entry ID a real
    /// termination notification drains; factored out (design review round
    /// 6) so a test can drive the SAME code with a fabricated entry ID,
    /// without a real `io_iterator_t`.
    internal func removeStateCCEntry(entryID: UInt64) {
        identities = Self.reduceStateCCIdentities(identities, entryID: entryID, identity: nil)
        if let n = stateCCInterest.remove(entryID: entryID) {
            releaseHandle(n)
        }
    }

    /// Releases every held StateCC interest handle and empties the map.
    /// The StateCC-specific half of `stop()`, factored out (design review
    /// round 6) for the same reason as the two methods above: a test seeds
    /// fake handles via `stateCCInterest`, then calls the REAL `stop()`
    /// (safe to call directly: with no real IOKit session ever started,
    /// `iterators` is empty and `notifyPort` is nil, so nothing else in
    /// `stop()` touches real IOKit either), and observes them released
    /// through the injected `releaseHandle`.
    private func releaseAllStateCCInterest() {
        for (_, n) in stateCCInterest.removeAll() {
            releaseHandle(n)
        }
    }

    /// Test seam (design review round 6): registers a StateCC interest
    /// handle directly, without a real IOKit service, so
    /// `stop()`/`pruneStateCCInterest(liveEntryIDs:)`/
    /// `removeStateCCEntry(entryID:)` can be exercised end to end from a
    /// test. Production never calls this; `registerStateCCInterest(for:
    /// entryID:)` (a real `io_service_t` plus a real `IOServiceAdd
    /// InterestNotification` call) is production's only writer.
    internal func seedStateCCInterest(entryID: UInt64, handle: io_object_t) {
        stateCCInterest.register(entryID: entryID, handle: handle)
    }

    /// Test seam: the current StateCC interest-handle map, for assertions.
    internal var stateCCInterestHandles: [UInt64: io_object_t] {
        stateCCInterest.handles
    }

    /// One StateCC service, read once: for a MagSafe candidate (whatever its
    /// current `Active`/SOP1-key state), returns its entry ID plus whatever
    /// identity it currently emits (nil when it doesn't). Returns nil
    /// outright for a non-candidate (USB-C StateCC), so callers never
    /// register interest for one and never treat it as live StateCC state.
    /// Registers nothing itself: the caller registers interest for the
    /// returned entry ID.
    nonisolated private static func readStateCCService(_ service: io_service_t) -> (entryID: UInt64, identity: USBPDSOP?)? {
        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { return nil }

        // Same per-key read rationale as `makeIdentity(from:)` above: a bulk
        // property fetch can abort the process mid-teardown. See issue #181.
        func read(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }

        guard Self.isStateCCMagSafeCandidate(read: read) else { return nil }

        let uuid = wcHPMControllerUUID(for: service)
        let identity = Self.parseStateCCIdentity(entryID: entryID, read: read, hpmControllerUUID: uuid)
        return (entryID, identity)
    }

    /// Subscribes to property-change notifications on a StateCC candidate.
    /// The node persists across plug/unplug (add/terminate notifications
    /// never fire for a state change on it), so this is the only timely
    /// signal a cable was plugged or removed; `refresh()` is the backstop.
    /// Idempotent by registry entry ID, same pattern as
    /// `AppleHPMInterfaceWatcher.registerInterest(for:entryID:)`. The
    /// callback discards the service/message arguments and triggers a full
    /// `refresh()`, matching every other interest callback in this codebase
    /// (`AppleHPMInterfaceWatcher`, `IOThunderboltSwitchWatcher`,
    /// `AppleTypeCPhyWatcher`, `PortDiagnosticsWatcher`): the raw `io_service_t`
    /// IOKit hands the callback is only valid for the callback's own
    /// duration, not across the async `Task` hop to the main actor, so
    /// re-deriving state from a fresh registry walk is the safe option, not
    /// a shortcut.
    private func registerStateCCInterest(for service: io_service_t, entryID: UInt64) {
        guard let notifyPort, stateCCInterest.shouldRegister(entryID: entryID) else { return }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let cb: IOServiceInterestCallback = { refcon, _, _, _ in
            guard let refcon else { return }
            let w = Unmanaged<USBPDSOPWatcher>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor [weak w] in w?.refresh() }
        }
        var notification: io_object_t = 0
        let result = IOServiceAddInterestNotification(
            notifyPort,
            service,
            kIOGeneralInterest,
            cb,
            selfPtr,
            &notification
        )
        if result == KERN_SUCCESS {
            stateCCInterest.register(entryID: entryID, handle: notification)
        }
    }

    nonisolated private static func makeIdentity(from service: io_service_t) -> USBPDSOP? {
        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { return nil }

        // Read keys individually rather than fetching the full property
        // dictionary. The bulk fetch (IORegistryEntryCreateCFProperties)
        // can abort the process from inside IOCFUnserializeBinary when
        // the kernel returns a malformed serialised properties blob,
        // typically when the service is being torn down mid-read. The
        // per-key call has no such failure path. See issue #181.
        func read(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }

        var classNameBuf = [CChar](repeating: 0, count: 128)
        let className: String? = (IOObjectGetClass(service, &classNameBuf) == KERN_SUCCESS)
            ? String(cString: classNameBuf)
            : nil

        // Walk the parent chain to capture the HPM controller UUID.
        // SOP/SOP' nodes sit at Port-USB-C@N/CC/SOP, so the controller is
        // ~3-4 steps up (CC -> AppleHPMInterfaceType10 -> AppleHPMDeviceHALType3).
        let uuid = wcHPMControllerUUID(for: service)

        return Self.parseIdentity(
            entryID: entryID,
            read: read,
            className: className,
            hpmControllerUUID: uuid
        )
    }

    /// Parse a `USBPDSOP` from a property-read closure plus metadata that the
    /// IOKit wrapper already resolved. Extracted from `makeIdentity(from:)` so
    /// corpus-replay tests can drive the parse logic without real IOKit services.
    internal nonisolated static func parseIdentity(
        entryID: UInt64,
        read: (String) -> Any?,
        className: String?,
        hpmControllerUUID: String?
    ) -> USBPDSOP? {
        let endpoint = Self.endpoint(read: read, className: className)
        let parent = Self.parentPortIdentity(read: read)
        let specRev = (read("Specification Revision") as? NSNumber)?.intValue ?? 0

        let metadata = Self.metadataDictionary(read: read)
        let vendorID = Self.vendorID(read: read, metadata: metadata)
        let productID = Self.productID(read: read, metadata: metadata)
        let bcdDevice = Self.bcdDevice(from: metadata)

        let vdos: [UInt32] = ((metadata["VDOs"] as? [Any]) ?? []).compactMap { value in
            guard let data = value as? Data else { return nil }
            return PDVDO.vdoFromData(data)
        }

        return USBPDSOP(
            id: entryID,
            endpoint: endpoint,
            parentPortType: parent.type,
            parentPortNumber: parent.number,
            vendorID: vendorID,
            productID: productID,
            bcdDevice: bcdDevice,
            vdos: vdos,
            specRevision: specRev,
            hpmControllerUUID: hpmControllerUUID
        )
    }

    // MARK: - StateCC candidate/parse (issue #573 part 2)
    //
    // Deliberately separate from `parseIdentity` above rather than folded
    // into it: StateCC is structurally a different node (different class,
    // different keys, no VDOs ever), and the two-stage candidate/emit rule
    // below has no equivalent in the SOP-component path. Corpus facts
    // (2026-08-31 sweep, 1325 probe-01 files, independently re-derived
    // twice, see the #573 spec's "Measured corpus facts"): MagSafe
    // (`ParentPortType == 17`) `IOPortTransportStateCC` blocks split
    // `Active == false` (616, never carries the SOP1 keys), `Active ==
    // true` with both SOP1 keys (266, every one read VID 0x05AC / PID
    // 0x7800 at that time -- a dated observation, not an invariant this
    // code enforces), and `Active == true` without the keys (1, an
    // outlier). USB-C StateCC blocks (3342 in the same sweep) never
    // candidate and never emit.

    /// Candidate test: does this StateCC node belong to a MagSafe port,
    /// independent of whether it currently emits an identity? This is
    /// deliberately loose (ignores `Active` and the SOP1 keys entirely) --
    /// it is the interest-subscription gate, not the emission gate below,
    /// and an inactive MagSafe node at app launch MUST still subscribe or
    /// the eventual plug is only caught by the idle refresh cadence. Reuses
    /// `parentPortIdentity(read:)`'s BuiltIn-prioritized parent-type read,
    /// the same rule the SOP-component path uses, so the two never
    /// disagree about which port a node belongs to.
    internal nonisolated static func isStateCCMagSafeCandidate(read: (String) -> Any?) -> Bool {
        Self.parentPortIdentity(read: read).type == PortIdentity.magSafeTypeCode
    }

    /// Parses a StateCC node into a `USBPDSOP` cable identity, or nil when
    /// it doesn't currently emit one. Emission requires: a MagSafe
    /// candidate (see above), `Active == true` (defends against any future
    /// or stale SOP1-key retention after unplug; matches every observed
    /// accepted corpus case), and both `Vendor ID (SOP1)` / `Product ID
    /// (SOP1)` present as a PARSEABLE NUMERIC value -- zero allowed, since
    /// the fingerprint's `hasUniqueModelID` is the single judge of
    /// trackability, not this parser. Reads the two SOP1 keys DIRECTLY,
    /// never the generic metadata-first `vendorID(read:metadata:)` /
    /// `productID(read:metadata:)` precedence above, which could pick up an
    /// unrelated field if StateCC's own metadata shape ever changes.
    /// `endpoint` is forced to `.sopPrime` and `vdos` to `[]` explicitly:
    /// MagSafe never publishes a VDO array, and letting the generic
    /// `endpoint(read:className:)` / metadata parsing decide either one
    /// (the old "TransportTypeDescription == CC" mapping in that function)
    /// is exactly the dead-code mechanism this fix replaces, not extends.
    internal nonisolated static func parseStateCCIdentity(
        entryID: UInt64,
        read: (String) -> Any?,
        hpmControllerUUID: String?
    ) -> USBPDSOP? {
        guard Self.isStateCCMagSafeCandidate(read: read) else { return nil }
        guard (read("Active") as? NSNumber)?.boolValue == true else { return nil }
        guard let vendorID = (read("Vendor ID (SOP1)") as? NSNumber)?.intValue,
              let productID = (read("Product ID (SOP1)") as? NSNumber)?.intValue
        else { return nil }

        let parent = Self.parentPortIdentity(read: read)
        // specRevision / bcdDevice default 0 UNLESS the node provides them
        // (design review, Low): the corpus never shows StateCC publishing
        // either, so 0 is what every real read gets today, but read them
        // with the SAME key names/precedence the generic `parseIdentity`
        // path uses above, rather than hardcoding, in case a future macOS
        // ever does populate them here.
        let specRev = (read("Specification Revision") as? NSNumber)?.intValue ?? 0
        let metadata = Self.metadataDictionary(read: read)
        let bcdDevice = Self.bcdDevice(from: metadata)
        return USBPDSOP(
            id: entryID,
            endpoint: .sopPrime,
            parentPortType: parent.type,
            parentPortNumber: parent.number,
            vendorID: vendorID,
            productID: productID,
            bcdDevice: bcdDevice,
            vdos: [],
            specRevision: specRev,
            hpmControllerUUID: hpmControllerUUID
        )
    }

    /// Pure lifecycle reducer over the persistent StateCC node problem: the
    /// node itself is never added or removed on plug/unplug (see the type
    /// doc comment), only its properties change, so every StateCC-driven
    /// update -- initial sighting, plug, unplug, a changed VID/PID, a
    /// repeated interest callback that changed nothing -- goes through this
    /// one "remove this entry ID's old identity, then insert the new one
    /// if there is one" rule. That single rule is what makes all four
    /// lifecycle behaviours (appear, disappear, no duplicate on repeat,
    /// replace not append on change) fall out of the same code path rather
    /// than needing a separate special case each. Testable with plain
    /// `[USBPDSOP]` fixtures, no IOKit.
    internal nonisolated static func reduceStateCCIdentities(
        _ current: [USBPDSOP],
        entryID: UInt64,
        identity: USBPDSOP?
    ) -> [USBPDSOP] {
        var result = current.filter { $0.id != entryID }
        if let identity {
            result.append(identity)
        }
        return result
    }

    nonisolated static func endpointName(read: (String) -> Any?) -> String {
        (read("ComponentName") as? String)
            ?? (read("AddressDescription") as? String)
            ?? (read("Address Description") as? String)
            ?? (read("TransportTypeDescription") as? String)
            ?? "Unknown"
    }

    nonisolated static func endpoint(read: (String) -> Any?, className: String? = nil) -> USBPDSOP.Endpoint {
        if let name = (read("ComponentName") as? String)
            ?? (read("AddressDescription") as? String)
            ?? (read("Address Description") as? String) {
            return USBPDSOP.Endpoint(rawValue: name) ?? .unknown
        }
        // The IOKit class name is the most reliable signal: macOS exposes
        // SOP' as a separate `IOPortTransportComponentCCUSBPDSOPp` class
        // (and SOP'' as `...SOPpp`), even when ComponentName is absent.
        switch className {
        case "IOPortTransportComponentCCUSBPDSOP": return .sop
        case "IOPortTransportComponentCCUSBPDSOPp": return .sopPrime
        case "IOPortTransportComponentCCUSBPDSOPpp": return .sopDoublePrime
        default: break
        }
        // MagSafe CC transport has no ComponentName; map "CC" only from
        // TransportTypeDescription so a future node with ComponentName="CC"
        // is not misclassified as a cable e-marker.
        switch read("TransportTypeDescription") as? String {
        case "SOP": return .sop
        case "SOP'", "CC": return .sopPrime
        case "SOP''": return .sopDoublePrime
        default: return .unknown
        }
    }

    /// Reads the parent port type and number from the service's properties.
    /// Same approach as `PowerSourceWatcher.parentPortIdentity(read:)`. The
    /// BuiltIn keys must take priority so PD identity and power data resolve
    /// to the same portKey for a given physical port.
    nonisolated static func parentPortIdentity(read: (String) -> Any?) -> (type: Int, number: Int) {
        let type = (read("ParentBuiltInPortType") as? NSNumber)?.intValue
            ?? (read("ParentPortType") as? NSNumber)?.intValue
            ?? 0
        let number = (read("ParentBuiltInPortNumber") as? NSNumber)?.intValue
            ?? (read("ParentPortNumber") as? NSNumber)?.intValue
            ?? Int(((read("Priority") as? NSNumber)?.uint64Value ?? 0) & 0xFF)
        return (type, number)
    }

    nonisolated static func metadataDictionary(read: (String) -> Any?) -> [String: Any] {
        let raw = read("Metadata")
        if let metadata = raw as? [String: Any] {
            return metadata
        }
        if let nsMetadata = raw as? NSDictionary {
            var converted: [String: Any] = [:]
            for case let (key, value) as (String, Any) in nsMetadata {
                converted[key] = value
            }
            return converted
        }
        return [:]
    }

    nonisolated static func vendorID(read: (String) -> Any?, metadata: [String: Any]) -> Int {
        (metadata["Vendor ID"] as? NSNumber)?.intValue
            ?? (metadata["Vendor ID (SOP1)"] as? NSNumber)?.intValue
            ?? (read("Vendor ID (SOP1)") as? NSNumber)?.intValue
            ?? (read("Vendor ID") as? NSNumber)?.intValue
            ?? 0
    }

    nonisolated static func productID(read: (String) -> Any?, metadata: [String: Any]) -> Int {
        (metadata["Product ID"] as? NSNumber)?.intValue
            ?? (metadata["Product ID (SOP1)"] as? NSNumber)?.intValue
            ?? (read("Product ID (SOP1)") as? NSNumber)?.intValue
            ?? (read("Product ID") as? NSNumber)?.intValue
            ?? 0
    }

    nonisolated static func bcdDevice(from metadata: [String: Any]) -> Int {
        (metadata["bcdDevice"] as? NSNumber)?.intValue ?? 0
    }

    public func identities(for port: AppleHPMInterface) -> [USBPDSOP] {
        identities.filter { $0.canonicallyMatches(port: port) }
    }
}

/// The StateCC interest-handle bookkeeping (issue #573 part 2), factored out
/// as a plain generic type so its four decisions -- register only when
/// nothing is already held for this entry ID, remove one entry's handle,
/// remove every entry no longer in a "live" set, remove everything -- are
/// testable with plain Swift values (an `Int` or `String` handle in tests),
/// never a real IOKit `io_object_t`. `USBPDSOPWatcher` is the only caller
/// that ever hands it a real one; the actual `IOObjectRelease(_:)` call on
/// whatever this returns stays in the watcher, production code only.
///
/// Design review (Codex required finding): the lifecycle tests before this
/// exercised `reduceStateCCIdentities` (the identity list) but nothing
/// verified the handle map itself shrank on `stop()`/prune/termination or
/// stayed flat on a repeated registration, so deleting an `IOObjectRelease`
/// call or a map mutation left every existing test green. This type is
/// the seam that closes that gap.
internal struct StateCCInterestBookkeeping<Handle> {
    private(set) var handles: [UInt64: Handle] = [:]

    /// The idempotency gate: only `true` when nothing is already held for
    /// this entry ID. A caller must check this BEFORE doing whatever
    /// produces a new handle (a real `IOServiceAddInterestNotification`
    /// call in production), not after, so a duplicate sighting of the same
    /// candidate never triggers a second real registration.
    func shouldRegister(entryID: UInt64) -> Bool {
        handles[entryID] == nil
    }

    /// Records a handle for an entry ID. Idempotent by construction (a
    /// dictionary assignment), but callers are expected to have already
    /// checked `shouldRegister(entryID:)` first; this alone doesn't grow the
    /// map on a repeat call either way.
    mutating func register(entryID: UInt64, handle: Handle) {
        handles[entryID] = handle
    }

    /// Removes and returns the handle for one entry ID (the termination
    /// path), or nil when nothing was held for it.
    @discardableResult
    mutating func remove(entryID: UInt64) -> Handle? {
        handles.removeValue(forKey: entryID)
    }

    /// Removes and returns every handle whose entry ID is NOT in `live`
    /// (the refresh-prune path: a service genuinely gone from the
    /// registry, as opposed to merely inactive, which stays in `live`).
    mutating func pruneStale(live: Set<UInt64>) -> [UInt64: Handle] {
        let staleIDs = Set(handles.keys).subtracting(live)
        var removed: [UInt64: Handle] = [:]
        for id in staleIDs {
            removed[id] = handles.removeValue(forKey: id)
        }
        return removed
    }

    /// Removes and returns every handle (the `stop()` path).
    mutating func removeAll() -> [UInt64: Handle] {
        let all = handles
        handles.removeAll()
        return all
    }
}

