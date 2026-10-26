// Self-hosted update checker.
import Foundation
import AppKit
import UserNotifications
import os.log
import WhatCableCore

struct AvailableUpdate: Equatable {
    let version: String
    let url: URL
    let downloadURL: URL?
    let notes: String?
}

/// Polls the GitHub releases API for newer versions of WhatCable.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    private nonisolated static let log = Logger(subsystem: "uk.whatcable.whatcable", category: "updates")
    /// Stable-only feed. GitHub never returns a pre-release from this, which
    /// is the first of the three layers keeping opted-out users off betas.
    private nonisolated static let latestEndpoint = URL(string: "https://api.github.com/repos/darrylmorley/whatcable/releases/latest")!
    /// Beta feed. The list endpoint is the only one that can see a
    /// pre-release. Drafts stay invisible to unauthenticated requests.
    private nonisolated static let listEndpoint = URL(string: "https://api.github.com/repos/darrylmorley/whatcable/releases?per_page=10")!
    private static let pollInterval: TimeInterval = 6 * 60 * 60 // 6h

    @Published private(set) var available: AvailableUpdate?
    @Published private(set) var isChecking = false
    @Published private(set) var lastCheck: Date?

    private var timer: Timer?
    private var notifiedVersion: String?
    /// Set immediately (synchronously) when postNotification starts an
    /// authorization request for a version, cleared once that request's
    /// completion runs (grant or deny). notifiedVersion is only stamped
    /// inside a grant, which happens asynchronously, so there is a window
    /// between the synchronous notifiedVersion guard and the async stamp
    /// where a second postNotification call for the same version (the 6h
    /// timer, checkIfStale, or a manual click landing while a system
    /// permission dialog is still open) would sail past that guard and
    /// start a second authorization request, posting twice if both grant.
    /// This field closes that window.
    private var pendingAuthVersion: String?
    /// When a manual "Check for Updates" click arrives while a silent
    /// background check is in flight, we set this so the in-flight result
    /// surfaces a visible alert instead of being silently swallowed.
    private var pendingVisibleCheck = false

    private init() {}

    func start() {
        guard Bundle.main.object(forInfoDictionaryKey: "WhatCableLabBuild") as? Bool != true else { return }
        guard timer == nil else { return }
        check(silent: true)
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check(silent: true) }
        }
    }

    /// Fire a silent check only if the last one is older than `staleAfter` (or
    /// none has run yet). Called when the menu bar panel opens so the displayed
    /// "X available" version is current before the user acts, without hitting
    /// the API on every open. The 6-hour background poll stays the baseline.
    /// (issue #372: keep the offered version fresh so a user isn't surprised by
    /// landing on a newer build than the one shown.)
    func checkIfStale(staleAfter: TimeInterval = 30 * 60) {
        // Don't re-check mid-install. A check that finds the running version is
        // newest sets `available = nil`, which would yank the install progress
        // banner out from under an in-flight install. The install path does its
        // own pre-download re-check anyway.
        guard case .idle = Installer.shared.state else { return }
        if Self.isStale(lastCheck: lastCheck, now: Date(), staleAfter: staleAfter) {
            check(silent: true)
        }
    }

    /// Pure throttle decision: a check is due if none has run yet, or the last
    /// one is at least `staleAfter` old. Split out so the policy is unit-tested
    /// without a live network call. Boundary is inclusive (>=).
    nonisolated static func isStale(lastCheck: Date?, now: Date, staleAfter: TimeInterval) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= staleAfter
    }

    /// Manually trigger a check. When `silent` is false, surfaces an alert
    /// for the "no update" case so the user gets feedback from the menu item.
    func check(silent: Bool) {
        if Bundle.main.object(forInfoDictionaryKey: "WhatCableLabBuild") as? Bool == true {
            if !silent {
                let alert = NSAlert()
                alert.messageText = "接口线缆助手"
                alert.informativeText = "本版本不自动更新。请到本项目 GitHub Releases 查看发布版本。"
                alert.runModal()
            }
            return
        }
        if isChecking {
            // A check is already in flight. If the user explicitly asked for
            // one, upgrade the in-flight result to non-silent so they still
            // get feedback. Multiple manual clicks coalesce into one alert.
            if !silent { pendingVisibleCheck = true }
            return
        }
        isChecking = true
        pendingVisibleCheck = !silent

        // Read the preference on the main actor before hopping onto the
        // session's callback queue.
        let betas = AppSettings.shared.receiveBetaUpdates

        URLSession.shared.dataTask(with: Self.makeReleaseRequest(includingBetas: betas)) { [weak self] data, _, error in
            Task { @MainActor in
                guard let self else { return }
                self.isChecking = false
                // If a manual click arrived during the in-flight check, this
                // gets surfaced. Reset for the next run.
                let visible = self.pendingVisibleCheck
                self.pendingVisibleCheck = false

                if let error {
                    // Don't stamp lastCheck on failure: the panel-open throttle
                    // uses it to mean "we successfully learned the latest N
                    // minutes ago", so a failed check should let the next panel
                    // open retry instead of suppressing checks for 30 minutes
                    // (e.g. after the Mac comes back online).
                    Self.log.error("Update check failed: \(error.localizedDescription, privacy: .public)")
                    if visible { self.showAlert(title: "Couldn't check for updates", message: error.localizedDescription) }
                    return
                }

                guard let data, let release = Self.newestRelease(from: data, allowPrerelease: betas) else {
                    if visible { self.showAlert(title: "Couldn't check for updates", message: "Unexpected response from GitHub.") }
                    return
                }

                // Only a successful, parsed response counts as a check for
                // throttle purposes.
                self.lastCheck = Date()

                // The preference was read before the request went out. If the
                // user switched betas off while it was in flight, that snapshot
                // is stale, so re-read now and drop a pre-release rather than
                // offering something they just opted out of (Codex review,
                // finding 1). Re-reading here is safe: this closure is already
                // back on the main actor.
                if AppSettings.shared.suppressesPrerelease(release) {
                    self.available = nil
                    if visible {
                        self.showAlert(
                            title: "You're up to date",
                            message: "WhatCable \(AppInfo.version) is the latest version."
                        )
                    }
                    return
                }

                if Self.isNewer(remote: release.version, current: AppInfo.version) {
                    let update = release
                    self.available = update
                    self.postNotification(update)
                    if visible {
                        // Manual "Check for Updates" click: surface a modal
                        // alert so the user gets the same feedback they get
                        // when already up-to-date, with a button to open the
                        // release page directly.
                        self.showUpdateAlert(update)
                    }
                } else {
                    self.available = nil
                    if visible {
                        self.showAlert(
                            title: "You're up to date",
                            message: "WhatCable \(AppInfo.version) is the latest version."
                        )
                    }
                }
            }
        }.resume()
    }

    /// Fetch the current latest release without touching published state or
    /// surfacing any UI. Used for the pre-install re-check (issue #372) so a
    /// release that shipped since the last background poll isn't missed.
    /// Returns nil on any network or parse error: callers fall back to
    /// whatever update they already had.
    func fetchLatestRelease() async -> AvailableUpdate? {
        let betas = AppSettings.shared.receiveBetaUpdates
        do {
            let (data, _) = try await URLSession.shared.data(for: Self.makeReleaseRequest(includingBetas: betas))
            return Self.newestRelease(from: data, allowPrerelease: betas)
        } catch {
            Self.log.error("Pre-install update re-check failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Build the `releases/latest` request used by both the background poll and
    /// the pre-install re-check, so the endpoint, headers and timeout live in
    /// one place.
    nonisolated static func makeReleaseRequest(includingBetas: Bool = false) -> URLRequest {
        var request = URLRequest(url: includingBetas ? listEndpoint : latestEndpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("WhatCable/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        return request
    }

    /// Drop an outstanding pre-release offer when the user opts out of betas.
    ///
    /// Without this, a tester could opt in, be shown a beta, opt out, and
    /// still install it from the banner that was already on screen, which
    /// makes the settings caption a lie (Codex review, finding 2). Called by
    /// `AppSettings` when the toggle changes.
    func discardPrereleaseOfferIfOptedOut() {
        guard let current = available else { return }
        if AppSettings.shared.suppressesPrerelease(current) {
            available = nil
            notifiedVersion = nil
        }
    }

    /// Sync the published `available` pointer when a pre-install re-check finds
    /// a newer release than the one originally surfaced, so the panel row
    /// reflects the version that's actually being installed.
    func updateAvailable(to update: AvailableUpdate) {
        available = update
    }

    /// Parse GitHub's `releases/latest` JSON into an `AvailableUpdate`. Returns
    /// nil if the payload is missing the fields we need. Does not compare
    /// against the running version; callers apply `isNewer` themselves.
    nonisolated static func parseRelease(from data: Data, allowPrerelease: Bool = false) -> AvailableUpdate? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parseRelease(json: json, allowPrerelease: allowPrerelease)
    }

    /// Pick the newest release from a response, handling both shapes: the
    /// single object `releases/latest` returns, and the array `releases`
    /// returns.
    ///
    /// The array is ordered by creation date, NOT by version, so taking the
    /// first entry offers the wrong build whenever a stable ships after a
    /// beta. Compare every candidate and keep the semver-newest, which is
    /// what makes a stable supersede its own betas for opted-in users.
    nonisolated static func newestRelease(from data: Data, allowPrerelease: Bool = false) -> AvailableUpdate? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }

        if let object = json as? [String: Any] {
            return parseRelease(json: object, allowPrerelease: allowPrerelease)
        }
        guard let array = json as? [[String: Any]] else { return nil }

        var best: AvailableUpdate?
        for item in array {
            guard let candidate = parseRelease(json: item, allowPrerelease: allowPrerelease) else { continue }
            if let current = best {
                if AppInfo.isNewer(remote: candidate.version, current: current.version) {
                    best = candidate
                }
            } else {
                best = candidate
            }
        }
        return best
    }

    private nonisolated static func parseRelease(json: [String: Any], allowPrerelease: Bool) -> AvailableUpdate? {
        guard let tag = json["tag_name"] as? String,
              let urlString = json["html_url"] as? String,
              let url = URL(string: urlString) else {
            return nil
        }
        // releases/latest never returns pre-releases, but this is a client-side
        // backstop so a mis-flagged release can never be offered as an update.
        // Opted-in beta users pass allowPrerelease, which lifts only this
        // check; every other gate (trusted host, signature, notarisation)
        // stays in force.
        if !allowPrerelease, json["prerelease"] as? Bool == true {
            return nil
        }
        // A draft has no usable asset and should never be offered. Drafts are
        // invisible to unauthenticated requests, so this is belt and braces.
        if json["draft"] as? Bool == true {
            return nil
        }
        let remote = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let notes = json["body"] as? String
        let downloadURL = (json["assets"] as? [[String: Any]])?
            .first(where: { ($0["name"] as? String) == "WhatCable.zip" })
            .flatMap { $0["browser_download_url"] as? String }
            .flatMap { URL(string: $0) }
            .flatMap { isTrustedDownloadURL($0) ? $0 : nil }
        return AvailableUpdate(version: remote, url: url, downloadURL: downloadURL, notes: notes)
    }

    /// Pure notification-gating decision (issue #550): update notifications
    /// no longer depend on the cable-change toggle, only on this one. Split
    /// out so the rule is unit-tested without touching
    /// `UNUserNotificationCenter`.
    nonisolated static func shouldNotify(notifyOnUpdates: Bool) -> Bool {
        notifyOnUpdates
    }

    /// Where an update notification actually gets posted. Injected (default
    /// is the real system call) so a test can drive `postNotification` itself,
    /// the real call site, rather than only the pure `shouldNotify` rule.
    /// Without this seam a test could pass while the gating guard in
    /// `postNotification` had drifted back to depending on notifyOnChanges.
    var notificationSink: (AvailableUpdate) -> Void = { update in
        let content = UNMutableNotificationContent()
        content.title = "WhatCable \(update.version) available"
        // Deliberately unlocalised, matching the rest of this file. Clicking
        // lands on the update banner in the popover, not release notes
        // directly (issue #567): the banner has its own "View release"
        // button for that, so the copy here promises the update itself, not
        // the notes.
        content.body = "You're on \(AppInfo.version). Click to view the update."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "update-\(update.version)", content: content, trigger: nil)
        )
    }

    /// Ask whether posting is currently allowed, requesting authorization
    /// first if it has never been decided. notifyOnUpdates now defaults on
    /// independent of notifyOnChanges (owner decision, issue #550), so
    /// nothing else is guaranteed to have requested notification permission
    /// before the first update is found; this closes that gap at post time
    /// instead. Injected (default is the real UNUserNotificationCenter flow)
    /// so a test can drive `postNotification`'s authorization gate without
    /// touching UNUserNotificationCenter, which crashes under the swift test
    /// runner (no signed app bundle). The completion always runs on the main
    /// actor, matching the pattern used for the URLSession completion above.
    var ensureNotificationAuthorization: (@escaping (Bool) -> Void) -> Void = { completion in
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                Task { @MainActor in completion(true) }
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error {
                        UpdateChecker.log.error("Notification auth failed: \(error.localizedDescription, privacy: .public)")
                    }
                    Task { @MainActor in completion(granted) }
                }
            default:
                Task { @MainActor in completion(false) }
            }
        }
    }

    func postNotification(_ update: AvailableUpdate) {
        guard Self.shouldNotify(notifyOnUpdates: AppSettings.shared.notifyOnUpdates) else { return }
        // Stamp only once a post genuinely happens, not when the version is
        // first seen and not merely because a post was attempted. A denied
        // authorization request must not stamp: otherwise a user who later
        // grants permission (e.g. in System Settings) would find this version
        // already marked "notified" and never see it. Stamping happens only
        // inside the authorization completion below.
        guard notifiedVersion != update.version else { return }
        // A second call for the same version must not start a second
        // authorization request while the first is still pending (see
        // pendingAuthVersion's doc comment for why this race exists).
        guard pendingAuthVersion != update.version else { return }
        pendingAuthVersion = update.version
        ensureNotificationAuthorization { [weak self] granted in
            guard let self else { return }
            // Clear on every outcome, grant or deny, so a denial still
            // allows a later retry instead of latching this version out
            // forever.
            self.pendingAuthVersion = nil
            guard granted else { return }
            self.notifiedVersion = update.version
            self.notificationSink(update)
        }
    }

    private func showAlert(title: String, message: String) {
        // LSUIElement apps can't reliably bring a modal alert to the front.
        // Briefly promote to a regular app so the alert takes focus, then
        // restore accessory policy after dismissal.
        let originalPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.window.level = .floating
        alert.runModal()

        NSApp.setActivationPolicy(originalPolicy)
    }

    private func showUpdateAlert(_ update: AvailableUpdate) {
        let originalPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()

        let alert = NSAlert()
        alert.messageText = "WhatCable \(update.version) is available"
        alert.informativeText = "You're on \(AppInfo.version). Open the release page to read the notes and download."
        alert.window.level = .floating
        let hasDownload = update.downloadURL != nil
        if hasDownload {
            alert.addButton(withTitle: "Update")
        }
        alert.addButton(withTitle: "View Release")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()

        NSApp.setActivationPolicy(originalPolicy)

        if hasDownload && response == .alertFirstButtonReturn {
            Installer.shared.install(update)
        } else if response == (hasDownload ? .alertSecondButtonReturn : .alertFirstButtonReturn) {
            NSWorkspace.shared.open(update.url)
        }
    }

    /// Compare dot-separated numeric versions. Non-numeric segments compare lexically.
    nonisolated static func isNewer(remote: String, current: String) -> Bool {
        AppInfo.isNewer(remote: remote, current: current)
    }

    /// Whether this copy is managed by a Homebrew cask.
    ///
    /// The layout is the opposite way round to the obvious guess, and the
    /// obvious guess shipped in the first draft of this feature. Homebrew's
    /// `app` artifact MOVES WhatCable.app into /Applications and leaves a
    /// symlink behind in the Caskroom pointing at it. So the running bundle
    /// resolves to /Applications/WhatCable.app and a "does my path contain
    /// Caskroom" test is false for every real cask install.
    ///
    /// Verified on a live cask install (v0.22.0):
    ///   /Applications/WhatCable.app                                 real directory
    ///   /opt/homebrew/Caskroom/whatcable/0.22.0/WhatCable.app  ->  /Applications/WhatCable.app
    ///
    /// So ask the question from the other end: does any Caskroom entry point
    /// at the bundle we are running from?
    ///
    /// Only used to decide whether to warn that `brew upgrade` can replace a
    /// beta with the current stable. Nothing about updating is blocked by it.
    static var isHomebrewInstall: Bool {
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        return caskroomAppLinks().contains { link in
            isSameBundle(caskLinkTarget: link, bundlePath: bundle)
        }
    }

    /// Every `WhatCable.app` entry Homebrew has under a Caskroom, across the
    /// prefixes a cask can live at: HOMEBREW_PREFIX if set, /opt/homebrew on
    /// Apple Silicon, /usr/local on Intel.
    private static func caskroomAppLinks() -> [URL] {
        var prefixes = ["/opt/homebrew", "/usr/local"]
        if let custom = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"], !custom.isEmpty {
            prefixes.insert(custom, at: 0)
        }
        let fm = FileManager.default
        var found: [URL] = []
        for prefix in prefixes {
            // <prefix>/Caskroom/whatcable/<version>/WhatCable.app
            let caskDir = URL(fileURLWithPath: prefix)
                .appendingPathComponent("Caskroom")
                .appendingPathComponent("whatcable")
            guard let versions = try? fm.contentsOfDirectory(
                at: caskDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for version in versions {
                found.append(version.appendingPathComponent("WhatCable.app"))
            }
        }
        return found
    }

    /// Pure comparison, so the rule is unit-tested without needing a real
    /// cask install on the test runner. A Caskroom entry identifies this copy
    /// when it resolves to the same bundle we are running from.
    nonisolated static func isSameBundle(caskLinkTarget: URL, bundlePath: String) -> Bool {
        caskLinkTarget.resolvingSymlinksInPath().path == bundlePath
    }

    /// Only accept download URLs from GitHub's release asset CDN.
    nonisolated static func isTrustedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme == "https",
              let host = url.host else { return false }
        let trusted = ["objects.githubusercontent.com", "github.com", "releases.githubusercontent.com"]
        return trusted.contains(host)
    }
}

