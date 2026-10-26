import Foundation
import IOKit

public func wcInt(_ value: Any?) -> Int {
    if let n = value as? NSNumber { return n.intValue }
    if let i = value as? Int { return i }
    if let s = value as? String, let i = Int(s) { return i }
    return 0
}

public func wcUInt32(_ value: Any?) -> UInt32 {
    if let n = value as? NSNumber { return UInt32(truncatingIfNeeded: n.int64Value) }
    if let i = value as? Int { return UInt32(truncatingIfNeeded: i) }
    if let u = value as? UInt32 { return u }
    return 0
}

public func wcUInt8(_ value: Any?) -> UInt8 {
    UInt8(truncatingIfNeeded: wcInt(value))
}

public func wcBool(_ value: Any?) -> Bool {
    if let n = value as? NSNumber { return n.boolValue }
    if let b = value as? Bool { return b }
    return false
}

public func wcDictionary(_ value: Any?) -> [String: Any] {
    if let dict = value as? [String: Any] { return dict }
    if let nsDict = value as? NSDictionary {
        var converted: [String: Any] = [:]
        for case let (key, val) as (String, Any) in nsDict {
            converted[key] = val
        }
        return converted
    }
    return [:]
}

public func wcArray(_ value: Any?) -> [Any] {
    if let array = value as? [Any] { return array }
    if let nsArray = value as? NSArray { return nsArray.map { $0 } }
    return []
}

public func wcData(_ value: Any?) -> Data? {
    value as? Data
}

/// Drains an IOKit iterator into an array, retrying the whole pass from the
/// start when the iterator was invalidated partway through the walk (the
/// registry changed under us mid-read, e.g. a cable was unplugged while we
/// were iterating).
///
/// `IOIteratorIsValid` returning false is ambiguous on its own: Apple
/// documents it as "the iterator is no longer valid", but it is also what a
/// perfectly normal empty match reports (measured directly on macOS 26 by
/// `probes/test-kit/42_typec_phy_subtree.c`: an iterator that matched
/// nothing at all reports invalid too). So invalidity is only treated as a
/// signal worth retrying on when this pass actually produced at least one
/// item; `sawAny` is what tells the two cases apart.
///
/// On a retry, `IOIteratorReset` rewinds the iterator back to the start of
/// its list, so anything this pass already collected would be seen again
/// and double counted if it were kept. The whole pass's results are
/// discarded and the walk restarts from scratch. `transform` is called once
/// per item and the item is released immediately afterwards, whether or not
/// this pass ends up being the one that gets kept, so a discarded pass never
/// leaks the objects it obtained.
///
/// Retries are capped at `maxAttempts` (default 3, i.e. up to 2 resets).
/// After the final attempt this returns whatever that attempt collected
/// even if the iterator is still reporting invalid: an occasionally
/// incomplete result is acceptable here, an unbounded retry loop is not.
///
/// `onTerminalInvalidation` fires at most once, only when the very last
/// attempt still saw the iterator invalidated mid-walk (i.e. the same
/// condition that would otherwise trigger one more retry, but the retry
/// budget is spent). It is a no-op by default so the 30+ existing call
/// sites that only want the collected array are unaffected. For a
/// notification-backed iterator (one obtained from
/// `IOServiceAddMatchingNotification`), this is the caller's only signal
/// that the notification may not have been fully re-armed for future
/// deliveries; see `wcDrainIterator`'s doc comment for what "may" means
/// here.
public func wcDrainAllRetrying<T>(
    _ iterator: io_iterator_t,
    maxAttempts: Int = 3,
    transform: (io_service_t) -> T,
    onTerminalInvalidation: () -> Void = {}
) -> [T] {
    var attempt = 0
    while true {
        attempt += 1
        var results: [T] = []
        var sawAny = false
        var next = IOIteratorNext(iterator)
        while next != 0 {
            sawAny = true
            results.append(transform(next))
            IOObjectRelease(next)
            next = IOIteratorNext(iterator)
        }
        let invalidatedMidWalk = sawAny && IOIteratorIsValid(iterator) == 0
        if !invalidatedMidWalk {
            return results
        }
        if attempt >= maxAttempts {
            onTerminalInvalidation()
            return results
        }
        // Discard `results`. IOIteratorReset rewinds to the start of the
        // list, so anything already collected in this pass would be seen
        // again, and double counted, once the re-walk reaches it a second
        // time.
        IOIteratorReset(iterator)
    }
}

