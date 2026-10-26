import Foundation

/// One notification category per event type (issue #567). Posting with
/// the same identifier replaces the previous notification in place
/// (Apple's sanctioned "one standing notification per topic" pattern),
/// so a second device event doesn't leave two separate banners sitting
/// in Notification Centre. Charger and device events use distinct
/// identifiers so one never replaces the other.
public enum NotificationCategory: String, Equatable, Hashable {
    case device = "device-event"
    case charger = "charger-event"
}
