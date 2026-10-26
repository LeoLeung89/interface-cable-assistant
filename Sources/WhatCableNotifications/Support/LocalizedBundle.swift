import Foundation

// The bundle used for all localized strings in WhatCableNotifications.
// Defaults to the module bundle (system language). Call setNotificationsLocale(_:)
// to switch to a specific lproj bundle for live language switching.
//
// Access goes through an NSLock so the live language switch (written on the
// main actor from AppSettings) can't race a concurrent read from a background
// context. NSLock is plain Foundation, keeping WhatCableNotifications
// import-clean (no Apple-only `os` lock). Reads stay synchronous, so every
// `String(localized:bundle: _notificationsLocalizedBundle)` call site is
// unchanged. Modelled exactly on WhatCableCore's `_coreLocalizedBundle`.
private let _notificationsBundleLock = NSLock()
private nonisolated(unsafe) var _notificationsBundleStorage: Bundle = .module

public var _notificationsLocalizedBundle: Bundle {
    _notificationsBundleLock.lock()
    defer { _notificationsBundleLock.unlock() }
    return _notificationsBundleStorage
}

public func setNotificationsLocale(_ identifier: String) {
    let resolved: Bundle
    if identifier.isEmpty {
        resolved = .module
    } else if let url = Bundle.module.url(forResource: identifier, withExtension: "lproj"),
              let b = Bundle(url: url) {
        resolved = b
    } else {
        resolved = .module
    }
    _notificationsBundleLock.lock()
    _notificationsBundleStorage = resolved
    _notificationsBundleLock.unlock()
}
