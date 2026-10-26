import SwiftUI

/// Shared motion vocabulary for the settling card (spec: "settling-card",
/// "Motion"): one definition point for entrance, exit, and reveal, so every
/// place that animates a port card in, out, or from placeholder to body
/// agrees on duration and easing rather than each call site picking its own.
///
/// Duration matches the app's one existing animation idiom
/// (`withAnimation(.linear(duration: 0.35))`, the refresh-icon spin in
/// `ContentView.body`). Cards use `.easeInOut` rather than `.linear`: a card
/// sliding or fading into place reads better with easing than a spinning
/// icon does, where linear is the point.
///
/// Explicit, narrowly scoped transactions only: callers wrap the specific
/// state mutation that should animate (the loading -> body replacement, a
/// parent `ForEach` insertion/removal) in `withAnimation(CardMotion
/// .animation(reduceMotion:))`. Nothing here is a `.animation(_, value:)`
/// modifier attached to a watcher-driven value, which the spec explicitly
/// rules out (an unscoped `.animation` would animate every future update to
/// that value, not just the one transition it's meant for).
enum CardMotion {
    /// Shared duration for every card motion (entrance, exit, reveal).
    static let duration: Double = 0.35

    /// The `.fading` watchdog's fallback interval (per-branch-review
    /// addendum, round 2, finding 4): if `SettlingPortCardHost`'s normal
    /// `withAnimation` completion handler never delivers `fadeCompleted`
    /// (Core Animation dropping a completion for an off-screen view is a
    /// real category of platform flakiness, and the popover's
    /// `NSHostingController` is never torn down on close/reopen), this is
    /// how long the watchdog waits before firing it itself. `duration * 2`
    /// gives the real animation a full cycle of slack beyond its own
    /// length before assuming it's stuck, plus a small margin so the
    /// watchdog is never a hair-trigger race against a legitimately slow
    /// but still-completing animation.
    static let fadeWatchdogInterval: Double = duration * 2 + 0.1

    /// The animation curve for a card's entrance, exit, or the internal
    /// loading -> body reveal.
    static var animation: Animation {
        .easeInOut(duration: duration)
    }

    /// Reduce Motion still animates (an instant cut reads as a glitch), but
    /// drops the easing curve in favour of a flat linear fade: only opacity
    /// changes under Reduce Motion (see `entrance`/`exit`/`reveal` below),
    /// and a linear opacity ramp is the least motion-heavy way to present one.
    static var reduceMotionAnimation: Animation {
        .linear(duration: duration)
    }

    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? reduceMotionAnimation : animation
    }

    /// A parent-owned `ForEach` insertion (a card entering `visiblePorts`)
    /// or removal (dropping out via "Hide empty ports", spec: "Parent-owned
    /// retention and removal"). Normally a fade combined with a slight
    /// vertical move, so a card reads as arriving/leaving rather than a hard
    /// cut. Reduce Motion collapses this to opacity only.
    static func entrance(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }

    /// Same shape as `entrance`, for the parent's `ForEach` removal and for
    /// the card's own internal exit before `.retained`.
    static func exit(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }

    /// The internal loading -> body reveal (and the later fading -> retained
    /// swap). Deliberately opacity-only even without Reduce Motion: the
    /// card's own size changes here (a small spinner placeholder becomes the
    /// full body), and combining that with a slide reads as a jump rather
    /// than the "one smooth animated transition" the spec asks for.
    static func reveal(reduceMotion: Bool) -> AnyTransition {
        .opacity
    }
}
