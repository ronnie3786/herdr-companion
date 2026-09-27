import AppKit
import SwiftUI

/// The main window's MonoCode frame: a transparent 40pt title bar whose
/// traffic lights sit 12pt from the left edge, centered in the bar.
///
/// An empty `NSToolbar` in `.unifiedCompact` style is what gives AppKit a 40pt
/// title bar on macOS 26 (measured: no toolbar 32pt, `.expanded` 48pt,
/// `.unified` 66pt), so the window buttons line up with Herdr's own 40pt bars
/// without moving them by hand. The toolbar never has items; SwiftUI draws the
/// bar's content (`HerdrTitleBar`) under the transparent title bar.
struct HerdrWindowChrome: NSViewRepresentable {
    /// Height of the compact title bar the toolbar produces.
    static let titleBarHeight: CGFloat = HerdrTheme.ControlHeight.titleBar
    /// Where content may start to the right of the traffic lights.
    static let trafficLightInset: CGFloat = 80

    @Binding var isFullScreen: Bool

    func makeNSView(context: Context) -> ChromeView {
        let view = ChromeView()
        view.onFullScreenChange = { value in
            if isFullScreen != value { isFullScreen = value }
        }
        return view
    }

    func updateNSView(_ view: ChromeView, context: Context) {
        view.onFullScreenChange = { value in
            if isFullScreen != value { isFullScreen = value }
        }
        view.applyChrome()
    }

    final class ChromeView: NSView {
        static let toolbarIdentifier = NSToolbar.Identifier("herdr.main.chrome")
        var onFullScreenChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            applyChrome()
            let center = NotificationCenter.default
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reportFullScreen() }
                })
            }
            reportFullScreen()
        }

        func applyChrome() {
            guard let window else { return }
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
            if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
            if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
            if window.toolbar?.identifier != Self.toolbarIdentifier {
                let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
                toolbar.allowsUserCustomization = false
                toolbar.displayMode = .iconOnly
                window.toolbar = toolbar
            }
            if window.toolbarStyle != .unifiedCompact { window.toolbarStyle = .unifiedCompact }
        }

        private func reportFullScreen() {
            onFullScreenChange?(window?.styleMask.contains(.fullScreen) ?? false)
        }

    }
}

private struct HerdrWindowFullScreenKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while the main window is in full screen, where the traffic lights
    /// are hidden and bars can start at their normal padding.
    var herdrWindowIsFullScreen: Bool {
        get { self[HerdrWindowFullScreenKey.self] }
        set { self[HerdrWindowFullScreenKey.self] = newValue }
    }
}

/// Installs `HerdrWindowChrome` on the main window and publishes whether it is
/// in full screen to every bar below it.
struct HerdrMainWindowChromeModifier: ViewModifier {
    /// The window's opaque background while glass is off.
    var background: Color = HerdrTheme.windowBackground
    @State private var isFullScreen = false
    @AppStorage(HerdrAppearancePreferences.glassEnabledKey) private var glassEnabled = HerdrAppearancePreferences.defaultGlassEnabled
    @AppStorage(HerdrAppearancePreferences.hazeEnabledKey) private var hazeEnabled = HerdrAppearancePreferences.defaultHazeEnabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let glass = HerdrGlass.isActive(enabled: glassEnabled, reduceTransparency: reduceTransparency, colorScheme: colorScheme)
        content
            // The shell draws its own 40pt bars at the top edge; nothing below
            // them should treat the transparent title bar as a safe area.
            .ignoresSafeArea(.container, edges: .top)
            .environment(\.herdrWindowIsFullScreen, isFullScreen)
            .environment(\.herdrGlassActive, glass)
            .environment(\.herdrHazeActive, glass && hazeEnabled)
            // One dusk behind both columns; their glass levels sit over it.
            .background {
                Group {
                    if glass { HerdrDuskBackdrop() } else { background }
                }
                .ignoresSafeArea()
            }
            .background { HerdrWindowChrome(isFullScreen: $isFullScreen) }
    }
}
