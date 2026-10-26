import XCTest
import AppKit
import SwiftUI
import WhatCableAppKit
import WhatCablePlugins
@testable import WhatCable

/// Window-mode sizing for the Pro screens and Settings (public issue #600).
///
/// Two failures this guards:
/// - Cropping: the window could be dragged shorter than the screen's own
///   minimum, hiding Back/Done and the title. In place, `ContentView`'s outer
///   `minHeight: 200` overrode every screen's larger minimum. Detached, an
///   explicit `NSWindow.minSize` set the floor 32pt (the title bar) below the
///   screen's declared one.
/// - Floating header: a screen shorter than a tall window was centred in it,
///   so its header sat mid-window. Detached Negotiation and Display could not
///   be made taller at all (`contentMaxSize` pinned to their fitting height).
///
/// The windows are shown (transparent) because `NSHostingController` only
/// applies its size constraints to a window that is on screen: measured, an
/// off-screen window reports `contentMinSize` 0x0 whatever the content says.
final class ProScreenWindowSizingTests: XCTestCase {

    /// Each screen's own declared SwiftUI minimum height, from its `.frame`.
    private struct Case {
        let id: String
        let minHeight: CGFloat
        let make: () -> AnyView
    }

    private let proScreens: [Case] = [
        Case(id: "pro.power-monitor", minHeight: 420) { AnyView(PowerMonitorWindow()) },
        Case(id: "pro.negotiation", minHeight: 440) { AnyView(NegotiationWindow()) },
        Case(id: "pro.display", minHeight: 440) { AnyView(DisplayWindow()) },
        Case(id: "pro.saved-cables", minHeight: 420) { AnyView(SavedCablesScreen()) },
    ]

    /// Pro Overview declares no minimum height, so it takes each window's
    /// general floor: 200 in place (the main window's), 520 x 420 detached.
    private let overview = Case(id: "pro.overview", minHeight: 200) { AnyView(ProOverviewScreen()) }
    private let detachedFloor: CGFloat = 420

    /// Tall enough to leave a visible gap above a centred screen, short
    /// enough that a 13-inch display's visible frame does not clamp it.
    private let tallHeight: CGFloat = 900

    /// The header must start within this many points of the top edge. Fixed
    /// layouts measure 10-15pt (header padding); the bug measured 200pt+.
    private let headerTopTolerance: CGFloat = 40

    // MARK: - In place (window mode)

    @MainActor
    func testInPlaceProScreensKeepTheirFloorAndPinTheHeader() {
        _ = NSApplication.shared
        withScratchAppSettingsDefaults {
            AppSettings.shared.useMenuBarMode = false
            for screen in proScreens + [overview] {
                registerIfMissing(screen)
                RefreshSignal.shared.activeProScreen = ProScreenRoute(id: screen.id)
                defer { RefreshSignal.shared.activeProScreen = nil }
                assertSizing(of: makeMainWindow(), name: "in place \(screen.id)", minHeight: screen.minHeight)
            }
        }
    }

    @MainActor
    func testInPlaceSettingsKeepsItsFloorAndPinsTheHeader() {
        _ = NSApplication.shared
        withScratchAppSettingsDefaults {
            AppSettings.shared.useMenuBarMode = false
            RefreshSignal.shared.showSettings = true
            defer { RefreshSignal.shared.showSettings = false }
            // SettingsView declares minHeight 320.
            assertSizing(of: makeMainWindow(), name: "in place Settings", minHeight: 320)
        }
    }

    // MARK: - Detached ("open in a separate window")

    @MainActor
    func testDetachedProScreensKeepTheirFloorGrowAndPinTheHeader() {
        _ = NSApplication.shared
        withScratchAppSettingsDefaults {
            for screen in proScreens + [overview] {
                let window = DetachedProWindowManager.makeWindow(for: screen.make(), title: screen.id)
                assertSizing(of: window, name: "detached \(screen.id)", minHeight: max(screen.minHeight, detachedFloor))
            }
        }
    }

    /// The detached floor grows with the Settings font slider, read when the
    /// window opens, so large text can't be squeezed into a 520 x 420 window.
    @MainActor
    func testDetachedFloorScalesWithFontSize() {
        _ = NSApplication.shared
        withScratchAppSettingsDefaults {
            AppSettings.shared.fontSize = 1.4
            defer { AppSettings.shared.fontSize = 1.0 }
            for screen in proScreens + [overview] {
                let window = DetachedProWindowManager.makeWindow(for: screen.make(), title: screen.id)
                window.isReleasedWhenClosed = false
                window.alphaValue = 0
                window.orderFrontRegardless()
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                XCTAssertGreaterThanOrEqual(window.contentMinSize.width, 520 * 1.4, "detached \(screen.id): min width at 1.4x")
                XCTAssertGreaterThanOrEqual(window.contentMinSize.height, 420 * 1.4, "detached \(screen.id): min height at 1.4x")
                window.close()
            }
        }
    }

    // MARK: - Helpers

    /// Same host as `AppDelegate.setUpWindowMode`.
    @MainActor
    private func makeMainWindow() -> NSWindow {
        let host = NSHostingController(
            rootView: ScaledHost {
                ContentView().environmentObject(RefreshSignal.shared)
            }
        )
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 540))
        return window
    }

    /// The tests build `ContentView` directly, so the plugin bootstrap has not
    /// run. Register the same builders `bootstrapPlugins` does, once.
    @MainActor
    private func registerIfMissing(_ screen: Case) {
        guard PluginRegistry.shared.proScreen(id: screen.id, portCard: nil) == nil else { return }
        PluginRegistry.shared.register(proScreen: screen.id) { _ in screen.make() }
    }

    @MainActor
    private func assertSizing(of window: NSWindow, name: String, minHeight: CGFloat,
                              file: StaticString = #filePath, line: UInt = #line) {
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.orderFrontRegardless()
        defer { window.close() }
        // Let the hosting controller push its constraints to the window.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        XCTAssertGreaterThanOrEqual(
            window.contentMinSize.height, minHeight,
            "\(name): window can shrink to \(window.contentMinSize.height)pt, below the screen's own \(minHeight)pt minimum",
            file: file, line: line
        )
        XCTAssertGreaterThan(
            window.contentMaxSize.height, tallHeight,
            "\(name): window cannot grow past \(window.contentMaxSize.height)pt",
            file: file, line: line
        )

        window.setContentSize(NSSize(width: 760, height: tallHeight))
        window.layoutIfNeeded()
        guard let view = window.contentView else {
            return XCTFail("\(name): window has no content view", file: file, line: line)
        }
        let top = firstContentRowFromTop(of: view) / window.backingScaleFactor
        // Row 0 would mean the corner sample landed on content, so the scan
        // proved nothing about where the header is.
        XCTAssertGreaterThan(top, 0, "\(name): background sample hit content", file: file, line: line)
        XCTAssertLessThan(
            top, headerTopTolerance,
            "\(name): header starts \(top)pt below the top edge of a \(tallHeight)pt window",
            file: file, line: line
        )
    }

    /// Renders the view and returns the first pixel row, counted from the
    /// top, that has anything other than the background colour (sampled at
    /// the top-left corner, which the header's padding leaves empty).
    @MainActor
    private func firstContentRowFromTop(of view: NSView) -> CGFloat {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return .infinity }
        view.cacheDisplay(in: view.bounds, to: rep)
        let background = rep.colorAt(x: 2, y: 2)
        for y in 0..<rep.pixelsHigh {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) where rep.colorAt(x: x, y: y) != background {
                return CGFloat(y)
            }
        }
        return CGFloat(rep.pixelsHigh)
    }
}
