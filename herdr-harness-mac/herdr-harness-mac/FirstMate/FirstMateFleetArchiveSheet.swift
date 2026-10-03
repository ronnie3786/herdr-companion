import SwiftUI

/// An archive sheet owns its client instead of following whichever conversation is selected.
struct FirstMateFleetArchiveSheet: View {
    let index: FirstMateFleetIndex
    let target: FirstMateFleetIndex.ArchiveTarget
    let onArchived: () -> Void
    @State private var store: FirstMateStore?
    @Environment(\.dismiss) private var dismiss

    init(index: FirstMateFleetIndex, target: FirstMateFleetIndex.ArchiveTarget,
         demoStore: FirstMateStore? = nil, onArchived: @escaping () -> Void = {}) {
        self.index = index
        self.target = target
        self.onArchived = onArchived
        if let demoStore, demoStore.isDemo {
            _store = State(initialValue: demoStore)
        } else if let client = index.archiveClient(for: target) {
            let store = FirstMateStore()
            store.configure(client: client, demo: false)
            _store = State(initialValue: store)
        } else {
            _store = State(initialValue: nil)
        }
    }

    var body: some View {
        if let store {
            FirstMateArchiveSheet(store: store, feature: target.feature,
                isConnectionCurrent: { store.isDemo || index.isCurrent(target) }, onArchived: onArchived)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                Label("Companion connection changed", systemImage: "exclamationmark.triangle")
                    .herdrFont(size: 16, weight: .semibold)
                Text("Close this screen and open Archive again from the session’s machine.")
                Button("Close", role: .cancel) { dismiss() }
            }
            .padding(24).frame(width: 440).modifier(FirstMateArchiveSurface())
            .preferredColorScheme(.dark)
        }
    }
}
