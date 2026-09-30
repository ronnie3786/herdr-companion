import SwiftUI

/// Pane fill over the app's shared cached dusk. Standalone previews and sheets
/// retain a complete readable background without adding effects to their rows.
struct HerdrBackground: View {
    @Environment(\.herdrDuskInstalled) private var installed
    @Environment(\.herdrGlassActive) private var glass
    var body: some View {
        Group {
            if installed {
                HerdrGlassBackground(level: HerdrTheme.Glass.pane)
            } else {
                HerdrGlassBackground(level: HerdrTheme.Glass.pane).herdrAppChrome()
            }
        }
        .containerBackground(for: .navigation) { HerdrAppBackdrop(active: glass) }
        .containerBackground(for: .navigationSplitView) { HerdrAppBackdrop(active: glass) }
        .ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}
