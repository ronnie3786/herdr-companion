import SwiftUI

struct HerdrUpdateBanner: View {
    let version: String
    let updates: HerdrUpdateController

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .herdrFont(.title2)
                .foregroundStyle(HerdrTheme.accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Herdr \(version) is available")
                    .herdrFont(.subheadline, weight: .semibold)
                    .foregroundStyle(HerdrTheme.text)
                Text("Review what’s new and choose when to install.")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.mist)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)

            Spacer(minLength: 12)

            Button("Later") {
                updates.dismissBanner()
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Dismiss update banner")
            .accessibilityIdentifier("update-banner-later")

            Button("Review update…") {
                updates.checkForUpdates()
            }
            .herdrProminentButton()
            .disabled(!updates.canCheckForUpdates)
            .accessibilityIdentifier("update-banner-review")
        }
        .padding(.horizontal, HerdrTheme.pagePadding)
        .padding(.vertical, 12)
        .background(HerdrTheme.graphite)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(HerdrTheme.surface)
                .frame(height: 1)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("update-banner")
    }
}
