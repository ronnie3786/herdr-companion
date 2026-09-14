import SwiftUI

struct FirstMateSessionHistoryView: View {
    @Bindable var store: FirstMateStore
    let resource: FirstMateResource

    private var sessions: [FirstMateSession] { store.snapshot?.sessions(for: resource.assignmentID) ?? [] }

    var body: some View {
        if !sessions.isEmpty {
            Menu {
                ForEach(sessions) { session in
                    Button {
                        Task { await store.open(.history(session)) }
                    } label: {
                        Label("Generation \(session.generation) · \(session.ownershipStatus) · \(session.createdAt.prefix(10))",
                              systemImage: resource.nativeSessionID == session.nativeSessionID ? "checkmark" : "bubble.left")
                    }
                    .help(session.nativeSessionID)
                }
            } label: {
                Label("Session history (\(sessions.count))", systemImage: "clock.arrow.circlepath")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("first-mate-session-history")
            .accessibilityHint("Open an earlier or current saved session for this agent")
        }
    }
}
