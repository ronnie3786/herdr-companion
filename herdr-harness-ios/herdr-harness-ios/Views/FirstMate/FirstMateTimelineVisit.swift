import SwiftUI

struct FirstMateTimelineVisit: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    let visit: FirstMateVisit
    let index: Int
    let isLast: Bool
    @Environment(\.colorScheme) private var scheme

    private var isCurrent: Bool { visit.id == snapshot.feature.currentVisitID }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Image(systemName: visit.status == "completed" ? "checkmark.circle.fill" : isCurrent ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(isCurrent ? FirstMatePalette(scheme: scheme).accent : FirstMatePalette(scheme: scheme).secondaryText)
                    .frame(width: 24, height: 30)
                if !isLast {
                    Rectangle()
                        .fill(FirstMatePalette(scheme: scheme).line)
                        .frame(width: 2)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
                Text(isCurrent ? "CURRENT STEP" : "STEP \(index + 1)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(isCurrent ? FirstMatePalette(scheme: scheme).accent : FirstMatePalette(scheme: scheme).secondaryText)
                FirstMateVisitHeading(visit: visit, isCurrent: isCurrent)
                FirstMateResourceButtons(store: store, snapshot: snapshot, visit: visit)
            }
            .padding(.bottom, isLast ? 0 : 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
