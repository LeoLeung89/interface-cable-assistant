import Foundation

// The bundle used for all localized strings in WhatCable.
// Updated in tandem with _coreLocalizedBundle when language changes.
//
// Same lock-guarded pattern as WhatCableCore's _coreLocalizedBundle: the write
// (live language switch, on the main actor from AppSettings) is serialised
// against any concurrent read. Reads stay synchronous so call sites are
// unchanged.
private let _appBundleLock = NSLock()
private nonisolated(unsafe) var _appBundleStorage: Bundle = .module

var _appLocalizedBundle: Bundle {
    _appBundleLock.lock()
    defer { _appBundleLock.unlock() }
    return _appBundleStorage
}

/// A language the app ships, for the Settings language picker.
/// `id` is the BCP-47 code (also the picker tag and the `.lproj` name);
/// `name` is the language's own name (its autonym).
struct AppLanguage: Identifiable, Hashable {
    let id: String
    let name: String
}

enum AppLanguages {
    /// Every language the app bundles, derived at runtime from the `.lproj`
    /// resources in `Bundle.module` (the same bundle `setAppLocale` reads). This
    /// is the single source of truth: adding a new `<code>.lproj` makes it appear
    /// in the picker automatically, with no code edit. Each entry's display name
    /// is the language's own autonym (e.g. "Deutsch", "日本語"), first letter
    /// capitalised in that language's own locale.
    ///
    /// Codes are canonicalised because SPM lowercases the script/region when it
    /// copies resources (`zh-Hans.lproj` lands as `zh-hans.lproj`), so the raw
    /// bundle names come back lowercased. `canonicalLanguageIdentifier` restores
    /// the BCP-47 case (`zh-hans` -> `zh-Hans`, `pt-br` -> `pt-BR`) so the picker
    /// tag matches what the system expects and what the old picker stored.
    static let available: [AppLanguage] = {
        Bundle.module.localizations
            .filter { $0 != "Base" }
            .map { rawCode in
                let code = Locale.canonicalLanguageIdentifier(from: rawCode)
                let locale = Locale(identifier: code)
                let display = locale.localizedString(forIdentifier: code) ?? code
                let name = display.isEmpty
                    ? code
                    : display.prefix(1).capitalized(with: locale) + display.dropFirst()
                return AppLanguage(id: code, name: name)
            }
            .sorted { $0.id < $1.id }
    }()
}

func setAppLocale(_ identifier: String) {
    let resolved: Bundle
    if identifier.isEmpty {
        resolved = .module
    } else if let url = Bundle.module.url(forResource: identifier, withExtension: "lproj"),
              let b = Bundle(url: url) {
        resolved = b
    } else {
        resolved = .module
    }
    _appBundleLock.lock()
    _appBundleStorage = resolved
    _appBundleLock.unlock()
}
