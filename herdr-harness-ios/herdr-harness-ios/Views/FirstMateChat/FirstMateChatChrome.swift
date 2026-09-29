import SwiftUI

/// Install once at a First Mate screen's root, not on its rows. Other tabs
/// deliberately keep HerdrBackground until the app-wide contrast sweep.
struct HerdrFirstMateChromeModifier: ViewModifier {
    @AppStorage(HerdrAppearancePreferences.glassKey) private var glass = HerdrAppearancePreferences.glassDefault
    @AppStorage(HerdrAppearancePreferences.hazeKey) private var haze = HerdrAppearancePreferences.hazeDefault
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var active: Bool {
        HerdrGlass.isActive(enabled: glass, reduceTransparency: reduceTransparency, colorScheme: .dark)
    }

    func body(content: Content) -> some View {
        content
            .dynamicTypeSize(...HerdrTheme.maximumDynamicTypeSize)
            .background {
                ZStack {
                    HerdrTheme.windowBackground
                    if active { HerdrDuskBackdrop() }
                }
                .ignoresSafeArea()
            }
            .environment(\.herdrGlassActive, active)
            .environment(\.herdrHazeActive, active && haze)
            .preferredColorScheme(.dark)
    }
}

extension View {
    func herdrFirstMateChrome() -> some View { modifier(HerdrFirstMateChromeModifier()) }
}
