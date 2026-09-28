import SwiftUI

struct FirstMateSidebarView: View {
    @Bindable var store: FirstMateStore
    let back: () -> Void
    let canControl: Bool
    var leaveDemo: () -> Void = {}
    @Environment(\.colorScheme) private var scheme
    @State private var archiveCandidate: FirstMateFeature? = nil
    private var palette: FirstMatePalette { FirstMatePalette(scheme: scheme) }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceSearchField(text: $store.search, placeholder: "Find a feature")
                .herdrHairline(.bottom, color: palette.hairline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    SidebarNavRow(title: "All sessions", systemImage: "chevron.left", action: back)
                        .accessibilityIdentifier("first-mate-back")
                    if let warning = store.runtimeHealth?.warning {
                        Label("Execution needs attention", systemImage: "exclamationmark.triangle.fill")
                            .herdrFont(size: HerdrTheme.TextSize.small, weight: .medium)
                            .foregroundStyle(HerdrTheme.warning)
                            .padding(.horizontal, 8)
                            .frame(minHeight: HerdrTheme.minHitTarget)
                            .help(warning)
                    }
                    FirstMateSidebarSection(title: "Your features", count: store.activeFeatures.count)
                    ForEach(store.activeFeatures) { feature in
                        featureRow(feature)
                    }
                    if store.showArchived, !store.archivedFeatures.isEmpty {
                        FirstMateSidebarSection(title: "Archived", count: store.archivedFeatures.count)
                            .padding(.top, 10)
                        ForEach(store.archivedFeatures) { feature in
                            featureRow(feature)
                        }
                    }
                }
                .padding(6)
            }
            footer
        }
        .herdrPaneBackground(palette.sidebar)
        .foregroundStyle(palette.text, palette.secondaryText, palette.tertiaryText)
        .herdrRailHeaderActions {
            Button("New feature", systemImage: "plus") { store.isCreating = true }
                .buttonStyle(HerdrIconButtonStyle(tint: palette.iconTint))
                .disabled(!canControl)
                .help("New feature")
                .accessibilityIdentifier("first-mate-new-feature")
        }
        .sheet(item: $archiveCandidate) { feature in
            FirstMateArchiveSheet(store: store, feature: feature)
        }
        .accessibilityIdentifier("first-mate-sidebar")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $store.showArchived) {
                Text("Show archived")
                    .herdrFont(size: HerdrTheme.TextSize.small)
                    .foregroundStyle(palette.secondaryText)
            }
            .toggleStyle(.switch)
            .onChange(of: store.showArchived) { _, _ in Task { await store.refresh() } }
            .disabled(!store.archiveSupported)
            .help(store.archiveSupported ? "Include archived features" : "Update the companion server to manage archived features")
            .accessibilityIdentifier("first-mate-show-archived")
            if store.hasLoaded, !store.archiveSupported, !store.isDemo {
                Text("Update the companion server to archive features.")
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(palette.tertiaryText)
            }
            if store.isDemo {
                Button("Connect to live work", systemImage: "server.rack", action: leaveDemo)
                    .buttonStyle(HerdrButtonStyle(kind: .primary))
                    .accessibilityIdentifier("first-mate-leave-demo")
                HStack(spacing: 6) {
                    Label("Synthetic demo", systemImage: "flask")
                        .labelStyle(DashboardInlineLabelStyle(spacing: 5))
                        .herdrFont(size: HerdrTheme.TextSize.caption)
                        .foregroundStyle(palette.tertiaryText)
                    Text("·").foregroundStyle(palette.tertiaryText)
                    Text(store.demoStepTitle)
                        .herdrFont(size: HerdrTheme.TextSize.small, weight: .medium)
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                }
                Button("Next scenario", systemImage: "forward.end", action: store.advanceDemo)
                    .buttonStyle(HerdrButtonStyle(kind: .outline))
                    .accessibilityIdentifier("first-mate-demo-next")
            }
            HStack(spacing: 6) {
                Label(store.isDemo ? "Demo data only" : "Companion host", systemImage: store.isDemo ? "circle.dotted" : "desktopcomputer")
                    .labelStyle(DashboardInlineLabelStyle(spacing: 6))
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(palette.tertiaryText)
                Spacer()
                Button(store.isDark ? "Use light appearance" : "Use dark appearance", systemImage: store.isDark ? "sun.max" : "moon") { store.isDark.toggle() }
                    .buttonStyle(HerdrIconButtonStyle(tint: palette.iconTint))
                    .help(store.isDark ? "Use light appearance" : "Use dark appearance")
                    .accessibilityIdentifier("first-mate-theme")
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .herdrHairline(.top, color: palette.hairline)
    }

    private func featureRow(_ feature: FirstMateFeature) -> some View {
        HStack(spacing: 2) {
            Button { store.select(feature.id) } label: {
                FirstMateFeatureCard(
                    title: feature.title,
                    detail: [feature.workItemID ?? "Idea", FirstMateUsageFormatting.compactCost(feature.usage)].joined(separator: " · "),
                    status: store.executionDisplayStatus(for: feature),
                    symbol: feature.isArchived ? "archivebox" : "square.3.layers.3d",
                    isSelected: store.selectedFeatureID == feature.id
                )
            }
            .accessibilityLabel("\(feature.title), \(feature.workItemID ?? "Idea"), status \(store.executionDisplayStatus(for: feature).replacingOccurrences(of: "_", with: " ")), \(FirstMateUsageFormatting.taskAccessibilityDescription(feature.usage))")
            .accessibilityAddTraits(store.selectedFeatureID == feature.id ? .isSelected : [])
            .help("\(feature.title)\n\(FirstMateUsageFormatting.taskAccessibilityDescription(feature.usage))")
            .buttonStyle(.herdrPlain)
            .accessibilityIdentifier("first-mate-feature-\(feature.id)")
            if feature.isArchived {
                Button("Unarchive", systemImage: "arrow.uturn.backward") {
                    Task { _ = await store.setArchived(featureID: feature.id, archived: false) }
                }
                .buttonStyle(HerdrIconButtonStyle(visualSize: HerdrTheme.ControlHeight.small, tint: palette.iconTint))
                .help("Unarchive \(feature.title)")
                .disabled(!canControl || !store.archiveSupported || store.isSending)
            }
        }
        .contextMenu {
            if feature.isArchived {
                Button("Unarchive", systemImage: "arrow.uturn.backward") {
                    Task { _ = await store.setArchived(featureID: feature.id, archived: false) }
                }
                .disabled(!canControl || !store.archiveSupported || store.isSending)
            } else {
                Button("Archive…", systemImage: "archivebox") { archiveCandidate = feature }
                    .disabled(!canControl || !store.archiveSupported || store.isSending)
            }
        }
    }
}

