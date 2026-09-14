import SwiftUI

struct FirstMateSessionHistoryView: View {
    @Bindable var store: FirstMateStore
    let resource: FirstMateResource

    private var sessions: [FirstMateSession] { store.snapshot?.sessions(for: resource.assignmentID) ?? [] }

    var body: some View {
        if !sessions.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Earlier generations remain available after a handoff.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                    ForEach(sessions.reversed()) { session in
                        FirstMateSessionRow(store: store, session: session,
                                            isSelected: session.nativeSessionID == resource.nativeSessionID)
                        Divider()
                    }
                }
            } label: {
                Text("Session history · \(sessions.count)")
                    .accessibilityIdentifier("first-mate-session-history")
            }
            .font(.subheadline.weight(.medium))
            .padding(.vertical, 8)
        }
    }
}
