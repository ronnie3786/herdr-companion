import SwiftUI

/// A step's name with its status, and its revision underneath.
struct FirstMateVisitHeading: View {
    let visit: FirstMateVisit
    var isCurrent = false
    var displayStatus: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(visit.title).herdrFont(.body, weight: .semibold).foregroundStyle(HerdrTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                FirstMateStatusLabel(status: displayStatus ?? visit.status)
            }
            Text("\(isCurrent ? "Current · " : "")Revision \(visit.revision)")
                .herdrFont(.footnote).foregroundStyle(isCurrent ? HerdrTheme.accent : HerdrTheme.tertiaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
