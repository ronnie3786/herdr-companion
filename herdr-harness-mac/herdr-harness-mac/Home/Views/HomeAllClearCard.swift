import SwiftUI

/// Only shown when every applicable source is current and no unresolved work remains.
struct HomeAllClearCard: View {
    var onCommand: (HomeCommand) -> Void
    @Environment(\.homeReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle").herdrFont(size: 22).foregroundStyle(HomePalette.signal)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("All set.").herdrFont(size: 14, weight: .semibold).foregroundStyle(HomePalette.ink)
                Text("Nothing currently needs your input. Pick up a project or plan what comes next.")
                    .herdrFont(size: 13).foregroundStyle(HomePalette.prose)
                Button("Plan what’s next") { onCommand(.ask("Help me plan what comes next.", context: nil)) }
                    .herdrFont(size: 12.5, weight: .semibold).foregroundStyle(HomePalette.accent)
                    .buttonStyle(HomeButtonStyle()).padding(.top, 4)
                    .accessibilityIdentifier("home.allClear.plan")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 16).padding(.horizontal, 18)
        .background(reduceTransparency ? HomePalette.color(0x242F30) : HomePalette.signal.opacity(0.06), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(HomePalette.signal.opacity(0.24)))
        .accessibilityIdentifier("home.allClear")
    }
}
