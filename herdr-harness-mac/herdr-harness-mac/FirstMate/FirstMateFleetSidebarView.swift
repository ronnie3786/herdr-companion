import SwiftUI

struct FirstMateFleetSidebarView: View {
    @Bindable var index: FirstMateFleetIndex
    @Bindable var appearanceStore: FirstMateStore
    let selectedMachineID: String?
    let selectedFeatureID: String?
    let createMachines: [HerdrMachine]
    let back: () -> Void
    let openFeature: (String, String) -> Void
    let createFeature: (String) -> Void
    let refresh: () -> Void
    @Environment(\.colorScheme) private var scheme

    private var palette: FirstMatePalette { FirstMatePalette(scheme: scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button("All sessions", systemImage: "chevron.left", action: back)
                .buttonStyle(.plain)
                .herdrFont(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("first-mate-back")
            HStack {
                Label("First Mate", systemImage: "sailboat.fill")
                    .herdrFont(.title3, weight: .semibold)
                Spacer()
                Menu("New feature", systemImage: "plus") {
                    ForEach(createMachines) { machine in
                        Button(machine.name) { createFeature(machine.id) }
                    }
                }
                .labelStyle(.iconOnly)
                .menuStyle(.borderlessButton)
                .disabled(createMachines.isEmpty)
                .accessibilityIdentifier("first-mate-new-feature")
                Button("Refresh all machines", systemImage: "arrow.clockwise", action: refresh)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("first-mate-fleet-refresh")
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").accessibilityHidden(true)
                TextField("Find a feature on any machine", text: $index.search)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Find a feature on any machine")
            }
            .padding(10)
            .foregroundStyle(palette.text)
            .background(palette.surface, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.line))
            Text("ALL MACHINES").herdrFont(.caption2, weight: .semibold).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(index.filteredHosts) { host in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 7) {
                                Image(systemName: "desktopcomputer").accessibilityHidden(true)
                                Text(host.machineName).herdrFont(.caption, weight: .semibold)
                                Spacer()
                                if host.isLoading { ProgressView().controlSize(.small) }
                            }
                            .foregroundStyle(.secondary)
                            if let error = host.error {
                                Label(error, systemImage: host.unsupported ? "arrow.down.circle" : "wifi.exclamationmark")
                                    .herdrFont(.caption2)
                                    .foregroundStyle(host.unsupported ? palette.secondaryText : Color.orange)
                                    .padding(.vertical, 6)
                            } else if !host.isLoading && host.features.isEmpty {
                                Text("No features")
                                    .herdrFont(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 6)
                            }
                            ForEach(host.features) { feature in
                                let isSelected = selectedMachineID == host.machineID && selectedFeatureID == feature.id
                                Button { openFeature(host.machineID, feature.id) } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: "square.stack.3d.up").foregroundStyle(palette.accent)
                                        VStack(alignment: .leading, spacing: 7) {
                                            Text(feature.title).herdrFont(.body, weight: .medium).multilineTextAlignment(.leading)
                                            Text(feature.workItemID ?? "Idea").herdrFont(.caption2).foregroundStyle(.secondary)
                                            FirstMateStatusLabel(status: feature.status)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(isSelected ? palette.accent.opacity(0.12) : .clear, in: .rect(cornerRadius: 9))
                                }
                                .accessibilityAddTraits(isSelected ? .isSelected : [])
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("first-mate-feature-\(host.machineID)-\(feature.id)")
                            }
                        }
                    }
                    if index.filteredHosts.isEmpty, index.hasLoadedAnyHost {
                        ContentUnavailableView.search(text: index.search)
                    }
                }
            }
            Spacer(minLength: 0)
            Divider()
            HStack {
                Label("Feature details open on their owning companion", systemImage: "desktopcomputer")
                    .herdrFont(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(
                    appearanceStore.isDark ? "Use light appearance" : "Use dark appearance",
                    systemImage: appearanceStore.isDark ? "sun.max" : "moon"
                ) { appearanceStore.isDark.toggle() }
                .buttonStyle(.plain)
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("first-mate-theme")
            }
        }
        .padding(18)
        .background(palette.sidebar)
        .foregroundStyle(.primary)
        .accessibilityIdentifier("first-mate-fleet-sidebar")
    }
}
