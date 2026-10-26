import Foundation

/// A single notification's content (title, subtitle, body), decided independently of
/// `UNUserNotificationCenter` so the merge decision below is testable
/// without posting anything. See issue #556.
public struct NotificationContent: Equatable {
    public let title: String
    /// The saved-cable name, verbatim, when one applies to this post; empty
    /// otherwise. macOS notification titles are a single line with no wrap,
    /// so a long cable name used to truncate the title. The subtitle slot
    /// sits on its own line and was unused, so the name moved there instead
    /// (issue #570).
    public let subtitle: String
    public let body: String

    public init(title: String, subtitle: String = "", body: String) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
    }
}
