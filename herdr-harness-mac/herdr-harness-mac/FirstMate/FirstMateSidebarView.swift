import SwiftUI

struct FirstMateSidebarView: View {
    @Bindable var store: FirstMateStore
    let back: () -> Void
    let canControl: Bool
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button("All sessions", systemImage: "chevron.left", action: back)
                .buttonStyle(.plain).herdrFont(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("first-mate-back")
            HStack {
                Label("First Mate", systemImage: "sailboat.fill").herdrFont(.title3, weight: .semibold)
                Spacer()
                Button("New feature", systemImage: "plus") { store.isCreating = true }
                    .labelStyle(.iconOnly).buttonStyle(.plain).disabled(!canControl)
                    .accessibilityIdentifier("first-mate-new-feature")
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").accessibilityHidden(true)
                TextField("Find a feature", text: $store.search)
                    .textFieldStyle(.plain).accessibilityLabel("Find a feature")
            }
            .padding(10)
            .foregroundStyle(FirstMatePalette(scheme: scheme).text)
            .background(FirstMatePalette(scheme: scheme).surface, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(FirstMatePalette(scheme: scheme).line))
            Text("YOUR FEATURES").herdrFont(.caption2, weight: .semibold).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(store.filteredFeatures) { feature in
                        Button { store.select(feature.id) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "square.stack.3d.up").foregroundStyle(FirstMatePalette(scheme: scheme).accent)
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(feature.title).herdrFont(.body, weight: .medium).multilineTextAlignment(.leading)
                                    Text(feature.workItemID ?? "Idea").herdrFont(.caption2).foregroundStyle(.secondary)
                                    FirstMateStatusLabel(status: feature.status)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(store.selectedFeatureID == feature.id ? FirstMatePalette(scheme: scheme).accent.opacity(0.12) : .clear, in: .rect(cornerRadius: 9))
                        }
                        .accessibilityAddTraits(store.selectedFeatureID == feature.id ? .isSelected : [])
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("first-mate-feature-\(feature.id)")
                    }
                }
            }
            Spacer(minLength: 0)
            if store.isDemo {
                Label("Synthetic demo", systemImage: "flask").herdrFont(.caption).foregroundStyle(.secondary)
                Text(store.demoStepTitle).herdrFont(.caption, weight: .medium)
                Button("Next scenario", systemImage: "forward.end", action: store.advanceDemo)
                    .accessibilityIdentifier("first-mate-demo-next")
            }
            Divider()
            HStack {
                Label(store.isDemo ? "Demo data only" : "Companion host", systemImage: store.isDemo ? "circle.dotted" : "desktopcomputer")
                    .herdrFont(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button(store.isDark ? "Use light appearance" : "Use dark appearance", systemImage: store.isDark ? "sun.max" : "moon") { store.isDark.toggle() }
                    .buttonStyle(.plain).labelStyle(.iconOnly)
                    .accessibilityIdentifier("first-mate-theme")
            }
        }
        .padding(18).background(FirstMatePalette(scheme: scheme).sidebar)
        .foregroundStyle(.primary)
        .accessibilityIdentifier("first-mate-sidebar")
    }
}
