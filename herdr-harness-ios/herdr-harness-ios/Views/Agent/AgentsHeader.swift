import SwiftUI

struct AgentsHeader: View {
    @Bindable var model: HerdrAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HerdrBrandMark(size: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Agents")
                        .font(.title2.bold())
                    Text("All machines")
                        .font(.caption)
                        .foregroundStyle(HerdrTheme.mist)
                }

                Spacer()

                Button("Car mode", systemImage: "car.fill") {
                    model.openCarMode()
                }
                .labelStyle(.iconOnly)
                .font(.headline.bold())
                .foregroundStyle(HerdrTheme.accent)
                .frame(width: 44, height: 44)
                .background(HerdrTheme.elevated)
                .overlay {
                    RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                        .strokeBorder(HerdrTheme.surface, lineWidth: 1)
                }
                .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
                .buttonStyle(.plain)
                .accessibilityIdentifier("car-mode-open")
                .accessibilityLabel("Car mode")
                .accessibilityHint("Opens a distraction-free driving view with voice-only replies")

                Button("Open navigator", systemImage: "sidebar.leading") {
                    model.isSidebarPresented = true
                }
                .labelStyle(.iconOnly)
                .font(.headline.bold())
                .foregroundStyle(HerdrTheme.accent)
                .frame(width: 44, height: 44)
                .background(HerdrTheme.elevated)
                .overlay {
                    RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                        .strokeBorder(HerdrTheme.surface, lineWidth: 1)
                }
                .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebar-toggle")

                HerdPulseButton(controlSize: 44)

                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refresh() }
                }
                .labelStyle(.iconOnly)
                .font(.headline.bold())
                .foregroundStyle(HerdrTheme.accent)
                .frame(width: 44, height: 44)
                .background(HerdrTheme.elevated)
                .overlay {
                    RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                        .strokeBorder(HerdrTheme.surface, lineWidth: 1)
                }
                .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
                .buttonStyle(.plain)
                .disabled(model.isRefreshing)

            }

            if model.isDemoMode {
                Label("Demo data is active", systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(HerdrTheme.accent)
            }
        }
    }
}
