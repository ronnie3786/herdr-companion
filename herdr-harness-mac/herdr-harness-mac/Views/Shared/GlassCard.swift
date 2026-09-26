import SwiftUI

/// A MonoCode card: 3% ink in a 12pt rounded rectangle with a 10% outline.
/// Content is clipped to the card so inset rows and dividers stay inside it.
struct GlassCard<Content: View>: View {
    let radius: Double
    @ViewBuilder let content: Content

    init(radius: Double = HerdrTheme.cardRadius, @ViewBuilder content: () -> Content) {
        self.radius = radius
        self.content = content()
    }

    var body: some View {
        content
            .background(HerdrTheme.cardFill)
            .clipShape(.rect(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(HerdrTheme.outline, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}
