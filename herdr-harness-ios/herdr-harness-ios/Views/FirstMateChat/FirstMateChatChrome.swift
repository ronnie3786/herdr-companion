import SwiftUI

extension EnvironmentValues {
    /// Child chrome inherits the app's cached artwork. UIKit navigation and
    /// modal containers also install that same artwork on their own surface.
    @Entry var herdrDuskInstalled = false
}

struct HerdrAppChromeModifier: ViewModifier {
    var separateSurface = false
    @AppStorage(HerdrAppearancePreferences.glassKey) private var glass = HerdrAppearancePreferences.glassDefault
    @AppStorage(HerdrAppearancePreferences.hazeKey) private var haze = HerdrAppearancePreferences.hazeDefault
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.herdrDuskInstalled) private var installed

    private var active: Bool {
        HerdrGlass.isActive(enabled: glass, reduceTransparency: reduceTransparency, colorScheme: .dark)
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                #if DEBUG
                if (!installed || separateSurface), ProcessInfo.processInfo.arguments.contains("-HerdrAppAppearanceProbe") {
                    HerdrAppAppearanceProbe()
                }
                #endif
            }
            .containerBackground(for: .navigation) { HerdrAppBackdrop(active: active) }
            .containerBackground(for: .navigationSplitView) { HerdrAppBackdrop(active: active) }
            .herdrNavigationBarChrome()
            .dynamicTypeSize(...HerdrTheme.maximumDynamicTypeSize)
            .background {
                if !installed || separateSurface {
                    HerdrAppBackdrop(active: active).ignoresSafeArea()
                }
            }
            .environment(\.herdrGlassActive, active)
            .environment(\.herdrHazeActive, active && haze)
            .environment(\.herdrDuskInstalled, true)
            .foregroundStyle(HerdrTheme.primaryText, HerdrTheme.secondaryText, HerdrTheme.tertiaryText)
            .preferredColorScheme(.dark)
            .tint(HerdrTheme.accent)
    }
}

/// Reuses the one cached bitmap for surfaces UIKit composites independently.
struct HerdrAppBackdrop: View {
    let active: Bool
    var body: some View {
        ZStack {
            HerdrTheme.windowBackground
            if active { HerdrDuskBackdrop() }
        }
    }
}

private struct HerdrNavigationBarChromeModifier: ViewModifier {
    @Environment(\.herdrGlassActive) private var glass
    func body(content: Content) -> some View {
        content
            .toolbarBackground(
                HerdrGlass.darkened(HerdrTheme.railBackground, scheme: .dark)
                    .opacity(glass ? HerdrTheme.Glass.sidebar : 1), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

extension View {
    /// Apply to the navigation content so UIKit installs the readable bar fill.
    func herdrNavigationBarChrome() -> some View { modifier(HerdrNavigationBarChromeModifier()) }
    func herdrAppChrome(separateSurface: Bool = false) -> some View {
        modifier(HerdrAppChromeModifier(separateSurface: separateSurface))
    }
    func herdrFirstMateChrome() -> some View { herdrAppChrome() }
}

#if DEBUG
private struct HerdrAppAppearanceProbe: View {
    @Environment(\.dynamicTypeSize) private var size
    var body: some View {
        Text("Text size: \(String(describing: size))")
            .font(.system(size: 1)).foregroundStyle(.clear).frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityIdentifier("app-text-size-probe")
    }
}
#endif
