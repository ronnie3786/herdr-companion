import SwiftUI

struct SidebarRangeMenu: View {
    @Bindable var model: HerdrAppModel

    var body: some View {
        Menu {
            ForEach(SidebarRecency.allCases) { recency in
                Button {
                    model.sidebarRecency = recency
                } label: {
                    Label(
                        recency.title,
                        systemImage: recency == model.sidebarRecency
                            ? "checkmark"
                            : recency.symbolName
                    )
                }
            }
        } label: {
            Label(model.sidebarRecency.title, systemImage: model.sidebarRecency.symbolName)
                .font(.caption.bold())
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(model.sidebarRecency == .all ? HerdrTheme.mist : HerdrTheme.accent)
                .frame(minHeight: SidebarMetrics.controlHeight)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar-recent-filter")
        .accessibilityLabel("Chat range, \(model.sidebarRecency.title)")
    }
}
