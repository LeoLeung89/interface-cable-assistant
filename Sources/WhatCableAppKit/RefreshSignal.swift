import Combine
import CoreGraphics

public final class RefreshSignal: ObservableObject {
    /// Single shared instance. The app injects this into `ContentView`
    /// (both popover and desktop modes) and plugins reach it directly so
    /// menu items and header buttons can drive in-app navigation without
    /// referencing the app target.
    public static let shared = RefreshSignal()

    @Published public var tick: Int = 0
    @Published public var optionHeld: Bool = false
    @Published public var showSettings: Bool = false
    @Published public var showTestKitConsent: Bool = false

    /// When set, `ContentView` shows the named Pro screen in place of the
    /// main content (a drill-down, like Settings), instead of opening a
    /// separate window. `nil` returns to the main content.
    @Published public var activeProScreen: ProScreenRoute? = nil

    /// Keep the menu-bar popover open (non-transient). Mirrors the
    /// right-click "Keep window open" toggle and is also surfaced as a UI
    /// button. Session-only; no effect in desktop window mode.
    @Published public var keepOpen: Bool = false

    /// Height cap for the menu-bar popover, in points. The app recomputes this
    /// from the display the status item is on each time the popover opens, so a
    /// tall panel can't grow past the screen and shove its own header (with the
    /// settings gear) up behind the menu bar out of reach (issue #454). Seeded
    /// to the historic 760 cap; only ever shrunk below that on a screen too
    /// short to fit it. No effect in desktop window mode.
    @Published public var maxPopoverHeight: CGFloat = 760

    public init() {}

    public func bump() { tick &+= 1 }
}

/// Identifies which Pro screen to show, plus optional per-port context
/// for screens that are scoped to a single port (Cable Diagnostics).
public struct ProScreenRoute {
    public let id: String
    public let portCard: PortCardContext?

    public init(id: String, portCard: PortCardContext? = nil) {
        self.id = id
        self.portCard = portCard
    }
}
