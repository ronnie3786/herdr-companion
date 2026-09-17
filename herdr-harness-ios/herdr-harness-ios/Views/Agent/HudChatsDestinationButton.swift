import SwiftUI

struct HudChatsDestinationButton: View {
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .font(.title3)
                    .foregroundStyle(HerdrTheme.accent)
                    .frame(width: 44, height: 44)
                    .background(HerdrTheme.graphite)
                    .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))

                VStack(alignment: .leading, spacing: 3) {
                    Text("HUD Chats")
                        .font(.headline)
                        .foregroundStyle(HerdrTheme.text)
                    Text("Saved conversations across your machines")
                        .font(.subheadline)
                        .foregroundStyle(HerdrTheme.mist)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .foregroundStyle(HerdrTheme.muted)
            }
            .padding(HerdrTheme.cardPadding)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(HerdrTheme.elevated.opacity(0.55))
            .overlay {
                RoundedRectangle(cornerRadius: HerdrTheme.cardRadius)
                    .strokeBorder(HerdrTheme.surface, lineWidth: 1)
            }
            .clipShape(.rect(cornerRadius: HerdrTheme.cardRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("hud-chats-destination")
    }
}
