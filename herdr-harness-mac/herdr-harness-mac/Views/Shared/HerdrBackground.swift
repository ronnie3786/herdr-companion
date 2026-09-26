import SwiftUI

/// The opaque page background. Main-window screens pass `followsGlass` so the
/// shell's pane glass shows through them; sheets and other windows stay opaque.
struct HerdrBackground: View {
    var followsGlass = false
    @Environment(\.herdrGlassActive) private var glassActive

    var body: some View {
        (followsGlass && glassActive ? Color.clear : HerdrTheme.windowBackground)
            .ignoresSafeArea()
    }
}
