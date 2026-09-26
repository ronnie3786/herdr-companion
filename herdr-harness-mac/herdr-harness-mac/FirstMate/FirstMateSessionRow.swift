import SwiftUI

struct FirstMateSessionRow: View {
    @Bindable var store: FirstMateStore
    let session: FirstMateSession
    var body: some View {
        Button {
            Task { await store.open(.history(session)) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right").accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(session.kindDisplayName) · generation \(session.generation)")
                        .herdrFont(size: HerdrTheme.TextSize.small, weight: .medium)
                    Text("\(session.ownershipStatus.capitalized) · \(session.createdAt.prefix(10))")
                        .herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.secondaryText)
                    if let selection = session.modelSelection {
                        Label(selection.compactDisplayName, systemImage: "cpu")
                            .herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.secondaryText)
                            .help(selection.fullDisplayName)
                            .accessibilityLabel(selection.fullDisplayName)
                    }
                    Text(FirstMateUsageFormatting.inlineSummary(session.usage))
                        .herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.secondaryText)
                }
                Spacer()
                FirstMateStatusLabel(status: session.status)
            }.padding(.vertical, 8).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("first-mate-saved-session-\(session.nativeSessionID)")
    }
}
