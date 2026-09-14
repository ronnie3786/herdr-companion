import SwiftUI

struct FirstMateGraphView: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    @Environment(\.colorScheme) private var scheme
    private let spacing: CGFloat = 24
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(snapshot.visits.enumerated()), id: \.element.id) { index, visit in
                if index > 0 {
                    HStack {
                        Spacer()
                        VStack(spacing: 0) {
                            Rectangle().fill(FirstMatePalette(scheme: scheme).accent.opacity(0.35)).frame(width: 1, height: spacing - 8)
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }.accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        store.selectedVisitID = visit.id
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: visit.stageKey.contains("review") ? "person.2.wave.2" : "square.stack.3d.up")
                            VStack(alignment: .leading, spacing: 5) {
                                Text(visit.title).herdrFont(.headline)
                                Text("Revision \(visit.revision)").herdrFont(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            FirstMateStatusLabel(status: visit.status)
                        }.contentShape(.rect)
                    }.buttonStyle(.plain)
                    Divider()
                    FirstMateResourceButtons(store: store, snapshot: snapshot, visit: visit)
                }
                .padding(15)
                .background(visit.id == snapshot.feature.currentVisitID ? FirstMatePalette(scheme: scheme).accent.opacity(0.10) : FirstMatePalette(scheme: scheme).surface, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(visit.id == (store.selectedVisitID ?? snapshot.feature.currentVisitID) ? FirstMatePalette(scheme: scheme).accent : FirstMatePalette(scheme: scheme).line, lineWidth: 1))
                .accessibilityIdentifier("first-mate-graph-node-\(visit.id)")
            }
            Text("Recorded visit order. Each node opens its own agents and documents.")
                .herdrFont(.caption2).foregroundStyle(.secondary).padding(.top, 16)
        }
        .accessibilityIdentifier("first-mate-graph")
    }
}
