import SwiftUI

/// An icon and title on one baseline with an explicit gap.
struct HerdrInlineLabelStyle: LabelStyle {
    var spacing: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: spacing) {
            configuration.icon
            configuration.title
        }
    }
}
