import SwiftUI

struct ChatTabColorFilterButton: View {
    let store: ChatTabColorStore
    let selectedColor: ChatTabColor?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: selectedColor?.symbol ?? "paintpalette")
                    .foregroundStyle(selectedColor?.swatch ?? HerdrTheme.mist)
                    .accessibilityHidden(true)

                Text("Tab colors")
                    .foregroundStyle(selectedColor == nil ? HerdrTheme.mist : HerdrTheme.accent)

                Spacer(minLength: 8)

                Text(selectedColor.map { store.label(for: $0) } ?? "No filter")
                    .font(.caption)
                    .foregroundStyle(HerdrTheme.muted)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)

                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(HerdrTheme.muted)
                    .accessibilityHidden(true)
            }
            .font(.subheadline)
            .padding(.horizontal, SidebarMetrics.rowHorizontalPadding)
            .frame(minHeight: SidebarMetrics.controlHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar-tab-colors")
        .accessibilityLabel("Tab colors")
        .accessibilityValue(selectedColor.map { "Filtered by \(store.label(for: $0))" } ?? "No filter")
        .accessibilityHint("Shows local tab color filters and label editing")
    }
}
