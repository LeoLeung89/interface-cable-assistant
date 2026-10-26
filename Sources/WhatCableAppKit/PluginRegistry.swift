import SwiftUI
import AppKit
import Combine
import WhatCableNotifications

@MainActor
public final class PluginRegistry {
    public static let shared = PluginRegistry()
    private init() {}

    public private(set) var launchHooks: [() async -> Void] = []
    public func register(launchHook: @escaping () async -> Void) {
        launchHooks.append(launchHook)
    }

    public private(set) var menuItems: [MenuPlacement: [PluginMenuItem]] = [:]
    public func register(menuItem: PluginMenuItem, at placement: MenuPlacement) {
        menuItems[placement, default: []].append(menuItem)
    }

    public private(set) var nsMenuItemBuilders: [MenuPlacement: [() -> NSMenuItem]] = [:]
    public func register(nsMenuItemBuilder: @escaping () -> NSMenuItem, at placement: MenuPlacement) {
        nsMenuItemBuilders[placement, default: []].append(nsMenuItemBuilder)
    }

    public private(set) var headerButtonBuilders: [() -> AnyView] = []
    public func register(headerButton: @escaping () -> AnyView) {
        headerButtonBuilders.append(headerButton)
    }

    public private(set) var footerButtonBuilders: [() -> AnyView] = []
    public func register(footerButton: @escaping () -> AnyView) {
        footerButtonBuilders.append(footerButton)
    }

    public private(set) var portCardTrailingBuilders: [(PortCardContext) -> AnyView?] = []
    public func register(portCardTrailing: @escaping (PortCardContext) -> AnyView?) {
        portCardTrailingBuilders.append(portCardTrailing)
    }

    public private(set) var widgetDataContributors: [any WidgetDataContributor] = []
    public func register(widgetDataContributor: any WidgetDataContributor) {
        widgetDataContributors.append(widgetDataContributor)
    }

    public private(set) var cliCommands: [CLICommand] = []
    public func register(cliCommand: CLICommand) {
        cliCommands.append(cliCommand)
    }

    /// Contributors that append a footer line to one-shot CLI text output.
    /// Each returns nil when it has nothing to say (e.g. when the user has
    /// already unlocked Pro). The CLI calls these only for plain text mode,
    /// not for --json / --watch / --report, where extra lines would break
    /// scripts or re-render every tick.
    public private(set) var cliOutputFooterContributors: [() -> String?] = []
    public func register(cliOutputFooter: @escaping () -> String?) {
        cliOutputFooterContributors.append(cliOutputFooter)
    }

    /// Snapshot providers for the saved-cable feed: which saved cables are
    /// CURRENTLY attached and uniquely attributed, plus whether the user
    /// has any saved cable at all. `DeviceDiffSequencer` (via the app-side
    /// shim) reads this on every PD identity publish to decide whether a
    /// labelled cable connecting or disconnecting should be named in a
    /// notification title (issue #570 part B). Mirrors
    /// `cliOutputFooterContributors`: a plain snapshot-returning closure, no
    /// async, called fresh at read time (no caching here). At most one Pro
    /// provider registers; the public-mirror stub registers none, so the
    /// shim's fold over an empty array yields `nil` there (feature
    /// unavailable), same as the free build with Pro locked.
    ///
    /// `CableLabelFeed?`, not a bare `[String: String]?` (post-review fix):
    /// `nil` means "the feature is unavailable right now" (Pro locked, or
    /// nothing registered), unchanged. But whether the attached map being
    /// EMPTY means "nothing saved anywhere" vs "something's saved, just not
    /// attached right now" can no longer be inferred from the map alone
    /// (that inference broke the feature's own flagship case: a user with
    /// exactly one saved cable, currently unplugged, has an empty attached
    /// map right up until that cable's e-marker resolves). `hasSavedCables`
    /// is the provider's own, separate answer to that question. See
    /// `WhatCableNotifications.NotificationDecision.CableLabelFeed`'s doc
    /// comment for the full story.
    public private(set) var notificationCableLabelProviders: [() -> NotificationDecision.CableLabelFeed?] = []
    public func register(notificationCableLabelProvider: @escaping () -> NotificationDecision.CableLabelFeed?) {
        notificationCableLabelProviders.append(notificationCableLabelProvider)
    }

    /// Fires whenever a registered notification cable-label provider's
    /// underlying gate state changes IN-APP (fix 4: `LicenceManager.activate`,
    /// `deactivate`, and `clearLicence`, wired by `bootstrapPlugins`), so
    /// the app-side notification shim can re-push the folded feed
    /// immediately rather than waiting for the next unrelated `WatcherHub`
    /// tick or PD identity publish. Mirrors `widgetDataContributors`'s
    /// registry shape (a plain array, appended at registration time, read
    /// once by the shim when it wires its subscriptions in
    /// `NotificationManager.start()` -- same ordering requirement as
    /// `widgetDataContributors`: registration must happen before whatever
    /// reads the array). `AnyPublisher<Void, Never>`, not the concrete
    /// `PassthroughSubject` type, so this seam carries no `WhatCablePlugins`
    /// / `LicenceManager` symbol into `WhatCableAppKit`, which both the app
    /// target and the public-mirror stub build depend on. The public-mirror
    /// stub's `bootstrapPlugins` registers nothing, so this array stays
    /// empty there and the shim's subscription loop over it is a no-op.
    public private(set) var notificationCableLabelChangeSignals: [AnyPublisher<Void, Never>] = []
    public func register(notificationCableLabelChangeSignal: AnyPublisher<Void, Never>) {
        notificationCableLabelChangeSignals.append(notificationCableLabelChangeSignal)
    }

    public private(set) var settingsProSectionBuilders: [() -> AnyView] = []
    public func register(settingsProSection: @escaping () -> AnyView) {
        settingsProSectionBuilders.append(settingsProSection)
    }

    /// Full-surface Pro screens, keyed by id. Rendered in place of the
    /// main content (a drill-down, like Settings), not in a separate
    /// window. The optional `PortCardContext` is supplied for screens
    /// scoped to one port (Cable Diagnostics); global screens ignore it.
    public typealias ProScreenBuilder = (PortCardContext?) -> AnyView
    public private(set) var proScreenBuilders: [String: ProScreenBuilder] = [:]
    public func register(proScreen id: String, builder: @escaping ProScreenBuilder) {
        if proScreenBuilders[id] != nil {
            assertionFailure("PluginRegistry: pro screen '\(id)' is already registered")
        }
        proScreenBuilders[id] = builder
    }
    public func proScreen(id: String, portCard: PortCardContext?) -> AnyView? {
        proScreenBuilders[id].map { $0(portCard) }
    }
}
