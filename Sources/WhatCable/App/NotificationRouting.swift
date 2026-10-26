import Foundation

/// What clicking a WhatCable notification should do. Kept as an enum
/// rather than folding the behaviour straight into the delegate, so the
/// identifier -> action mapping is unit-testable without
/// `UNUserNotificationCenter`, which is unavailable under `swift test`
/// (no signed app bundle to run it in).
enum NotificationClickAction: Equatable {
    /// Bring the popover (or window, in desktop mode) forward as-is.
    case openPopover
    /// Same, but also clear any Settings/Pro-screen overlay first, so the
    /// main content (where the update banner lives) is what's on screen.
    case openPopoverShowingUpdate
}

/// Pure identifier -> action mapping (issue #567). `NotificationManager`
/// posts device/charger events under `<category>-<launch token>-<sequence>`
/// (e.g. `device-event-4f2a-3`), a fresh identifier per post so macOS never
/// treats a new post as silently replacing an old one; `UpdateChecker`
/// posts update notifications under `update-<version>`. Anything else (a
/// stale identifier from an older build, say a bare `device-event` or
/// `charger-event`, or an unrecognised one) falls back to just opening the
/// popover: this routing only ever special-cases the `update-` prefix, so
/// it doesn't need to know the device/charger scheme's exact shape at all.
enum NotificationRouting {
    static func action(for identifier: String) -> NotificationClickAction {
        identifier.hasPrefix("update-") ? .openPopoverShowingUpdate : .openPopover
    }
}
