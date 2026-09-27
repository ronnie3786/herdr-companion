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
                            Rectangle().fill(HerdrTheme.outline).frame(width: 1, height: spacing - 8)
                            Image(systemName: "chevron.down").herdrFont(size: 8, weight: .semibold).foregroundStyle(HerdrTheme.iconTint)
                        }
                        Spacer()
                    }.accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        store.selectedVisitID = visit.id
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: visit.stageKey.contains("review") ? "person.2.wave.2" : "square.3.layers.3d")
                                .foregroundStyle(HerdrTheme.accent)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(visit.title).herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
                                Text("Revision \(visit.revision)").herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.secondaryText)
                            }
                            Spacer()
                            FirstMateStatusLabel(status: visit.status)
                        }.contentShape(.rect)
                    }.buttonStyle(.herdrPlain)
                    Rectangle().fill(HerdrTheme.hairline).frame(height: 1)
                    FirstMateResourceButtons(store: store, snapshot: snapshot, visit: visit)
                }
                .padding(12)
                .herdrCard(
                    // Inset, not selected, under the current visit: its resource
                    // chips keep 4.5:1 over the dusk.
                    fill: visit.id == snapshot.feature.currentVisitID ? HerdrTheme.insetFill : HerdrTheme.cardFill,
                    outline: visit.id == (store.selectedVisitID ?? snapshot.feature.currentVisitID) ? HerdrTheme.accent : HerdrTheme.outline
                )
                .accessibilityIdentifier("first-mate-graph-node-\(visit.id)")
            }
            Text("Recorded visit order. Each node opens its own agents and documents.")
                .herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.secondaryText).padding(.top, 16)
        }
        .accessibilityIdentifier("first-mate-graph")
    }
}
