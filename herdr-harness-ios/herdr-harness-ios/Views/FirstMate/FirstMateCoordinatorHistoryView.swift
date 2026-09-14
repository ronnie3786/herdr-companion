import SwiftUI

struct FirstMateCoordinatorHistoryView: View {
    @Bindable var store: FirstMateStore
    let sessions: [FirstMateSession]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text("Your feature conversation stays together across these saved sessions.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ForEach(sessions.reversed()) { session in
                    FirstMateSessionRow(store: store, session: session)
                }
            }
            .padding(.top, 12)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Label("First Mate", systemImage: "sparkles").font(.headline)
                    .accessibilityIdentifier("first-mate-coordinator-history")
                Text("\(sessions.count) saved \(sessions.count == 1 ? "session" : "sessions")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
        }
        .padding(16)
        .background(FirstMatePalette(scheme: scheme).surface, in: .rect(cornerRadius: 18))
    }
}
