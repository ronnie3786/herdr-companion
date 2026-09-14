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
                    Text("Generation \(session.generation)").herdrFont(.subheadline, weight: .medium)
                    Text("\(session.ownershipStatus.capitalized) · \(session.createdAt.prefix(10))")
                        .herdrFont(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                FirstMateStatusLabel(status: session.status)
            }.padding(.vertical, 8).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("first-mate-saved-session-\(session.nativeSessionID)")
    }
}