/// A First Mate sidebar section label (MonoCode's `.sec`): name on the left,
/// count on the right.
struct FirstMateSidebarSection: View {
    let title: String
    var count: Int?
    var countLabel: String? = nil

    var body: some View {
        HStack {
            Text(title)
                .herdrFont(size: HerdrTheme.TextSize.small)
                .foregroundStyle(HerdrTheme.tertiaryText)
            Spacer()
            if let count {
                Text(countLabel ?? "\(count)")
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .monospacedDigit()
                    .foregroundStyle(HerdrTheme.tertiaryText)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 5)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One feature in a First Mate sidebar (MonoCode's `.card`): ticket and
/// status on the first line, the title on the second.
struct FirstMateFeatureCard: View {
    let title: String
    let detail: String
    let status: String
    var symbol = "square.3.layers.3d"
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .herdrFont(size: 13)
                    .foregroundStyle(HerdrTheme.accent)
                    .accessibilityHidden(true)
                Text(detail)
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? HerdrTheme.secondaryText : HerdrTheme.tertiaryText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                FirstMateStatusLabel(status: status)
            }
            Text(title)
                .herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
                .foregroundStyle(HerdrTheme.primaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .herdrRowBackground(selected: isSelected, hovered: isHovered)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .padding(.bottom, 2)
    }
}
