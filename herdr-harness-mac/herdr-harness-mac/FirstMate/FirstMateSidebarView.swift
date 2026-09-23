import SwiftUI

struct FirstMateSidebarView: View {
    @Bindable var store: FirstMateStore
    let back: () -> Void
    let canControl: Bool
    var leaveDemo: () -> Void = {}
    @Environment(\.colorScheme) private var scheme
    @State private var archiveCandidate: FirstMateFeature? = nil
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
            if let warning = store.runtimeHealth?.warning {
                Label("Execution needs attention", systemImage: "exclamationmark.triangle.fill")
                    .herdrFont(.caption).foregroundStyle(.orange)
                    .help(warning)
            }
            Text("YOUR FEATURES").herdrFont(.caption2, weight: .semibold).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(store.activeFeatures) { feature in
                        featureRow(feature)
                    }
                    if store.showArchived, !store.archivedFeatures.isEmpty {
                        Text("ARCHIVED")
                            .herdrFont(.caption2, weight: .semibold)
                            .foregroundStyle(.secondary)
                            .padding(.top, 14)
                        ForEach(store.archivedFeatures) { feature in
                            featureRow(feature)
                        }
                    }
                }
            }
            Toggle("Show archived", isOn: $store.showArchived)
                .toggleStyle(.switch)
                .herdrFont(.caption)
                .onChange(of: store.showArchived) { _, _ in Task { await store.refresh() } }
                .disabled(!store.archiveSupported)
                .help(store.archiveSupported ? "Include archived features" : "Update the companion server to manage archived features")
                .accessibilityIdentifier("first-mate-show-archived")
            if store.hasLoaded, !store.archiveSupported, !store.isDemo {
                Text("Update the companion server to archive features.")
                    .herdrFont(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if store.isDemo {
                Button("Connect to live work", systemImage: "server.rack", action: leaveDemo)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("first-mate-leave-demo")
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
        .sheet(item: $archiveCandidate) { feature in
            FirstMateArchiveSheet(store: store, feature: feature)
        }
        .accessibilityIdentifier("first-mate-sidebar")
    }

    private func featureRow(_ feature: FirstMateFeature) -> some View {
        HStack(spacing: 4) {
            Button { store.select(feature.id) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: feature.isArchived ? "archivebox" : "square.stack.3d.up").foregroundStyle(FirstMatePalette(scheme: scheme).accent)
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(feature.title).herdrFont(.body, weight: .medium).multilineTextAlignment(.leading)
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text(feature.workItemID ?? "Idea")
                                        Spacer(minLength: 4)
                                        Text(FirstMateUsageFormatting.compactCost(feature.usage))
                                            .monospacedDigit()
                                            .lineLimit(1)
                                    }
                                    .herdrFont(.caption)
                                    .foregroundStyle(.secondary)
                                    FirstMateStatusLabel(status: store.executionDisplayStatus(for: feature))
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(store.selectedFeatureID == feature.id ? FirstMatePalette(scheme: scheme).accent.opacity(0.12) : .clear, in: .rect(cornerRadius: 9))
                        }
                        .accessibilityLabel("\(feature.title), \(feature.workItemID ?? "Idea"), status \(store.executionDisplayStatus(for: feature).replacingOccurrences(of: "_", with: " ")), \(FirstMateUsageFormatting.taskAccessibilityDescription(feature.usage))")
                        .accessibilityAddTraits(store.selectedFeatureID == feature.id ? .isSelected : [])
                        .help(FirstMateUsageFormatting.taskAccessibilityDescription(feature.usage))
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("first-mate-feature-\(feature.id)")
            if feature.isArchived {
                Button("Unarchive", systemImage: "arrow.uturn.backward") {
                    Task { _ = await store.setArchived(featureID: feature.id, archived: false) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
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

private struct FirstMateArchiveSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: FirstMateStore
    let feature: FirstMateFeature
    @State private var reason: FirstMateArchiveReason? = nil

    private var workContinues: Bool {
        ["running", "coordinating", "recovering"].contains(feature.status)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Archive \(feature.title)?").herdrFont(.title2, weight: .semibold)
            Text(workContinues
                 ? "The feature will leave the active list, but its work continues. All visits, assignments, documents, sessions, events, status, and Active Work linkage are retained."
                 : "The feature will leave the active list. All visits, assignments, documents, sessions, events, status, and Active Work linkage are retained.")
                .fixedSize(horizontal: false, vertical: true)
            Picker("Optional reason", selection: $reason) {
                Text("No reason").tag(nil as FirstMateArchiveReason?)
                ForEach(FirstMateArchiveReason.allCases) { value in
                    Text(value.title).tag(value as FirstMateArchiveReason?)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Archive", role: .destructive) {
                    Task {
                        if await store.setArchived(featureID: feature.id, archived: true, reason: reason) { dismiss() }
                    }
                }
                .disabled(!store.archiveSupported || store.isSending)
                .accessibilityIdentifier("first-mate-confirm-archive")
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
