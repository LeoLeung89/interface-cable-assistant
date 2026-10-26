import Foundation

// The bundle used for all localized strings in WhatCableCore.
// Defaults to the module bundle (system language). Call setCoreLocale(_:)
// to switch to a specific lproj bundle for live language switching.
//
// Access goes through an NSLock so the live language switch (written on the
// main actor from AppSettings) can't race a concurrent read from a background
// context (the CLI and the snapshot formatters read these strings off-main).
// NSLock is plain Foundation, keeping WhatCableCore import-clean (no Apple-only
// `os` lock). Reads stay synchronous, so every
// `String(localized:bundle: _coreLocalizedBundle)` call site is unchanged.
private let _coreBundleLock = NSLock()
private nonisolated(unsafe) var _coreBundleStorage: Bundle = .module

public var _coreLocalizedBundle: Bundle {
    _coreBundleLock.lock()
    defer { _coreBundleLock.unlock() }
    return _coreBundleStorage
}

public func setCoreLocale(_ identifier: String) {
    let resolved: Bundle
    if identifier.isEmpty {
        resolved = .module
    } else if let url = Bundle.module.url(forResource: identifier, withExtension: "lproj"),
              let b = Bundle(url: url) {
        resolved = b
    } else {
        resolved = .module
    }
    _coreBundleLock.lock()
    _coreBundleStorage = resolved
    _coreBundleLock.unlock()
}
