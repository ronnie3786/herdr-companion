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
        VStack(alignment: .leading, spacing: 14) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: symbol)
                        .font(.title2)
                        .foregroundStyle(FirstMatePalette(scheme: scheme).accent)
                        .padding(.top, 2)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 8) {
                        if isCurrent {
                            Text("CURRENT STEP").font(.footnote.weight(.semibold))
                                .foregroundStyle(FirstMatePalette(scheme: scheme).accent)
                        }
                        FirstMateVisitHeading(visit: visit, isCurrent: isCurrent)
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(visit.title), \(isExpanded ? "hide" : "show") step details")
            .accessibilityValue(isCurrent ? "Current step" : "")
            .accessibilityIdentifier("first-mate-graph-node-\(visit.id)")
            FirstMateResourceButtons(store: store, snapshot: snapshot, visit: visit)
            if isExpanded {
                Divider()
                FirstMateStageDetailView(store: store, snapshot: snapshot, visit: visit)
            }
        }
        .padding(18)
        .background(isCurrent ? FirstMatePalette(scheme: scheme).accent.opacity(0.07) : FirstMatePalette(scheme: scheme).surface, in: .rect(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(isCurrent ? FirstMatePalette(scheme: scheme).accent.opacity(0.55) : FirstMatePalette(scheme: scheme).line, lineWidth: 1)
        }
    }

    private var symbol: String {
        if visit.stageKey.contains("review") { return "person.2.wave.2" }
        if visit.stageKey.contains("plan") { return "map" }
        if visit.stageKey.contains("proof") || visit.stageKey.contains("verify") { return "checkmark.shield" }
        return "square.stack.3d.up"
    }
}
