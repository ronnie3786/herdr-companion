import SwiftUI

/// Quiet sidebar tools keep their 44-point targets without squeezing the title.
struct AgentsSidebarHeader: View {
    @Bindable var model: HerdrAppModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            header(showsMark: true)
            header(showsMark: false)
        }
        .buttonStyle(.plain)
        .foregroundStyle(HerdrTheme.secondaryText)
    }

    private func header(showsMark: Bool) -> some View {
        HStack(spacing: 4) {
            if showsMark { HerdrBrandMark(size: 22) }
            Text("Agents").font(.headline).fixedSize()
            Spacer(minLength: 0)
            Button("Open navigator", systemImage: "sidebar.leading") { model.isSidebarPresented = true }
                .labelStyle(.iconOnly)
                .frame(width: HerdrTheme.minHitTarget, height: HerdrTheme.minHitTarget)
                .accessibilityIdentifier("sidebar-toggle")
            HerdPulseButton(controlSize: 44, showsBackground: false)
            Menu {
                Button("Car mode", systemImage: "car.fill") { model.openCarMode() }
                    .accessibilityIdentifier("car-mode-open")
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .disabled(model.isRefreshing)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: HerdrTheme.minHitTarget, height: HerdrTheme.minHitTarget)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Agent list actions")
            .accessibilityIdentifier("agents-list-actions")
        }
        .buttonStyle(.plain)
        .foregroundStyle(HerdrTheme.secondaryText)
    }
}
