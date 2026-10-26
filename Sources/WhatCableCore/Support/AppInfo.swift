import Foundation

public enum AppInfo {
    public static let name = "接口线缆助手"
    public static let version: String = {
        // Single source of truth lives in the .app's Info.plist (written by
        // scripts/build-app.sh). Falls back to "dev" when run via `swift run`,
        // which has no bundled Info.plist.
        if let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            return v
        }
        // The CLI binary at Contents/Helpers/whatcable lives one extra level
        // deep, so Bundle.main doesn't auto-resolve to the .app. Walk up from
        // the executable until we find a Contents/Info.plist sibling.
        // Resolve symlinks first: when invoked via Homebrew's /opt/homebrew/bin
        // symlink, the executable path points outside the .app and walking up
        // would never find the bundle.
        let exe = Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""
        var dir = URL(fileURLWithPath: exe)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        for _ in 0..<4 {
            let plist = dir.appendingPathComponent("Info.plist")
            if let data = try? Data(contentsOf: plist),
               let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let v = parsed["CFBundleShortVersionString"] as? String {
                return v
            }
            dir = dir.deletingLastPathComponent()
        }
        return "dev"
    }()
    public static let credit = "WhatCable"
    public static var tagline: String { String(localized: "What can this USB-C cable actually do?", bundle: _coreLocalizedBundle) }
    public static let copyright = "© \(Calendar.current.component(.year, from: Date())) \(credit)"
    public static let helpURL = URL(string: "https://github.com/LeoLeung89/interface-cable-assistant")!

    /// Link to the GitHub release for the running version. Real builds always
    /// have a matching `v<version>` tag; `dev` builds (run via `swift run`) have
    /// no tag, so fall back to the releases list.
    public static var releaseURL: URL {
        if version == "dev" {
            return URL(string: "https://github.com/LeoLeung89/interface-cable-assistant/releases")!
        }
        return URL(string: "https://github.com/LeoLeung89/interface-cable-assistant/releases/tag/v\(version)")!
    }

    /// Compare dot-separated numeric versions, with optional semver-style
    /// pre-release suffixes (e.g. "1.2.0-beta.1"). Non-numeric segments in
    /// the core version compare as 0. A plain release beats any pre-release
    /// of the same core version (so a stable build outranks its own betas).
    /// Whether a version string carries a pre-release suffix ("1.5.0-beta.3").
    /// Shares `splitPrerelease` with `isNewer` so there is one definition of
    /// what a pre-release is, rather than a stray `contains("-")` somewhere.
    public static func isPrerelease(_ version: String) -> Bool {
        splitPrerelease(version).suffix != nil
    }

    public static func isNewer(remote: String, current: String) -> Bool {
        let (rCore, rSuffix) = splitPrerelease(remote)
        let (cCore, cSuffix) = splitPrerelease(current)

        let r = parts(rCore)
        let c = parts(cCore)
        for i in 0..<max(r.count, c.count) {
            let rv = i < r.count ? r[i] : 0
            let cv = i < c.count ? c[i] : 0
            if rv != cv { return rv > cv }
        }

        // Cores are equal. No suffix beats any suffix (a release beats its
        // own betas). Two suffixes compare identifier by identifier.
        switch (rSuffix, cSuffix) {
        case (nil, nil):
            return false
        case (nil, .some):
            return true
        case (.some, nil):
            return false
        case let (.some(rs), .some(cs)):
            return isPrereleaseNewer(rs, cs)
        }
    }

    /// Split a version string at the first "-" into its core and an
    /// optional pre-release suffix. "1.2.0-beta.1" -> ("1.2.0", "beta.1").
    /// "1.2.0" -> ("1.2.0", nil).
    private static func splitPrerelease(_ version: String) -> (core: Substring, suffix: Substring?) {
        guard let dashIndex = version.firstIndex(of: "-") else {
            return (Substring(version), nil)
        }
        let core = version[version.startIndex..<dashIndex]
        let suffix = version[version.index(after: dashIndex)...]
        return (core, suffix)
    }

    /// Compare two pre-release suffixes identifier by identifier, following
    /// semver's rule: numeric identifiers compare numerically, non-numeric
    /// identifiers compare lexically, a numeric identifier is always older
    /// than a non-numeric one, and a suffix that runs out of identifiers
    /// first is older ("beta" is older than "beta.1").
    private static func isPrereleaseNewer(_ remote: Substring, _ current: Substring) -> Bool {
        let rParts = remote.split(separator: ".")
        let cParts = current.split(separator: ".")
        for i in 0..<max(rParts.count, cParts.count) {
            guard i < rParts.count else { return false }
            guard i < cParts.count else { return true }

            let rPart = rParts[i]
            let cPart = cParts[i]
            let rNum = Int(rPart)
            let cNum = Int(cPart)

            switch (rNum, cNum) {
            case let (.some(rv), .some(cv)):
                if rv != cv { return rv > cv }
            case (.some, .none):
                return false
            case (.none, .some):
                return true
            case (.none, .none):
                if rPart != cPart { return rPart > cPart }
            }
        }
        return false
    }

    private static func parts(_ version: Substring) -> [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }
}
