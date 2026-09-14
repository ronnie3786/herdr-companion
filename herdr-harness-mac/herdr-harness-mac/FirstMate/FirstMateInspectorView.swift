import SwiftUI

struct FirstMateInspectorView: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(FirstMateInspector.allCases) { tab in
                    Button { store.inspector = tab } label: {
                        VStack(spacing: 12) {
                            Text(tab.rawValue).font(.subheadline.weight(store.inspector == tab ? .semibold : .regular))
                            Rectangle().fill(store.inspector == tab ? FirstMatePalette(scheme: scheme).accent : .clear).frame(height: 2)
                        }.padding(.top, 22).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(store.inspector == tab ? .isSelected : [])
                    .foregroundStyle(store.inspector == tab ? FirstMatePalette(scheme: scheme).accent : .secondary)
                    .accessibilityIdentifier("first-mate-tab-\(tab.id)")
                }
            }.padding(.horizontal, 16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch store.inspector {
                    case .overview: FirstMateOverviewView(store: store, snapshot: snapshot)
                    case .agents: FirstMateAgentsView(store: store, snapshot: snapshot)
                    case .documents: FirstMateDocumentsView(store: store, snapshot: snapshot)
                    case .workflow: FirstMateWorkflowView(store: store, snapshot: snapshot)
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 6) {
                Image(systemName: store.error == nil ? "checkmark.circle" : "exclamationmark.circle")
                Text(store.isDemo ? "Synthetic data · no agents launched" : store.error == nil ? "Synced with companion" : "Connection needs attention")
                Spacer()
                Text("Revision \(snapshot.feature.revision)")
            }.herdrFont(.caption2).foregroundStyle(.secondary).padding(12)
        }
        .background(FirstMatePalette(scheme: scheme).background)
    }
}
