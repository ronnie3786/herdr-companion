import SwiftUI

struct AgentBoardAssignmentView: View {
    @Bindable var state: AgentBoardColumnState
    let agent: FirstMateAssignment
    let openLiveSession: (String) -> Bool

    private var resource: FirstMateResource? {
        if agent.nativeSessionID != nil { return .session(agent) }
        if let session = state.snapshot?.sessions(for: agent.id).last { return .history(session) }
        return nil
    }

    var body: some View {
        Button {
            if let sessionID = agent.nativeSessionID, openLiveSession(sessionID) { return }
            guard let resource else { return }
            Task { await state.resources.open(resource) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusColor)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(agent.title).herdrFont(.body).lineLimit(2)
                    Text("\(agent.role.replacingOccurrences(of: "_", with: " ")) · \(statusTitle)")
                        .herdrFont(.caption).foregroundStyle(HerdrTheme.muted)
                    if let verdict = agent.verdict, !verdict.isEmpty {
                        Text(verdict.replacingOccurrences(of: "_", with: " "))
                            .herdrFont(.caption).foregroundStyle(HerdrTheme.muted).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.right").foregroundStyle(HerdrTheme.accent)
                    .opacity(resource == nil ? 0 : 1)
            }
            .padding(12)
            .background(HerdrTheme.graphite, in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(resource == nil)
        .accessibilityLabel("\(agent.title), \(statusTitle)")
        .accessibilityHint(resource == nil ? "No saved session yet" : "Opens this agent's live chat or saved session")
    }

    private var statusTitle: String {
        switch agent.status {
        case "running", "starting": "Running"
        case "completed", "done", "finished": "Finished"
        case "failed": "Failed"
        case "pending", "queued", "waiting": "Waiting"
        default: agent.status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    private var statusSymbol: String {
        switch agent.status {
        case "running", "starting", "recovering": "circle.lefthalf.filled"
        case "completed", "done", "finished": "checkmark.circle"
        case "failed": "xmark.circle"
        default: "circle"
        }
    }
    private var statusColor: Color {
        switch agent.status {
        case "running", "starting", "recovering": HerdrTheme.signal
        case "completed", "done", "finished": HerdrTheme.success
        case "failed": HerdrTheme.warning
        default: HerdrTheme.muted
        }
    }
}
