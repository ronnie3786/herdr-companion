import SwiftUI

struct GlassCard<Content: View>: View {
    let radius: Double
    @ViewBuilder let content: Content

    init(radius: Double = HerdrTheme.cardRadius, @ViewBuilder content: () -> Content) {
        self.radius = radius
        self.content = content()
    }

    var body: some View {
        content.herdrCard(radius: CGFloat(radius))
    }
}
