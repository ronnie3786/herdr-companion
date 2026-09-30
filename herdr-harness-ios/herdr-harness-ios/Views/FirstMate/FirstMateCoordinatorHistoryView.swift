import SwiftUI

struct FirstMateCoordinatorHistoryView: View {
    @Bindable var store: FirstMateStore
    let sessions: [FirstMateSession]
    var title = "First Mate coordinator"
    var symbol = "sparkles"
    var accessibilityID = "first-mate-coordinator-history"
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text("Retained coordinator and advisor sessions stay inspectable across handoffs.")
                    .font(.subheadline)
                    .foregroundStyle(HerdrTheme.secondaryText)
                ForEach(sessions.reversed()) { session in
                    FirstMateSessionRow(store: store, session: session)
                }
            }
            .padding(.top, 12)
        } label: {
            HStack(spacing: 8) {
                Label(title, systemImage: symbol).herdrFont(.body, weight: .semibold).foregroundStyle(HerdrTheme.primaryText)
                    .accessibilityIdentifier(accessibilityID)
                Spacer(minLength: 8)
                Text("\(sessions.count) saved \(sessions.count == 1 ? "session" : "sessions")")
                    .herdrFont(.footnote).foregroundStyle(HerdrTheme.tertiaryText)
            }
            .frame(minHeight: 44)
        }
        .tint(HerdrTheme.iconTint)
        Rectangle().fill(HerdrTheme.hairline).frame(height: 1)
        }
    }
}
