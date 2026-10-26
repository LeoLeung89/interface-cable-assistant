import Foundation

/// Whether a notification click should present the main surface right away,
/// or wait for the app to actually finish becoming active first.
///
/// The popover is `.transient`: it closes itself the moment it thinks focus
/// moved away. When the app isn't active yet, `NSApp.activate` kicks off an
/// asynchronous focus handover to WhatCable. Showing the popover before that
/// handover has actually completed means the tail end of the handover reads
/// as a click-away, and the transient popover closes itself again almost
/// instantly (the bug this type exists to fix). Deferring presentation to
/// `NSApplication.didBecomeActiveNotification` means the popover only opens
/// once the handover is genuinely done, so nothing still in flight can close
/// it out from under the click.
///
/// When the app is already active, there's no handover to wait for, so
/// presenting immediately is correct and is exactly today's behaviour. That
/// covers the status-item click path (the app is already frontmost there)
/// and a notification click that happens to arrive while WhatCable is
/// already the active app.
enum NotificationClickPresentation: Equatable {
    /// Present the main surface now, as before the fix.
    case presentNow
    /// Activate the app, then present once `didBecomeActiveNotification`
    /// confirms the activation actually landed.
    case activateThenPresentOnActivation

    /// Pure decision, kept separate from the observer plumbing so it's
    /// testable without `NSApplication` or `UNUserNotificationCenter`
    /// (neither is usable under `swift test`, which has no signed app
    /// bundle to run them in).
    static func decide(isAppActive: Bool) -> NotificationClickPresentation {
        isAppActive ? .presentNow : .activateThenPresentOnActivation
    }
}
