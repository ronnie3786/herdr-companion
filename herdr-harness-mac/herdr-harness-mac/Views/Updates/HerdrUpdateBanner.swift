import SwiftUI

struct HerdrUpdateBanner: View {
    let version: String
    let updates: HerdrUpdateController

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .herdrFont(size: HerdrTheme.TextSize.reading)
                .foregroundStyle(HerdrTheme.accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Herdr \(version) is available")
                    .herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
                    .foregroundStyle(HerdrTheme.text)
                Text("Review what’s new and choose when to install.")
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(HerdrTheme.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)

            Spacer(minLength: 12)

            Button("Later") {
                updates.dismissBanner()
            }
            .buttonStyle(HerdrButtonStyle(kind: .outline))
            .accessibilityLabel("Dismiss update banner")
            .accessibilityIdentifier("update-banner-later")

            Button("Review update…") {
                updates.checkForUpdates()
            }
            .buttonStyle(HerdrButtonStyle(kind: .primary))
            .disabled(!updates.canCheckForUpdates)
            .accessibilityIdentifier("update-banner-review")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(HerdrTheme.cardFill)
        .herdrHairline(.bottom)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("update-banner")
    }
}
