import SwiftUI

struct SettingsPageHeader: View {
    let pane: SettingsPane

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(pane.title)
                .herdrFont(size: SettingsDesign.pageTitle, weight: .semibold)
                .accessibilityAddTraits(.isHeader)
            Text(pane.subtitle)
                .herdrFont(.callout)
                .foregroundStyle(HerdrTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SettingsDesign.pageInset)
        .padding(.top, 24)
        .padding(.bottom, 18)
    }
}
