import AppKit
import SwiftUI
import Combine

// MARK: - Font scaling environment
//
// Lives in WhatCableAppKit so every SwiftUI surface (popover ContentView,
// Settings, Pro screens hosted by plugins, detached Pro windows, the welcome
// window, the licence panel) shares the same `\.fontScale` environment key
// and the same `.scaledFont(...)` modifier.
//
// Wrap each NSHostingController's rootView in `ScaledHost { ... }` so the
// view tree re-evaluates `\.fontScale` whenever the Settings slider moves,
// not just at the moment the window was opened.

public struct FontScaleKey: EnvironmentKey {
    public static let defaultValue: Double = 1.0
}

extension EnvironmentValues {
    public var fontScale: Double {
        get { self[FontScaleKey.self] }
        set { self[FontScaleKey.self] = newValue }
    }
}

/// Single source of truth for the current font scale, observed by
/// `ScaledHost`. The app target keeps this in sync with
/// `AppSettings.shared.fontSize`; AppKit + plugins observe it without
/// needing to know about the app target.
@MainActor
public final class FontScaleStore: ObservableObject {
    public static let shared = FontScaleStore()
    @Published public var fontScale: Double = 1.0
    private init() {}
}

/// Single source of truth for the window-opacity slider, observed by
/// `ScaledHost`. 1.0 is fully opaque (the default); lower values make every
/// surface see-through. The app target keeps this in sync with
/// `AppSettings.shared.uiOpacity`.
@MainActor
public final class OpacityStore: ObservableObject {
    public static let shared = OpacityStore()
    @Published public var opacity: Double = 1.0
    private init() {}
}

/// Sets the host window's `alphaValue` so the whole surface (popover, window,
/// detached Pro window, sheet, etc.) goes translucent. Lives in a `.background`
/// of `ScaledHost`, so it rides along on every surface without touching any
/// window-construction call site.
///
/// We fade the whole window rather than just its background: macOS vibrancy
/// (the popover's frosted backdrop) has no 0-100% knob, and making the window
/// non-opaque doesn't reveal the desktop because the popover draws its own
/// backdrop inside the window. Whole-window alpha is the one approach that
/// visibly works on the popover.
///
/// `NSViewRepresentable` is the bridge that lets a SwiftUI view reach the
/// underlying AppKit window, which is where `alphaValue` actually lives;
/// SwiftUI has no native "set my window's opacity" modifier.
private struct WindowAlphaApplier: NSViewRepresentable {
    var opacity: Double

    func makeNSView(context: Context) -> WindowAlphaView {
        let view = WindowAlphaView()
        view.alpha = opacity
        return view
    }

    func updateNSView(_ nsView: WindowAlphaView, context: Context) {
        nsView.alpha = opacity
    }
}

/// Backing view for `WindowAlphaApplier`. Applies the alpha both when the
/// value changes and when it first joins a window: the popover's backing
/// window doesn't exist until the popover is shown, and re-shows re-add the
/// hosting view, so `viewDidMoveToWindow` is the reliable hook.
private final class WindowAlphaView: NSView {
    var alpha: Double = 1.0 {
        didSet { applyAlpha() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyAlpha()
    }

    private func applyAlpha() {
        // Clamp defensively: alphaValue is only meaningful in 0...1, and the
        // store is public so a stray writer can't make a window vanish.
        window?.alphaValue = CGFloat(min(max(alpha, 0), 1))
    }
}

/// Wraps any view, observing `FontScaleStore.shared` and `OpacityStore.shared`
/// and re-applying the `\.fontScale` environment and window opacity whenever
/// the Settings sliders change.
///
/// Use at the root of every SwiftUI surface that is hosted in its own
/// `NSHostingController` (popover, detached Pro windows, welcome, licence
/// panel) and on each `.sheet` body (sheets are separate child windows that
/// the parent's wrapper doesn't cover). Without this wrapper those hosts read
/// the defaults (scale 1.0, opacity 1.0) and ignore the sliders entirely.
public struct ScaledHost<Content: View>: View {
    @ObservedObject private var store = FontScaleStore.shared
    @ObservedObject private var opacityStore = OpacityStore.shared
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .environment(\.fontScale, store.fontScale)
            .background(WindowAlphaApplier(opacity: opacityStore.opacity))
    }
}

/// Reads the `fontScale` environment and applies a scaled system font.
///
/// Use `.scaledFont(.caption)` instead of `.font(.caption)` on any text that
/// should respond to the slider. Use `.scaledFont(size: 38, ...)` when the
/// design calls for a literal point size (hero readouts, etc.) so the size
/// still tracks the slider. Chart axis labels and other chrome that looks
/// noisy when scaled can keep raw `.font(...)`.
public struct ScaledFontModifier: ViewModifier {
    @Environment(\.fontScale) private var scale
    let style: Font.TextStyle?
    let literalSize: Double?
    let design: Font.Design?
    let weight: Font.Weight?
    let monospacedDigit: Bool

    init(
        style: Font.TextStyle? = nil,
        literalSize: Double? = nil,
        design: Font.Design? = nil,
        weight: Font.Weight? = nil,
        monospacedDigit: Bool = false
    ) {
        self.style = style
        self.literalSize = literalSize
        self.design = design
        self.weight = weight
        self.monospacedDigit = monospacedDigit
    }

    public func body(content: Content) -> some View {
        let baseSize: Double
        if let literalSize {
            baseSize = literalSize
        } else if let style {
            baseSize = Self.baseSize(for: style)
        } else {
            baseSize = Self.baseSize(for: .body)
        }
        let size = baseSize * scale
        var font: Font = design != nil
            ? .system(size: size, design: design!)
            : .system(size: size)
        if let weight { font = font.weight(weight) }
        if monospacedDigit { font = font.monospacedDigit() }
        return content.font(font)
    }

    /// Approximate macOS system font sizes per text style. Matches the values
    /// SwiftUI picks for the default `.font(.x)` modifier on macOS 14+.
    public static func baseSize(for style: Font.TextStyle) -> Double {
        switch style {
        case .largeTitle: return 26
        case .title: return 22
        case .title2: return 17
        case .title3: return 15
        case .headline: return 13
        case .body: return 13
        case .callout: return 12
        case .subheadline: return 11
        case .footnote: return 10
        case .caption: return 10
        case .caption2: return 9
        @unknown default: return 13
        }
    }
}

extension View {
    /// Scale a text-style font with the `\.fontScale` environment.
    public func scaledFont(
        _ style: Font.TextStyle,
        design: Font.Design? = nil,
        weight: Font.Weight? = nil,
        monospacedDigit: Bool = false
    ) -> some View {
        modifier(ScaledFontModifier(
            style: style,
            design: design,
            weight: weight,
            monospacedDigit: monospacedDigit
        ))
    }

    /// Scale a literal point size with the `\.fontScale` environment. Use for
    /// hero readouts where the design calls for a specific size rather than a
    /// text style. Chart axis labels and other chrome should keep raw
    /// `.font(.system(size:))` instead.
    public func scaledFont(
        size: Double,
        design: Font.Design? = nil,
        weight: Font.Weight? = nil,
        monospacedDigit: Bool = false
    ) -> some View {
        modifier(ScaledFontModifier(
            literalSize: size,
            design: design,
            weight: weight,
            monospacedDigit: monospacedDigit
        ))
    }
}
