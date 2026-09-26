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
        VStack(spacing: 0) {
            WorkspaceSearchField(text: $index.search, placeholder: "Find a feature on any machine")
                .herdrHairline(.bottom, color: palette.hairline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    SidebarNavRow(title: "All sessions", systemImage: "chevron.left", action: back)
                        .accessibilityIdentifier("first-mate-back")
                    let total = index.filteredHosts.reduce(0) { $0 + $1.features.count }
                    FirstMateSidebarSection(title: "All machines", count: total,
                                            countLabel: "\(total) feature\(total == 1 ? "" : "s")")
                    ForEach(index.filteredHosts) { host in
                        HStack(spacing: 8) {
                            Image(systemName: "desktopcomputer")
                                .herdrFont(size: 14)
                                .foregroundStyle(palette.iconTint)
                                .accessibilityHidden(true)
                            Text(host.machineName)
                                .herdrFont(size: HerdrTheme.TextSize.body, weight: .medium)
                                .foregroundStyle(palette.text)
                                .lineLimit(1)
                            Spacer()
                            if host.isLoading {
                                ProgressView().controlSize(.mini)
                            } else {
                                Text("\(host.features.count)")
                                    .herdrFont(size: HerdrTheme.TextSize.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(palette.tertiaryText)
                            }
                        }
                        .padding(.horizontal, 8)
                        .frame(minHeight: HerdrTheme.ControlHeight.row)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isHeader)
                        if let error = host.error {
                            Label(error, systemImage: host.unsupported ? "arrow.down.circle" : "wifi.exclamationmark")
                                .herdrFont(size: HerdrTheme.TextSize.caption)
                                .foregroundStyle(host.unsupported ? palette.tertiaryText : HerdrTheme.warning)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                        } else if !host.isLoading && host.features.isEmpty {
                            Text("No features")
                                .herdrFont(size: HerdrTheme.TextSize.caption)
                                .foregroundStyle(palette.tertiaryText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                        }
                        ForEach(host.features) { feature in
                            let isSelected = selectedMachineID == host.machineID && selectedFeatureID == feature.id
                            Button { openFeature(host.machineID, feature.id) } label: {
                                FirstMateFeatureCard(
                                    title: feature.title,
                                    detail: feature.workItemID ?? "Idea",
                                    status: feature.status,
                                    isSelected: isSelected
                                )
                            }
                            .help(feature.title)
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("first-mate-feature-\(host.machineID)-\(feature.id)")
                        }
                    }
                    if index.filteredHosts.isEmpty, index.hasLoadedAnyHost {
                        ContentUnavailableView.search(text: index.search)
                    }
                }
                .padding(6)
            }
            HStack(spacing: 6) {
                Label("Feature details open on their owning companion", systemImage: "desktopcomputer")
                    .labelStyle(DashboardInlineLabelStyle(spacing: 6))
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(palette.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(
                    appearanceStore.isDark ? "Use light appearance" : "Use dark appearance",
                    systemImage: appearanceStore.isDark ? "sun.max" : "moon"
                ) { appearanceStore.isDark.toggle() }
                .buttonStyle(HerdrIconButtonStyle(tint: palette.iconTint))
                .help(appearanceStore.isDark ? "Use light appearance" : "Use dark appearance")
                .accessibilityIdentifier("first-mate-theme")
            }
            .padding(8)
            .herdrHairline(.top, color: palette.hairline)
        }
        .herdrPaneBackground(palette.sidebar)
        .foregroundStyle(palette.text, palette.secondaryText, palette.tertiaryText)
        .herdrRailHeaderActions {
            Menu {
                ForEach(createMachines) { machine in
                    Button(machine.name) { createFeature(machine.id) }
                }
            } label: {
                Image(systemName: "plus")
            }
            .herdrIconMenu(tint: palette.iconTint)
            .disabled(createMachines.isEmpty)
            .help("New feature")
            .accessibilityLabel("New feature")
            .accessibilityIdentifier("first-mate-new-feature")
            Button("Refresh all machines", systemImage: "arrow.clockwise", action: refresh)
                .buttonStyle(HerdrIconButtonStyle(tint: palette.iconTint))
                .help("Refresh all machines")
                .accessibilityIdentifier("first-mate-fleet-refresh")
        }
        .accessibilityIdentifier("first-mate-fleet-sidebar")
    }
}
