import SwiftUI

struct FirstMateVisitHeading: View {
    let visit: FirstMateVisit
    var isCurrent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(visit.title).font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    FirstMateStatusLabel(status: visit.status)
                        .fixedSize(horizontal: true, vertical: true)
                    Text("Revision \(visit.revision)").font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: true)
                }
                VStack(alignment: .leading, spacing: 8) {
                    FirstMateStatusLabel(status: visit.status)
                    Text("Revision \(visit.revision)").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