/// Drains an IOKit iterator with no per-item work beyond releasing each
/// object, retrying on the same policy as `wcDrainAllRetrying`.
///
/// This is the shape needed to consume (and thereby re-arm) an
/// `IOServiceAddMatchingNotification` iterator where the items themselves
/// carry no useful data for the caller, just released and discarded. See
/// `wcDrainAllRetrying`'s doc comment for the retry policy and why it is
/// safe against both meanings of an invalid iterator.
///
/// Returns `true` when the drain completed with the iterator in a valid
/// state (the ordinary case: either it matched nothing at all, or it
/// matched everything and the final `IOIteratorNext` cleanly returned 0).
/// Returns `false` only when the iterator saw at least one item and was
/// still reporting invalid after every retry was exhausted -- the case
/// where the caller cannot assume future notifications on this iterator
/// will keep arriving. (Before this fix the polarity was inverted --
/// `true` meant "still invalid" -- and every call site discarded the
/// result regardless, so a terminal invalidation was never noticed
/// anywhere. `@discardableResult` stays because most call sites still have
/// nothing useful to do with it directly; the ones that do now check it
/// explicitly. See `research/iokit-data-sources.md` for the background on
/// why `IOIteratorIsValid` needs this treatment at all.)
@discardableResult
public func wcDrainIterator(_ iterator: io_iterator_t, maxAttempts: Int = 3) -> Bool {
    var completedCleanly = true
    _ = wcDrainAllRetrying(iterator, maxAttempts: maxAttempts, transform: { _ in true }) {
        completedCleanly = false
    }
    return completedCleanly
}

public func wcRegistryEntryID(_ service: io_service_t) -> UInt64 {
    var entryID: UInt64 = 0
    IORegistryEntryGetRegistryEntryID(service, &entryID)
    return entryID
}

public func wcPortIndex(from dict: [String: Any], service: io_service_t? = nil) -> Int {
    if let n = dict["PortIndex"].map(wcInt), n != 0 { return n }
    if let n = dict["ParentPortNumber"].map(wcInt), n != 0 { return n }
    if let n = dict["ParentBuiltInPortNumber"].map(wcInt), n != 0 { return n }
    if let n = dict["PortNumber"].map(wcInt), n != 0 { return n }
    guard let service else { return 0 }
    var locBuf = [CChar](repeating: 0, count: 128)
    if IORegistryEntryGetLocationInPlane(service, kIOServicePlane, &locBuf) == KERN_SUCCESS,
       let n = Int(String(cString: locBuf), radix: 16) {
        return n
    }
    return 0
}

public func wcPortIndex(read: (String) -> Any?, service: io_service_t? = nil) -> Int {
    for key in ["PortIndex", "ParentPortNumber", "ParentBuiltInPortNumber", "PortNumber"] {
        let n = wcInt(read(key)); if n != 0 { return n }
    }
    guard let service else { return 0 }
    var locBuf = [CChar](repeating: 0, count: 128)
    if IORegistryEntryGetLocationInPlane(service, kIOServicePlane, &locBuf) == KERN_SUCCESS,
       let n = Int(String(cString: locBuf), radix: 16) {
        return n
    }
    return 0
}

public func wcPortType(from dict: [String: Any], service: io_service_t? = nil) -> String {
    if let type = dict["PortTypeDescription"] as? String { return type }
    guard let service else { return "USB-C" }

    var current = service
    IOObjectRetain(current)
    defer { IOObjectRelease(current) }
    for _ in 0..<5 {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
            break
        }
        IOObjectRelease(current)
        current = parent

        // Read the single key individually rather than bulk-fetching all
        // properties. The bulk fetch can abort inside IOCFUnserializeBinary
        // when the kernel returns a malformed blob mid-teardown. See #181.
        if let type = IORegistryEntryCreateCFProperty(current, "PortTypeDescription" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
            return type
        }
    }
    return "USB-C"
}

public func wcPortType(read: (String) -> Any?, service: io_service_t? = nil) -> String {
    if let type = read("PortTypeDescription") as? String { return type }
    guard let service else { return "USB-C" }

    var current = service
    IOObjectRetain(current)
    defer { IOObjectRelease(current) }
    for _ in 0..<5 {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
            break
        }
        IOObjectRelease(current)
        current = parent

        if let type = IORegistryEntryCreateCFProperty(current, "PortTypeDescription" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
            return type
        }
    }
    return "USB-C"
}

/// Is this IOKit class name an HPM power-controller node (the node that carries
/// the port's `UUID`)?
///
/// **This predicate is deliberately class-agnostic and must stay that way.**
/// `AppleHPMDevice` is the base class used on **M1/M2**; `AppleHPMDeviceHAL*`
/// (e.g. `AppleHPMDeviceHALType3`) is the M3+ subclass. **Both carry a `UUID`.**
/// The 206-machine probe-35 corpus is unambiguous: 295/295 `AppleHPMDevice`
/// ports and 409/409 `AppleHPMDeviceHALType3` ports have one, zero misses
/// (704 ports total; probe 35 also lists 50 `(no port child)` internal
/// controllers, which carry a UUID but own no port and are not counted).
///
/// Narrowing this to the `HALType3` subclass would silently drop every M1/M2
/// machine from the port join while looking like "M1/M2 hardware has no UUID".
/// That misreading has already cost two separate investigations, so it is pinned
/// by `HPMControllerClassGateTests`: narrow it and the tests go red.
public func wcIsHPMControllerClass(_ className: String) -> Bool {
    className == "AppleHPMDevice" || className.hasPrefix("AppleHPMDeviceHAL")
}

