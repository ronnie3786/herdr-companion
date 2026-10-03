import SwiftUI

/// Matches the standalone window's native material, dusk opacity, pane and haze.
/// Existing appearance and Reduce Transparency preferences remain authoritative.
struct FirstMateArchiveSurface: ViewModifier {
    @Environment(\.herdrGlassActive) private var glass
    @Environment(\.herdrDesktopGlassActive) private var desktopGlass

    func body(content: Content) -> some View {
        content
            .background(alignment: .top) { HerdrHazeBand() }
            .background { HerdrGlassBackground(level: HerdrTheme.Glass.pane) }
            .background {
                if glass {
                    ZStack {
                        if desktopGlass {
                            HerdrDesktopMaterial()
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                        HerdrDuskBackdrop()
                            .opacity(desktopGlass ? HerdrGlass.desktopDuskOpacity() : 1)
                    }
                }
            }
            .presentationBackground(.clear)
            .foregroundStyle(HerdrTheme.text)
            .tint(HerdrTheme.accent)
    }
}
