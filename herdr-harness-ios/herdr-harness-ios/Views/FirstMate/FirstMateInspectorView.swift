import SwiftUI

struct FirstMateInspectorView: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            FirstMateInspectorTabs(store: store)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch store.inspector {
                    case .overview: FirstMateOverviewView(store: store, snapshot: snapshot)
                    case .agents: FirstMateAgentsView(store: store, snapshot: snapshot)
                    case .documents: FirstMateDocumentsView(store: store, snapshot: snapshot)
                    case .workflow: FirstMateWorkflowView(store: store, snapshot: snapshot)
                    }
                    Label(syncDescription, systemImage: store.error == nil ? "checkmark.circle" : "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .id(store.inspector)
            .refreshable { await store.refresh() }
        }
        .background(FirstMatePalette(scheme: scheme).background)
        .foregroundStyle(FirstMatePalette(scheme: scheme).text)
        .tint(FirstMatePalette(scheme: scheme).accent)
        .sheet(item: $store.resourcePresentation, onDismiss: store.closeResource) { _ in
            if let resource = store.openedResource {
                FirstMateResourceSheet(store: store, resource: resource)
                    .id(resource.id)
            }
        }
    }

    private var syncDescription: String {
        if store.isDemo { return "Demo data · no agents launched" }
        if store.error != nil { return "Connection needs attention. Showing saved feature details." }
        return "Synced with companion · revision \(snapshot.feature.revision)"
    }
}