/// Walks the IOKit parent chain from `service` looking for an HPM power
/// controller node (`AppleHPMDevice` or `AppleHPMDeviceHAL*`) and
/// returns its `UUID` property as a raw string.
///
/// This is the same walk `AppleHPMInterfaceWatcher.hpmControllerUUID(for:)`
/// performs, factored out so every per-port source watcher (PowerSource,
/// USB3Transport, TRMTransport, CIOCableCapability) can capture the same UUID
/// without duplicating the logic. Both share `wcIsHPMControllerClass` so the two
/// walks can never drift apart on which classes count.
///
/// Returns `nil` when no HPM controller is found within 12 parent steps, or
/// when the controller carries no `UUID` property. The depth limit of 12
/// is larger than the watcher's 8 to accommodate deeper subtrees
/// (IOPortFeaturePowerSource sits ~4 levels below the HPM device node,
/// whereas `AppleHPMInterface` is a direct child).
public func wcHPMControllerUUID(for service: io_service_t) -> String? {
    guard let uuid = wcHPMControllerProperty(for: service, key: "UUID") as? String,
          !uuid.isEmpty else { return nil }
    return uuid
}

/// Walks the IOKit parent chain from `service` to its HPM power controller and
/// returns the controller's `RID` (the SPMI resource ID identifying that
/// controller on the bus).
///
/// `RID` is the ordering key for `AppleSmartBattery`'s `PortControllerInfo`
/// array. That array carries no port identifier of its own, so entry N can only
/// be tied back to a physical port by knowing the order Apple built it in;
/// sorting the ports by controller `RID` reproduces that order. See
/// `PowerService.orderedPortKeys(_:)` for the ordering itself and
/// `HPMPortKeyOrderCorpusSweepTests` for the corpus evidence.
///
/// Returns `nil` when no controller is found, or when it carries no numeric
/// `RID`. Every one of the 1518 real ports in the probe-35 corpus has one, so
/// `nil` is a defensive path, not an expected outcome.
public func wcHPMControllerRID(for service: io_service_t) -> Int? {
    guard let raw = wcHPMControllerProperty(for: service, key: "RID") else { return nil }
    // IOKit hands numbers back as CFNumber, which bridges to NSNumber. Going
    // via NSNumber (rather than `as? Int`) accepts whatever width the kernel
    // published it at.
    return (raw as? NSNumber)?.intValue
}

/// Shared parent walk behind `wcHPMControllerUUID` and `wcHPMControllerRID`:
/// climbs from `service` until it hits an HPM power controller node
/// (`AppleHPMDevice` or `AppleHPMDeviceHAL*`) and reads one property off it.
///
/// This is the same walk `AppleHPMInterfaceWatcher.hpmControllerUUID(for:)`
/// performs, factored out so every per-port source watcher (PowerSource,
/// USB3Transport, TRMTransport, CIOCableCapability) can capture the same
/// controller identity without duplicating the logic. All of them share
/// `wcIsHPMControllerClass` so the walks can never drift apart on which
/// classes count.
///
/// Stops at the first controller found: if that controller lacks the property,
/// the answer is `nil` rather than "keep climbing", because a property read off
/// some further-up node would not be describing this port's controller.
///
/// Returns `nil` when no controller is found within 12 parent steps. The depth
/// limit of 12 is larger than the watcher's 8 to accommodate deeper subtrees
/// (IOPortFeaturePowerSource sits ~4 levels below the HPM device node, whereas
/// `AppleHPMInterface` is a direct child).
public func wcHPMControllerProperty(for service: io_service_t, key: String) -> Any? {
    var current = service
    IOObjectRetain(current)
    defer { IOObjectRelease(current) }

    for _ in 0..<12 {
        var classBuf = [CChar](repeating: 0, count: 128)
        IOObjectGetClass(current, &classBuf)
        let cls = String(cString: classBuf)
        if wcIsHPMControllerClass(cls) {
            return IORegistryEntryCreateCFProperty(
                current,
                key as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue()
        }

        var parent: io_service_t = 0
        guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
            break
        }
        IOObjectRelease(current)
        current = parent
    }
    return nil
}

/// The live service for a registry entry ID, or nil when it is gone.
/// The caller owns the returned handle and must release it.
public func wcService(forEntryID entryID: UInt64) -> io_service_t? {
    guard entryID != 0, let matching = IORegistryEntryIDMatching(entryID) else { return nil }
    let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
    return service == 0 ? nil : service
}
