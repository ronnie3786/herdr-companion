import SwiftUI

/// An inspector tab's heading, as on the Mac: a semibold title and one
/// quiet line of context under it.
struct FirstMateInspectorHeading<Accessory: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 12) {
                Text(title).herdrFont(size: 20, weight: .semibold, relativeTo: .title3).foregroundStyle(HerdrTheme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity, alignment: .leading)
                accessory
            }
            if let detail {
                Text(detail).herdrFont(.subheadline).foregroundStyle(HerdrTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension FirstMateInspectorHeading where Accessory == EmptyView {
    init(title: String, detail: String? = nil) {
        self.init(title: title, detail: detail) { EmptyView() }
    }
}
