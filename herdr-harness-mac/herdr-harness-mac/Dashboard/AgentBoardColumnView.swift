import SwiftUI

struct AgentBoardColumnView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var state: AgentBoardColumnState
    let entry: DashboardFeatureEntry
    let demoSnapshot: FirstMateSnapshot?
    let openLiveSession: (String) -> Bool
    let openFullView: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @FocusState private var composerFocused: Bool

    private var feature: FirstMateFeature { state.snapshot?.feature ?? entry.feature }
    private var needsAttention: Bool { FirstMateAttention.needsHumanDecision(status: feature.status) }
    private var summary: FirstMateDashboardSummary? {
        if let snapshot = state.snapshot {
            return snapshot.feature.dashboardSummary ?? .from(snapshot)
        }
        return entry.summary
    }
    private var canSend: Bool {
        model.canControl(machineID: entry.machineID) && state.snapshot != nil
            && !feature.isArchived && !["completed", "cancelled"].contains(feature.status)
    }
    private var observationID: String {
        "\(model.connectionGeneration)|\(model.isDemoMode)|\(scenePhase == .active)|\(isVisible)"
    }

    var body: some View {
        @Bindable var resources = state.resources
        VStack(spacing: 0) {
            header
            DashboardNowView(summary: summary, needsAttention: needsAttention)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            tabs
            if needsAttention { attention }
            if let error = state.error ?? entry.hostError {
                connectionNotice(error)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            composer
            footer
        }
        .background(HerdrTheme.elevated, in: .rect(cornerRadius: 12))
        .clipShape(.rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(needsAttention ? HerdrTheme.working.opacity(0.55) : HerdrTheme.separator, lineWidth: 1)
        }
        .onScrollVisibilityChange(threshold: 0.01) { isVisible = $0 }
        .task(id: observationID) {
            guard isVisible, scenePhase == .active else { return }
            let configuration = model.firstMateConfiguration(machineID: entry.machineID)
            state.configure(configuration: configuration, generation: model.connectionGeneration, demo: model.isDemoMode,
                            client: configuration.map { HerdrAPIClient(configuration: $0) }, demoSnapshot: demoSnapshot)
            await state.observe()
        }
        .onChange(of: demoSnapshot) { _, snapshot in
            if let snapshot { state.receiveDemoSnapshot(snapshot) }
        }
        .sheet(item: $resources.resourcePresentation, onDismiss: state.resources.closeResource) { _ in
            if let resource = state.resources.openedResource {
                FirstMateResourceSheet(store: state.resources, resource: resource)
                    .id(resource.id)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-board-column-\(entry.id)")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                DashboardStatusView(status: feature.status)
                Spacer(minLength: 6)
                Text(entry.machineName).lineLimit(1).foregroundStyle(HerdrTheme.muted)
                    .herdrFont(.caption)
                Button("Open full view", systemImage: "arrow.up.left.and.arrow.down.right", action: openFullView)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .frame(width: 28, height: 28)
                    .foregroundStyle(HerdrTheme.accent)
                    .help("Open \(feature.title) in First Mate")
            }
            Text(feature.title)
                .herdrFont(.headline, weight: needsAttention ? .semibold : .medium)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            Text(feature.workItemID ?? "Idea")
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.muted)
        }
        .padding(16)
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(AgentBoardTab.allCases) { tab in
                Button {
                    state.tab = tab
                } label: {
                    Text(tab.rawValue)
                        .herdrFont(.subheadline, weight: state.tab == tab ? .medium : .regular)
                        .foregroundStyle(state.tab == tab ? HerdrTheme.accent : HerdrTheme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .contentShape(.rect)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(state.tab == tab ? HerdrTheme.accent : .clear).frame(height: 2)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(tab.rawValue), \(feature.title)")
                .accessibilityAddTraits(state.tab == tab ? .isSelected : [])
            }
        }
        .overlay(alignment: .bottom) { Divider() }
    }

    private var attention: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.turn.down.right")
                .accessibilityHidden(true)
            Text(summary?.needsUserPrompt ?? "Waiting for your direction.")
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Reply") { composerFocused = true }
                .buttonStyle(.plain)
                .frame(minWidth: 38, minHeight: 28)
                .disabled(!canSend)
                .accessibilityLabel("Reply to \(feature.title)")
        }
        .herdrFont(.caption, weight: .medium)
        .foregroundStyle(HerdrTheme.working)
        .padding(12)
        .background(HerdrTheme.working.opacity(0.07))
    }

    private func connectionNotice(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(state.snapshot == nil ? "Connection unavailable" : "Showing last saved state", systemImage: "wifi.slash")
                .herdrFont(.caption, weight: .medium)
            if let lastUpdated = state.lastUpdated ?? entry.lastUpdated {
                Text("Last seen \(lastUpdated, style: .relative) ago").herdrFont(.caption2)
            }
            Text(error).herdrFont(.caption2).lineLimit(2)
        }
        .foregroundStyle(HerdrTheme.warning)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = state.snapshot {
            switch state.tab {
            case .chat: AgentBoardChatView(state: state, snapshot: snapshot, openFullView: openFullView)
            case .overview: AgentBoardOverviewView(state: state, snapshot: snapshot, openLiveSession: openLiveSession)
            case .agents: AgentBoardAgentsView(state: state, snapshot: snapshot, openLiveSession: openLiveSession)
            case .workflow: AgentBoardWorkflowView(snapshot: snapshot)
            }
        } else if state.error != nil || entry.hostError != nil {
            ContentUnavailableView("Conversation unavailable", systemImage: "bubble.left", description: Text("Your draft stays here while this companion reconnects."))
        } else {
            ProgressView("Loading conversation…")
                .controlSize(.small)
                .foregroundStyle(HerdrTheme.muted)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = state.sendError {
                Label(error, systemImage: "exclamationmark.circle")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.warning)
                    .textSelection(.enabled)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Give direction or ask a question…", text: $state.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .herdrFont(.body)
                    .lineLimit(2...5)
                    .focused($composerFocused)
                    .disabled(!canSend)
                    .onSubmit(send)
                    .accessibilityLabel("Message to \(feature.title)")
                    .accessibilityIdentifier("agent-board-composer-\(entry.id)")
                Button(action: send) {
                    Image(systemName: state.isSending ? "ellipsis" : "arrow.up")
                        .herdrFont(.body, weight: .semibold)
                        .frame(width: 30, height: 30)
                        .foregroundStyle(.white)
                        .background(HerdrTheme.controlAccent, in: .rect(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(!canSend || state.isSending || state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(state.isSending ? "Sending to \(feature.title)" : "Send to \(feature.title)")
                .help("Send direction to this First Mate")
            }
            .padding(12)
            .background(HerdrTheme.input, in: .rect(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).stroke(composerFocused ? HerdrTheme.accent : HerdrTheme.separator) }
        }
        .padding(12)
        .overlay(alignment: .top) { Divider() }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(summary?.assignmentCount ?? 0) agents · \(summary?.runningAssignmentCount ?? 0) running")
                Spacer(minLength: 4)
                Button("Open full view", action: openFullView).buttonStyle(.plain).foregroundStyle(HerdrTheme.accent)
            }
            if let lastUpdated = state.lastUpdated ?? entry.lastUpdated {
                Text("Updated \(lastUpdated, style: .relative) ago")
            }
        }
        .herdrFont(.caption2)
        .foregroundStyle(HerdrTheme.muted)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private func send() {
        let generation = model.connectionGeneration
        let configuration = model.firstMateConfiguration(machineID: entry.machineID)
        let allowed = canSend
        Task {
            await state.send(configuration: configuration, generation: generation, canControl: allowed) {
                model.connectionGeneration == generation
                    && model.firstMateConfiguration(machineID: entry.machineID) == configuration
                    && model.canControl(machineID: entry.machineID)
            }
        }
    }
}
