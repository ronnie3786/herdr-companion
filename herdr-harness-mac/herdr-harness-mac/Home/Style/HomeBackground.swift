import SwiftUI

/// A controlled, opaque composite of the reference's dusk and 80% window tint.
/// Reduce Transparency uses the same readable surface without a material layer.
struct HomeBackground: View {
    @Environment(\.homeReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if reduceTransparency {
                LinearGradient(colors: [HomePalette.color(0x272230), HomePalette.color(0x191A25)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                HerdrDuskBackdrop(brightness: 1)
                HomePalette.base.opacity(0.8)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
