import SwiftUI

struct FirstMateGraphNode: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    let visit: FirstMateVisit
    let isExpanded: Bool
    let toggle: () -> Void
    @Environment(\.colorScheme) private var scheme

    private var isCurrent: Bool { visit.id == snapshot.feature.currentVisitID }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(HerdrTheme.accent)
                        .frame(width: 32, height: 32)
                        .background(HerdrTheme.accent.opacity(0.12), in: .rect(cornerRadius: 9))
                        .accessibilityHidden(true)
                    FirstMateVisitHeading(visit: visit, isCurrent: isCurrent, displayStatus: snapshot.displayStatus(for: visit))
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(HerdrTheme.iconTint)
                        .padding(.top, 5)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.herdrPlain)
            .accessibilityLabel("\(visit.title), \(isExpanded ? "hide" : "show") step details")
            .accessibilityValue(isCurrent ? "Current step" : "")
            .accessibilityIdentifier("first-mate-graph-node-\(visit.id)")
            FirstMateResourceButtons(store: store, snapshot: snapshot, visit: visit).padding(.leading, 44)
            if isExpanded {
                Divider()
                FirstMateStageDetailView(store: store, snapshot: snapshot, visit: visit)
            }
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
        .background(isCurrent ? HerdrTheme.accent.opacity(0.07) : HerdrTheme.cardFill, in: .rect(cornerRadius: HerdrTheme.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.Radius.card)
                .strokeBorder(isCurrent ? HerdrTheme.accent.opacity(0.45) : HerdrTheme.outline, lineWidth: 1)
        }
    }

    private var symbol: String {
        if visit.stageKey.contains("review") { return "person.2.wave.2" }
        if visit.stageKey.contains("plan") { return "map" }
        if visit.stageKey.contains("proof") || visit.stageKey.contains("verify") { return "checkmark.shield" }
        return "square.stack.3d.up"
    }
}
