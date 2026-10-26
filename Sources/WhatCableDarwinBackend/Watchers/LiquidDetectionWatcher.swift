import Foundation
import IOKit
import WhatCableCore
import os.log

@MainActor
public final class LiquidDetectionWatcher: ObservableObject {
    public struct LiquidDetectionUpdate: Codable, Sendable, Equatable {
        public let portIndex: Int
        public let portType: String
        public let status: LiquidDetectionStatus
    }

    @Published public private(set) var statuses: [LiquidDetectionUpdate] = []

    private var notifyPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0

    // Consecutive-recovery counters. Reset to 0 on any clean drain (see
    // `handleAdded`/`handleRemoved`); a run of failures this long without a
    // single clean drain in between means re-registering is not helping, so
    // recovery stops rather than looping forever.
    private var addedRecoveryAttempts = 0
    private var removedRecoveryAttempts = 0
    private static let maxRecoveryAttempts = 3

    nonisolated private static let log = Logger(subsystem: "uk.whatcable.whatcable", category: "liquid-detection")

    public init() {}

    public func start() {
        guard notifyPort == nil else { return }
        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        notifyPort = port

        registerAdded()
        registerRemoved()
    }

    /// Registers (or re-registers) the added-notification and drains its
    /// initial iterator. Factored out of `start()` so `handleAdded` can call
    /// it again on a terminal iterator invalidation (see its doc comment): a
    /// fresh registration's own initial drain is what re-arms delivery.
    private func registerAdded() {
        guard let notifyPort else { return }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let added: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let watcher = Unmanaged<LiquidDetectionWatcher>.fromOpaque(refcon).takeUnretainedValue()
            // Capture weakly so that if the watcher is torn down before this
            // task runs, it becomes a no-op rather than touching freed memory.
            Task { @MainActor [weak watcher] in watcher?.handleAdded(iterator) }
        }
        if IOServiceAddMatchingNotification(
            notifyPort,
            kIOMatchedNotification,
            IOServiceMatching("AppleHPMLDCMType2"),
            added,
            selfPtr,
            &addedIterator
        ) == KERN_SUCCESS {
            handleAdded(addedIterator)
        }
    }

    /// Removed-notification counterpart to `registerAdded`. See its comment.
    private func registerRemoved() {
        guard let notifyPort else { return }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let removed: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let watcher = Unmanaged<LiquidDetectionWatcher>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor [weak watcher] in watcher?.handleRemoved(iterator) }
        }
        if IOServiceAddMatchingNotification(
            notifyPort,
            kIOTerminatedNotification,
            IOServiceMatching("AppleHPMLDCMType2"),
            removed,
            selfPtr,
            &removedIterator
        ) == KERN_SUCCESS {
            handleRemoved(removedIterator)
        }
    }

    public func stop() {
        if addedIterator != 0 { IOObjectRelease(addedIterator); addedIterator = 0 }
        if removedIterator != 0 { IOObjectRelease(removedIterator); removedIterator = 0 }
        addedRecoveryAttempts = 0
        removedRecoveryAttempts = 0
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
        statuses.removeAll()
    }

    public func refresh() {
        // Build the new list locally and assign once. Mutating the published
        // `statuses` in place (removeAll then re-append) emits a transient empty
        // value that downstream subscribers see as "no ports," causing brief UI
        // flicker on every poll tick. See issue #227.
        var rebuilt: [LiquidDetectionUpdate] = []
        var iter: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleHPMLDCMType2"), &iter) == KERN_SUCCESS {
            defer { IOObjectRelease(iter) }
            let updates = wcDrainAllRetrying(iter) { service in makeUpdate(from: service) }
            for update in updates {
                guard let update else { continue }
                rebuilt.removeAll {
                    $0.portIndex == update.portIndex && $0.portType == update.portType
                }
                rebuilt.append(update)
            }
        }
        if rebuilt != statuses { statuses = rebuilt }
    }

    private func handleAdded(_ iterator: io_iterator_t) {
        var terminallyInvalidated = false
        let updates = wcDrainAllRetrying(iterator, transform: { service in makeUpdate(from: service) }) {
            terminallyInvalidated = true
        }
        for update in updates {
            guard let update else { continue }
            statuses.removeAll {
                $0.portIndex == update.portIndex && $0.portType == update.portType
            }
            statuses.append(update)
        }
        if terminallyInvalidated {
            recoverAddedNotification(iterator: iterator)
        } else {
            // A clean drain clears the run of failures, so a transient blip
            // followed by a healthy notification does not eat into the cap
            // below.
            addedRecoveryAttempts = 0
        }
    }

    /// Called at most once per drain, only when `handleAdded`'s drain saw at
    /// least one item and was still reporting an invalid iterator after
    /// every retry (`wcDrainAllRetrying`'s `onTerminalInvalidation`).
    ///
    /// `LiquidDetectionWatcher` has no polling fallback: `CableDiagnosticView`
    /// only calls `refresh()` once, on screen appear, not on a timer, so an
    /// added-notification that stays deaf here would stay deaf for the rest
    /// of the screen's lifetime. The recovery is to tear down and re-create
    /// the registration: a fresh `IOServiceAddMatchingNotification` call's
    /// own initial drain (inside `registerAdded`) re-delivers the current
    /// set, which is how delivery gets re-armed. Whether `IOIteratorReset`
    /// on a notification-backed iterator reliably re-arms it is not
    /// documented by Apple either way; treating a terminal invalidation as
    /// unrecovered and re-registering from scratch is a reasoned inference,
    /// not a measured fact.
    ///
    /// Capped at `maxRecoveryAttempts` consecutive failures (reset by any
    /// clean drain in between, see `handleAdded`). A registry that keeps
    /// invalidating every fresh registration is not something re-registering
    /// again can fix, so past the cap this stops trying rather than looping:
    /// `statuses` may go stale until the next app-level refresh brings the
    /// screen back and the notification is set up again from scratch.
    private func recoverAddedNotification(iterator: io_iterator_t) {
        guard iterator == addedIterator else { return }
        IOObjectRelease(iterator)
        addedIterator = 0

        addedRecoveryAttempts += 1
        guard addedRecoveryAttempts <= Self.maxRecoveryAttempts else {
            Self.log.error("LiquidDetectionWatcher: added-notification failed to recover after \(Self.maxRecoveryAttempts) attempts; giving up until the next refresh")
            return
        }
        Self.log.error("LiquidDetectionWatcher: added-notification stayed invalid after retries; re-registering to restore delivery (attempt \(self.addedRecoveryAttempts))")
        registerAdded()
    }

    private func handleRemoved(_ iterator: io_iterator_t) {
        var terminallyInvalidated = false
        let removed = wcDrainAllRetrying(iterator, transform: { service -> (portIndex: Int, portType: String) in
            func read(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            return (wcPortIndex(read: read, service: service), wcPortType(read: read, service: service))
        }) {
            terminallyInvalidated = true
        }
        for entry in removed {
            statuses.removeAll {
                $0.portIndex == entry.portIndex && $0.portType == entry.portType
            }
        }
        if terminallyInvalidated {
            recoverRemovedNotification(iterator: iterator)
        } else {
            removedRecoveryAttempts = 0
        }
    }

    /// Removed-notification counterpart to `recoverAddedNotification`. See
    /// its doc comment for why this watcher needs the stronger
    /// tear-down-and-re-register recovery instead of relying on a poll, and
    /// for the recovery-attempt cap.
    private func recoverRemovedNotification(iterator: io_iterator_t) {
        guard iterator == removedIterator else { return }
        IOObjectRelease(iterator)
        removedIterator = 0

        removedRecoveryAttempts += 1
        guard removedRecoveryAttempts <= Self.maxRecoveryAttempts else {
            Self.log.error("LiquidDetectionWatcher: removed-notification failed to recover after \(Self.maxRecoveryAttempts) attempts; giving up until the next refresh")
            return
        }
        Self.log.error("LiquidDetectionWatcher: removed-notification stayed invalid after retries; re-registering to restore delivery (attempt \(self.removedRecoveryAttempts))")
        registerRemoved()
    }

    private func makeUpdate(from service: io_service_t) -> LiquidDetectionUpdate? {
        func read(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }

        return Self.parseUpdate(
            read: read,
            portIndex: wcPortIndex(read: read, service: service),
            portType: wcPortType(read: read, service: service)
        )
    }

    /// Parse a `LiquidDetectionUpdate` from a property-read closure and
    /// pre-resolved port context. Extracted from `makeUpdate(from:)` so
    /// corpus-replay tests can drive the parse logic without real IOKit services.
    internal nonisolated static func parseUpdate(
        read: (String) -> Any?,
        portIndex: Int,
        portType: String
    ) -> LiquidDetectionUpdate? {
        let state = (read("StateDescription") as? String)
            ?? read("State").map { String(wcInt($0)) }
            ?? "Unknown"
        let status = LiquidDetectionStatus(
            liquidDetected: wcBool(read("LiquidDetected")),
            state: state,
            measurementStatus: wcInt(read("MeasurementStatus")),
            mitigationsEnabled: wcBool(read("MitigationsEnabled"))
        )
        return LiquidDetectionUpdate(
            portIndex: portIndex,
            portType: portType,
            status: status
        )
    }
}
