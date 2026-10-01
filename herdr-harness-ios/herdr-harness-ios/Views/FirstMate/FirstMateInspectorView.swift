import SwiftUI

struct FirstMateInspectorView: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    @Environment(\.firstMateHighlightedAssignment) private var highlighted

    var body: some View {
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
                .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 24)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .herdrEdgeFade()
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
        // The tab strip and sync footer float over the content with the
        // system scroll-edge effect, like the Mac inspector over its glass.
        .safeAreaBar(edge: .top, spacing: 0) { FirstMateInspectorTabs(store: store) }
        .safeAreaBar(edge: .bottom, spacing: 0) {
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
    /// Replaces "Revision N", e.g. the lead's "7 features".
    var trailing: String? = nil
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { status; Spacer(minLength: 4); revisionLabel }
            VStack(alignment: .leading, spacing: 4) { status; revisionLabel }
        }
        .herdrFont(.caption2).foregroundStyle(hasError ? HerdrTheme.warning : HerdrTheme.tertiaryText)
        .padding(.horizontal, 16).padding(.vertical, 6).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .herdrHairline(.top)
        .accessibilityElement(children: .combine).accessibilityIdentifier("first-mate-sync-footer")
        .composerLayoutMeasurement(id: "info-sync-footer")
    }
    private var status: some View {
        Label(isDemo ? "Synthetic data · no agents launched" : hasError ? "Connection needs attention" : "Synced with companion",
              systemImage: hasError ? "exclamationmark.circle" : "checkmark.circle")
            .fixedSize(horizontal: false, vertical: true)
    }
    private var revisionLabel: some View { Text(trailing ?? "Revision \(revision)").monospacedDigit().fixedSize() }
}
