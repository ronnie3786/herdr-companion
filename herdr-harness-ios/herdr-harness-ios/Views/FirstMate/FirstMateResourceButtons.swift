import SwiftUI

struct FirstMateResourceButtons: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    let visit: FirstMateVisit
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                FirstMateAgentMenu(store: store, snapshot: snapshot, visit: visit)
                FirstMateDocumentMenu(store: store, snapshot: snapshot, visit: visit)
            }
            VStack(alignment: .leading, spacing: 8) {
                FirstMateAgentMenu(store: store, snapshot: snapshot, visit: visit)
                FirstMateDocumentMenu(store: store, snapshot: snapshot, visit: visit)
            }
        }
        .font(.subheadline.weight(.medium))
        .tint(FirstMatePalette(scheme: scheme).accent)
    }
}
