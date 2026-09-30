import SwiftUI

struct FirstMateInspectorView: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    @Environment(\.firstMateHighlightedAssignment) private var highlighted

    var body: some View {
        VStack(spacing: 0) {
            FirstMateInspectorTabs(store: store)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        switch store.inspector {
                        case .overview: FirstMateOverviewView(store: store, snapshot: snapshot)
                        case .agents: FirstMateAgentsView(store: store, snapshot: snapshot)
                        case .documents: FirstMateDocumentsView(store: store, snapshot: snapshot)
                        case .workflow: FirstMateWorkflowView(store: store, snapshot: snapshot)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .id(store.inspector)
                .accessibilityIdentifier("first-mate-info-content")
                .refreshable { await store.refresh() }
                .task(id: highlighted) {
                    guard let highlighted, store.inspector == .agents else { return }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(highlighted, anchor: .center)
                }
            }
            FirstMateSyncFooter(isDemo: store.isDemo, hasError: store.error != nil, revision: snapshot.feature.revision)
        }
        .background { HerdrGlassBackground(level: HerdrTheme.Glass.pane).ignoresSafeArea() }
        .foregroundStyle(HerdrTheme.primaryText, HerdrTheme.secondaryText, HerdrTheme.tertiaryText).tint(HerdrTheme.accent)
        .sheet(item: $store.resourcePresentation, onDismiss: store.closeResource) { _ in
            if let resource = store.openedResource {
                FirstMateResourceSheet(store: store, resource: resource).id(resource.id)
            }
        }
    }
}

struct FirstMateSyncFooter: View {
    let isDemo: Bool
    let hasError: Bool
    let revision: Int
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { status; Spacer(minLength: 4); revisionLabel }
            VStack(alignment: .leading, spacing: 4) { status; revisionLabel }
        }
        .herdrFont(.caption2).foregroundStyle(hasError ? HerdrTheme.warning : HerdrTheme.secondaryText)
        .padding(.horizontal, 16).padding(.vertical, 6).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .herdrHairline(.top).background { HerdrGlassBackground(level: HerdrTheme.Glass.pane) }
        .accessibilityElement(children: .combine).accessibilityIdentifier("first-mate-sync-footer")
        .composerLayoutMeasurement(id: "info-sync-footer")
    }
    private var status: some View {
        Label(isDemo ? "Synthetic data · no agents launched" : hasError ? "Connection needs attention" : "Synced with companion",
              systemImage: hasError ? "exclamationmark.circle" : "checkmark.circle")
            .fixedSize(horizontal: false, vertical: true)
    }
    private var revisionLabel: some View { Text("Revision \(revision)").monospacedDigit().fixedSize() }
}
