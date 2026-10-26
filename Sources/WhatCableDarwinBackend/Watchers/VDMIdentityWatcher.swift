import Foundation
import IOKit
import WhatCableCore
import os.log

@MainActor
public final class VDMIdentityWatcher: ObservableObject {
    public enum Endpoint: String, Codable, Sendable {
        case sop = "SOP"
        case sopPrime = "SOP'"
    }

    public struct VDMIdentityUpdate: Codable, Sendable, Equatable {
        public let portIndex: Int
        /// Port type description (e.g. "USB-C", "MagSafe 3") used to
        /// disambiguate ports that share the same portIndex.
        public let portType: String
        public let endpoint: Endpoint
        public let identity: VDMIdentity
    }

    @Published public private(set) var identities: [VDMIdentityUpdate] = []

    private static let matchedClasses = [
        "IOPortTransportComponentCCUSBPDSOP",
        "IOPortTransportComponentCCUSBPDSOPp",
    ]

    private var notifyPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    // Which class each live notification iterator matches, so a
    // terminal invalidation (see `handleAdded`/`handleRemoved`) can
    // re-register the SAME matching notification. Needed because
    // `IOServiceMatchingCallback` is a non-capturing C function pointer: the
    // callback itself has no way to carry the class name, only the refcon
    // and the iterator handle IOKit calls it back with.
    private var addedClassForIterator: [io_iterator_t: String] = [:]
    private var removedClassForIterator: [io_iterator_t: String] = [:]

    // Consecutive-recovery counters, keyed by class name so they survive a
    // re-registration (the iterator handle changes each time). Reset to 0 on
    // any clean drain for that class; a run of failures this long without a
    // single clean drain in between means re-registering is not helping, so
    // recovery stops rather than looping forever.
    private var addedRecoveryAttempts: [String: Int] = [:]
    private var removedRecoveryAttempts: [String: Int] = [:]
    private static let maxRecoveryAttempts = 3

    nonisolated private static let log = Logger(subsystem: "uk.whatcable.whatcable", category: "vdm-identity")

    public init() {}

    public func start() {
        guard notifyPort == nil else { return }
        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        notifyPort = port

        for className in Self.matchedClasses {
            registerAdded(className: className)
            registerRemoved(className: className)
        }
    }

