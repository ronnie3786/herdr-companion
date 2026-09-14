import SwiftUI

struct FirstMateAgentMenu: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    let visit: FirstMateVisit
    @Environment(\.colorScheme) private var scheme

    private var agents: [FirstMateAssignment] { snapshot.agents(for: visit.id) }
    private var countTitle: String { "\(agents.count) \(agents.count == 1 ? "agent" : "agents")" }

    var body: some View {
        Menu {
            Section(visit.title) {
                ForEach(agents) { agent in
                    let sessions = snapshot.sessions(for: agent.id)
                    if sessions.count > 1 {
                        Menu {
                            Button("Open current session", systemImage: "bubble.left.and.bubble.right") {
                                open(agent)
                            }
                            ForEach(sessions.reversed()) { session in
                                Button("Generation \(session.generation) · \(session.ownershipStatus)", systemImage: "clock.arrow.circlepath") {
                                    Task { await store.open(.history(session)) }
                                }
                            }
                        } label: {
                            Label(agent.title, systemImage: "person.crop.circle")
                        }
                    } else {
                        Button { open(agent) } label: {
                            Label(agent.title, systemImage: "person.crop.circle")
                        }
                        .disabled(agent.nativeSessionID == nil && sessions.isEmpty)
                    }
                }
            }
            Button("View this crew", systemImage: "person.2") {
                store.selectedVisitID = visit.id
                store.inspector = .agents
            }
        } label: {
            Label(countTitle, systemImage: "person.2")
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(FirstMatePalette(scheme: scheme).accent.opacity(0.08), in: .rect(cornerRadius: 12))
        }
        .disabled(agents.isEmpty)
        .accessibilityLabel("\(countTitle) for \(visit.title)")
        .accessibilityHint("Choose an agent to open its saved session")
        .accessibilityIdentifier("first-mate-visit-agents-\(visit.id)")
    }

    private func open(_ agent: FirstMateAssignment) {
        Task {
            if agent.nativeSessionID != nil { await store.open(.session(agent)) }
            else if let session = snapshot.sessions(for: agent.id).last { await store.open(.history(session)) }
        }
    }
}
