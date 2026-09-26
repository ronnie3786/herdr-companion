import SwiftUI

struct HerdrHudTranscriptEmptyView: View {
    let errorMessage: String?
    let promoteErrorMessage: String?
    let audioErrorMessage: String?

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "sparkles")
                .herdrFont(size: HerdrTheme.TextSize.title)
                .foregroundStyle(HerdrTheme.accent)
                .accessibilityHidden(true)
            Text("Ask anything, anywhere")
                .herdrFont(size: HerdrTheme.TextSize.reading, weight: .bold)
                .foregroundStyle(HerdrTheme.text)
            Text("⌃⌥Space summons the HUD, anywhere.")
                .herdrFont(size: HerdrTheme.TextSize.caption)
                .foregroundStyle(HerdrTheme.tertiaryText)
                .multilineTextAlignment(.center)
            Spacer()
            HerdrHudTranscriptErrorsView(
                errorMessage: errorMessage,
                promoteErrorMessage: promoteErrorMessage,
                audioErrorMessage: audioErrorMessage
            )
        }
        .padding(HerdrTheme.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
