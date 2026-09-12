import SwiftUI

struct SidebarHeaderView: View {
    @Bindable var model: HerdrAppModel
    let close: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    identity
                    Spacer(minLength: 8)
                    closeButton
                }
                SidebarRangeMenu(model: model)
            }
        } else {
            HStack(spacing: 8) {
                identity
                Spacer(minLength: 4)
                SidebarRangeMenu(model: model)
                closeButton
            }
        }
    }

    private var identity: some View {
        Label {
            Text("herdr")
                .font(.headline.monospaced().bold())
                .foregroundStyle(HerdrTheme.text)
        } icon: {
            HerdrBrandMark(size: 28)
        }
    }

    private var closeButton: some View {
        Button("Close navigator", systemImage: "xmark", action: close)
            .labelStyle(.iconOnly)
            .foregroundStyle(HerdrTheme.mist)
            .frame(width: SidebarMetrics.controlHeight, height: SidebarMetrics.controlHeight)
            .contentShape(.rect)
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar-close")
    }
}