    /// Registers (or re-registers) the added-notification for one class and
    /// drains its initial iterator. Factored out of `start()` so
    /// `handleAdded` can call it again on a terminal iterator invalidation
    /// (see its doc comment): a fresh registration's own initial drain is
    /// what re-arms delivery.
    private func registerAdded(className: String) {
        guard let notifyPort else { return }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let added: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let watcher = Unmanaged<VDMIdentityWatcher>.fromOpaque(refcon).takeUnretainedValue()
            // Capture weakly so that if the watcher is torn down before this
            // task runs, it becomes a no-op rather than touching freed memory.
            Task { @MainActor [weak watcher] in watcher?.handleAdded(iterator) }
        }
        var addedIter: io_iterator_t = 0
        if IOServiceAddMatchingNotification(
            notifyPort,
            kIOMatchedNotification,
            IOServiceMatching(className),
            added,
            selfPtr,
            &addedIter
        ) == KERN_SUCCESS {
            addedClassForIterator[addedIter] = className
            iterators.append(addedIter)
            handleAdded(addedIter)
        }
    }

    /// Removed-notification counterpart to `registerAdded`. See its comment.
    private func registerRemoved(className: String) {
        guard let notifyPort else { return }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let removed: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let watcher = Unmanaged<VDMIdentityWatcher>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor [weak watcher] in watcher?.handleRemoved(iterator) }
        }
        var removedIter: io_iterator_t = 0
        if IOServiceAddMatchingNotification(
            notifyPort,
            kIOTerminatedNotification,
            IOServiceMatching(className),
            removed,
            selfPtr,
            &removedIter
        ) == KERN_SUCCESS {
            removedClassForIterator[removedIter] = className
            iterators.append(removedIter)
            handleRemoved(removedIter)
        }
    }

    public func stop() {
        for iter in iterators where iter != 0 { IOObjectRelease(iter) }
        iterators.removeAll()
        addedClassForIterator.removeAll()
        removedClassForIterator.removeAll()
        addedRecoveryAttempts.removeAll()
        removedRecoveryAttempts.removeAll()
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
        identities.removeAll()
    }

    public func refresh() {
        // Build the new list locally and assign once. Mutating the published
        // `identities` in place (removeAll then re-append) emits a transient empty
        // value that downstream subscribers see as "no identities," causing brief
        // UI flicker on every poll tick. See issue #227.
        var rebuilt: [VDMIdentityUpdate] = []
        for className in Self.matchedClasses {
            var iter: io_iterator_t = 0
            if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iter) == KERN_SUCCESS {
                defer { IOObjectRelease(iter) }
                let updates = wcDrainAllRetrying(iter) { service in makeUpdate(from: service) }
                for update in updates {
                    guard let update else { continue }
                    rebuilt.removeAll {
                        $0.portIndex == update.portIndex &&
                        $0.portType == update.portType &&
                        $0.endpoint == update.endpoint
                    }
                    rebuilt.append(update)
                }
            }
        }
        if rebuilt != identities { identities = rebuilt }
    }

    private func handleAdded(_ iterator: io_iterator_t) {
        var terminallyInvalidated = false
        let updates = wcDrainAllRetrying(iterator, transform: { service in makeUpdate(from: service) }) {
            terminallyInvalidated = true
        }
        for update in updates {
            guard let update else { continue }
            identities.removeAll {
                $0.portIndex == update.portIndex &&
                $0.portType == update.portType &&
                $0.endpoint == update.endpoint
            }
            identities.append(update)
        }
        if terminallyInvalidated {
            recoverAddedNotification(iterator: iterator)
        } else if let className = addedClassForIterator[iterator] {
            // A clean drain clears the run of failures, so a transient blip
            // followed by a healthy notification does not eat into the cap
            // below.
            addedRecoveryAttempts[className] = 0
        }
    }

    /// Called at most once per drain, only when `handleAdded`'s drain saw at
    /// least one item and was still reporting an invalid iterator after
    /// every retry (`wcDrainAllRetrying`'s `onTerminalInvalidation`).
    ///
    /// `VDMIdentityWatcher` has no polling fallback: `CableDiagnosticView`
    /// only calls `refresh()` once, on screen appear (see its `.onAppear`),
    /// not on a timer, so an added-notification that stays deaf here would
    /// stay deaf for the rest of the screen's lifetime. The recovery is to
    /// tear down and re-create the registration for this one class: a fresh
    /// `IOServiceAddMatchingNotification` call's own initial drain (inside
    /// `registerAdded`) re-delivers the current set, which is how delivery
    /// gets re-armed. Whether `IOIteratorReset` on a notification-backed
    /// iterator reliably re-arms it is not documented by Apple either way;
    /// treating a terminal invalidation as unrecovered and re-registering
    /// from scratch is a reasoned inference, not a measured fact.
    ///
    /// Capped at `maxRecoveryAttempts` consecutive failures for the same
    /// class (reset by any clean drain in between, see `handleAdded`). A
    /// registry that keeps invalidating every fresh registration is not
    /// something re-registering again can fix, so past the cap this stops
    /// trying rather than looping: `identities` for that class may go stale
    /// until the next app-level refresh brings the screen back and the
    /// notification is set up again from scratch.
    private func recoverAddedNotification(iterator: io_iterator_t) {
        guard let className = addedClassForIterator.removeValue(forKey: iterator) else { return }
        iterators.removeAll { $0 == iterator }
        IOObjectRelease(iterator)

        let attempts = (addedRecoveryAttempts[className] ?? 0) + 1
        addedRecoveryAttempts[className] = attempts
        guard attempts <= Self.maxRecoveryAttempts else {
            Self.log.error("VDMIdentityWatcher: added-notification for \(className, privacy: .public) failed to recover after \(Self.maxRecoveryAttempts) attempts; giving up until the next refresh")
            return
        }
        Self.log.error("VDMIdentityWatcher: added-notification for \(className, privacy: .public) stayed invalid after retries; re-registering to restore delivery (attempt \(attempts))")
        registerAdded(className: className)
    }

    private func handleRemoved(_ iterator: io_iterator_t) {
        var terminallyInvalidated = false
        let removed = wcDrainAllRetrying(iterator, transform: { service -> (portIndex: Int, portType: String, endpoint: Endpoint)? in
            guard let endpoint = Self.endpoint(for: service) else { return nil }
            func read(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            let portIndex = wcPortIndex(read: read, service: service)
            let portType = wcPortType(read: read, service: service)
            return (portIndex, portType, endpoint)
        }) {
            terminallyInvalidated = true
        }
        for entry in removed {
            guard let entry else { continue }
            identities.removeAll {
                $0.portIndex == entry.portIndex &&
                $0.portType == entry.portType &&
                $0.endpoint == entry.endpoint
            }
        }
        if terminallyInvalidated {
            recoverRemovedNotification(iterator: iterator)
        } else if let className = removedClassForIterator[iterator] {
            removedRecoveryAttempts[className] = 0
        }
    }

    /// Removed-notification counterpart to `recoverAddedNotification`. See
    /// its doc comment for why this watcher needs the stronger
    /// tear-down-and-re-register recovery instead of relying on a poll, and
    /// for the recovery-attempt cap.
    private func recoverRemovedNotification(iterator: io_iterator_t) {
        guard let className = removedClassForIterator.removeValue(forKey: iterator) else { return }
        iterators.removeAll { $0 == iterator }
        IOObjectRelease(iterator)

        let attempts = (removedRecoveryAttempts[className] ?? 0) + 1
        removedRecoveryAttempts[className] = attempts
        guard attempts <= Self.maxRecoveryAttempts else {
            Self.log.error("VDMIdentityWatcher: removed-notification for \(className, privacy: .public) failed to recover after \(Self.maxRecoveryAttempts) attempts; giving up until the next refresh")
            return
        }
        Self.log.error("VDMIdentityWatcher: removed-notification for \(className, privacy: .public) stayed invalid after retries; re-registering to restore delivery (attempt \(attempts))")
        registerRemoved(className: className)
    }

    private func makeUpdate(from service: io_service_t) -> VDMIdentityUpdate? {
        guard let endpoint = Self.endpoint(for: service) else { return nil }

        func read(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }

        return Self.parseUpdate(
            read: read,
            className: endpoint == .sop
                ? "IOPortTransportComponentCCUSBPDSOP"
                : "IOPortTransportComponentCCUSBPDSOPp",
            endpoint: endpoint,
            portIndex: wcPortIndex(read: read, service: service),
            portType: wcPortType(read: read, service: service)
        )
    }

    /// Parse a `VDMIdentityUpdate` from a property-read closure and pre-resolved
    /// context values. Extracted from `makeUpdate(from:)` so corpus-replay tests
    /// can drive the parse logic without real IOKit services.
    internal nonisolated static func parseUpdate(
        read: (String) -> Any?,
        className: String,
        endpoint: Endpoint,
        portIndex: Int,
        portType: String
    ) -> VDMIdentityUpdate? {
        let metadata = wcDictionary(read("Metadata"))
        let vdos = wcArray(metadata["VDOs"]).compactMap(wcData)
        let identity = VDMIdentity(
            vendorId: wcInt(metadata["VID"]) != 0 ? wcInt(metadata["VID"]) : wcInt(read("Vendor ID")),
            productId: wcInt(metadata["PID"]) != 0 ? wcInt(metadata["PID"]) : wcInt(read("Product ID")),
            bcdDevice: wcInt(metadata["bcdDevice"]),
            specRevision: wcInt(metadata["Specification Revision"]) != 0
                ? wcInt(metadata["Specification Revision"])
                : wcInt(read("Specification Revision")),
            vdos: vdos,
            productType: metadata["Product Type"].map(wcInt) ?? read("Product Type").map(wcInt),
            productTypeDescription: (metadata["Product Type Description"] as? String)
                ?? (read("Product Type Description") as? String)
        )
        return VDMIdentityUpdate(
            portIndex: portIndex,
            portType: portType,
            endpoint: endpoint,
            identity: identity
        )
    }

    private static func endpoint(for service: io_service_t) -> Endpoint? {
        var classBuf = [CChar](repeating: 0, count: 128)
        guard IOObjectGetClass(service, &classBuf) == KERN_SUCCESS else { return nil }
        switch String(cString: classBuf) {
        case "IOPortTransportComponentCCUSBPDSOP": return .sop
        case "IOPortTransportComponentCCUSBPDSOPp": return .sopPrime
        default: return nil
        }
    }
}
