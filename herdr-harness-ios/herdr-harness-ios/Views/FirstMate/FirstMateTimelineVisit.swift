import SwiftUI

/// One visit on the timeline, as in the Mac inspector: a step marker and
/// rail, the step name with its status, "Visit n · revision r", and the
/// step's agent and document chips.
struct FirstMateTimelineVisit: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    let visit: FirstMateVisit
    let index: Int
    let isLast: Bool

    private var isCurrent: Bool { visit.id == snapshot.feature.currentVisitID }
    private var complete: Bool { ["completed", "complete"].contains(visit.status) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Image(systemName: complete ? "checkmark.circle.fill" : isCurrent ? "circle.circle" : "circle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(complete || isCurrent ? HerdrTheme.accent : HerdrTheme.iconTint)
                    .frame(width: 24, height: 24)
                if !isLast {
                    Rectangle().fill(HerdrTheme.outline).frame(width: 1.5)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(visit.title).herdrFont(.body, weight: .semibold).foregroundStyle(HerdrTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    FirstMateStatusLabel(status: snapshot.displayStatus(for: visit))
                }
                .frame(minHeight: 24)
                Text("\(isCurrent ? "Current · " : "")Visit \(index + 1) · revision \(visit.revision)")
                    .herdrFont(.footnote).foregroundStyle(isCurrent ? HerdrTheme.accent : HerdrTheme.tertiaryText)
                FirstMateResourceButtons(store: store, snapshot: snapshot, visit: visit)
            }
            .padding(.bottom, isLast ? 0 : 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
    }
}
