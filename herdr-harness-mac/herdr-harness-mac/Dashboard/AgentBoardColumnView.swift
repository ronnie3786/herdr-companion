import SwiftUI

struct AgentBoardColumnView: View {
    @Bindable var model: HerdrAppModel
    let board: AgentBoardState
    @Bindable var state: AgentBoardColumnState
    let entry: DashboardFeatureEntry
    let demoSnapshot: FirstMateSnapshot?
    let openLiveSession: (String) -> Bool
    let openFullView: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @FocusState private var composerFocused: Bool

    /// Header facts come from whichever source is newer: the column's own board
    /// or the fleet list, so the column never contradicts its Dashboard card.
    private var header: Header {
        if let content = state.content, content.revision >= entry.feature.revision {
            return Header(status: content.status, awaitingTurn: content.awaitingTurn, title: content.title, stageTitle: content.stageTitle,
                          stageIndex: content.stageIndex, attention: content.attention,
                          acceptsMessages: content.acceptsMessages)
        }
        let summary = entry.summary
        return Header(status: entry.feature.status, awaitingTurn: entry.awaitingTurn, title: entry.title, stageTitle: summary?.currentStageTitle,
                      stageIndex: summary?.currentStageIndex,
                      attention: entry.needsAttention ? (entry.attentionPrompt ?? "Waiting for your direction.") : nil,
                      acceptsMessages: entry.isActive)
    }

    private struct Header {
        let status: String
        let awaitingTurn: Bool
        let title: String
        let stageTitle: String?
        let stageIndex: Int?
        let attention: String?
        let acceptsMessages: Bool
    }

    private var canSend: Bool { model.canControl(machineID: entry.machineID) && header.acceptsMessages }
    private var isOffline: Bool { entry.hostError != nil || (state.loadError != nil && state.content != nil) }
    private var observationID: String {
        "\(model.connectionGeneration)|\(model.isDemoMode)|\(scenePhase == .active)|\(isVisible)"
    }

    var body: some View {
        let header = header
        VStack(spacing: 0) {
            headerView(header)
            tabs
            if let attention = header.attention {
                banner(attention, status: header.status)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            composer
        }
        .background(HerdrTheme.elevated, in: .rect(cornerRadius: HerdrTheme.cardRadius))
        .clipShape(.rect(cornerRadius: HerdrTheme.cardRadius))
        .overlay { RoundedRectangle(cornerRadius: HerdrTheme.cardRadius).stroke(HerdrTheme.separator) }
        .onScrollVisibilityChange(threshold: 0.01) { isVisible = $0 }
        .task(id: observationID) { await observe() }
        .onChange(of: demoSnapshot) { _, snapshot in
            if let snapshot { state.receiveDemoSnapshot(snapshot) }
        }
        .sheet(item: resourcePresentation, onDismiss: { state.resourceStore?.closeResource() }) { _ in
            if let store = state.resourceStore, let resource = store.openedResource {
                FirstMateResourceSheet(store: store, resource: resource)
                    .id(resource.id)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(header.title)
        .accessibilityIdentifier("agent-board-column-\(entry.id)")
    }

    // MARK: - Header

    private func headerView(_ header: Header) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DashboardStatusPill(status: header.status, awaitingTurn: header.awaitingTurn)
                Text([entry.machineName, entry.feature.workItemID].compactMap { $0 }.joined(separator: " · "))
                    .herdrFont(.subheadline)
                    .foregroundStyle(HerdrTheme.muted)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isOffline, let seen = state.lastContact ?? entry.lastUpdated {
                    HStack(spacing: 3) {
                        Text("Last seen")
                        DashboardAgeText(date: seen)
                    }
                    .herdrFont(.subheadline)
                    .foregroundStyle(HerdrTheme.attention)
                    .fixedSize()
                    .help(state.loadError ?? entry.hostError ?? "")
                }
                DashboardIconButton(title: "Open in First Mate", systemImage: "arrow.up.left.and.arrow.down.right",
                                    help: "Open \(header.title) in First Mate", action: openFullView)
            }
            Text(header.title)
                .herdrFont(.title3, weight: .medium)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(header.title)
                .accessibilityAddTraits(.isHeader)
            DashboardNowBlock(stageTitle: header.stageTitle, stageIndex: header.stageIndex, style: .column)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(AgentBoardTab.allCases) { tab in
                let selected = state.tab == tab
                Button {
                    state.tab = tab
                } label: {
                    HStack(spacing: 4) {
                        Text(tab.rawValue)
                        if tab == .agents, let count = state.content?.agents.count, count > 0 {
                            Text("\(count)").monospacedDigit().foregroundStyle(HerdrTheme.muted)
                        }
                    }
                    .herdrFont(.callout, weight: selected ? .semibold : .regular)
                    .foregroundStyle(selected ? HerdrTheme.text : HerdrTheme.muted)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(selected ? HerdrTheme.accent : .clear).frame(height: 2)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.rawValue)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .overlay(alignment: .bottom) { Rectangle().fill(HerdrTheme.separator).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Views for \(header.title)")
    }

    private func banner(_ prompt: String, status: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: status == "blocked" ? "exclamationmark.triangle.fill" : "diamond.fill")
                .imageScale(.small)
                .foregroundStyle(HerdrTheme.attention)
                .padding(.top, 2)
                .accessibilityHidden(true)
            Text(prompt)
                .herdrFont(.callout, weight: .semibold)
                .foregroundStyle(HerdrTheme.text)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(prompt)
            Button("Reply") {
                state.tab = .chat
                composerFocused = true
            }
                .buttonStyle(.plain)
                .herdrFont(.callout, weight: .semibold)
                .foregroundStyle(HerdrTheme.accent)
                .disabled(!canSend)
                .accessibilityLabel("Reply to \(header.title)")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(HerdrTheme.attentionSurface, in: .rect(cornerRadius: HerdrTheme.nowRadius))
        .overlay { RoundedRectangle(cornerRadius: HerdrTheme.nowRadius).stroke(HerdrTheme.attentionEdge) }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let content = state.content {
            switch state.tab {
            case .chat:
                AgentBoardChatView(content: content, openFullView: openFullView)
            case .overview:
                AgentBoardOverviewView(content: content, showAgents: { state.tab = .agents }, openAgent: openAgent)
            case .agents:
                AgentBoardAgentsView(content: content, openAgent: openAgent, openSession: openSession)
            case .workflow:
                AgentBoardWorkflowView(content: content)
            }
        } else if let error = state.loadError ?? entry.hostError {
            VStack(alignment: .leading, spacing: 8) {
                Label("Couldn't load this conversation.", systemImage: "wifi.slash")
                    .herdrFont(.callout, weight: .medium)
                    .foregroundStyle(HerdrTheme.mist)
                Text(error).herdrFont(.subheadline).foregroundStyle(HerdrTheme.muted).lineLimit(3)
                Button("Try again") {
                    Task {
                        let capabilities = await capabilities()
                        await state.refresh(capabilities: capabilities, force: true)
                    }
                }
                .buttonStyle(.plain).foregroundStyle(HerdrTheme.accent)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                DashboardSkeletonBar(width: 240)
                DashboardSkeletonBar(width: 180)
                DashboardSkeletonBar(width: 210)
                Text("Loading conversation…").herdrFont(.subheadline).foregroundStyle(HerdrTheme.muted)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading conversation")
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = state.sendError {
                HStack(spacing: 6) {
                    Label(error, systemImage: "exclamationmark.circle")
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Button("Retry", action: send).buttonStyle(.plain).foregroundStyle(HerdrTheme.accent)
                }
                .herdrFont(.subheadline)
                .foregroundStyle(HerdrTheme.attention)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $state.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .herdrFont(.body)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .onSubmit(send)
                    .onExitCommand { composerFocused = false }
                    .padding(.vertical, 4)
                    .accessibilityLabel("Message to \(header.title)")
                    .accessibilityIdentifier("agent-board-composer-\(entry.id)")
                Button(action: send) {
                    Image(systemName: state.isSending ? "ellipsis" : "arrow.up")
                        .herdrFont(.callout, weight: .bold)
                        .foregroundStyle(sendEnabled ? .white : HerdrTheme.muted)
                        .frame(width: 26, height: 26)
                        .background(sendEnabled ? HerdrTheme.controlAccent : HerdrTheme.surface, in: .circle)
                }
                .buttonStyle(.plain)
                .disabled(!sendEnabled)
                .accessibilityLabel(state.isSending ? "Sending to \(header.title)" : "Send to \(header.title)")
                .help(canSend ? "Send direction to this First Mate" : sendUnavailableReason)
            }
            .padding(.leading, 12).padding(.trailing, 7).padding(.vertical, 7)
            .background(HerdrTheme.input, in: .rect(cornerRadius: HerdrTheme.composerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: HerdrTheme.composerRadius)
                    .stroke(composerFocused ? HerdrTheme.accent : HerdrTheme.separator)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var sendEnabled: Bool {
        canSend && !state.isSending && !state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var placeholder: String {
        if entry.hostError != nil { return "\(entry.machineName) is offline. Your draft is kept." }
        if !header.acceptsMessages { return "This feature is closed." }
        return "Give direction or ask a question…"
    }

    private var sendUnavailableReason: String {
        if !header.acceptsMessages { return "This feature is closed" }
        return "\(entry.machineName) is not connected"
    }

    // MARK: - Actions

    private var resourcePresentation: Binding<FirstMateResourcePresentation?> {
        Binding(
            get: { state.resourceStore?.resourcePresentation },
            set: { state.resourceStore?.resourcePresentation = $0 }
        )
    }

    private func openAgent(_ agent: AgentBoardContent.AgentRow) {
        if let sessionID = agent.assignment.nativeSessionID, openLiveSession(sessionID) { return }
        let resource: FirstMateResource? = agent.assignment.nativeSessionID != nil
            ? .session(agent.assignment) : agent.latestSession.map(FirstMateResource.history)
        guard let resource else { return }
        let store = state.resources()
        Task { await store.open(resource) }
    }

    private func openSession(_ session: FirstMateSession) {
        if openLiveSession(session.nativeSessionID) { return }
        let store = state.resources()
        Task { await store.open(.history(session)) }
    }

    private func capabilities() async -> FirstMateCapabilities? {
        let configuration = model.firstMateConfiguration(machineID: entry.machineID)
        return await board.capabilities(machineID: entry.machineID, configuration: configuration,
                                        generation: model.connectionGeneration,
                                        client: configuration.map { HerdrAPIClient(configuration: $0) })
    }

    private func observe() async {
        guard isVisible, scenePhase == .active else { return }
        let configuration = model.firstMateConfiguration(machineID: entry.machineID)
        state.configure(configuration: configuration, generation: model.connectionGeneration, demo: model.isDemoMode,
                        client: configuration.map { HerdrAPIClient(configuration: $0) }, demoSnapshot: demoSnapshot)
        await state.observe { await capabilities() }
    }

    private func send() {
        let generation = model.connectionGeneration
        let configuration = model.firstMateConfiguration(machineID: entry.machineID)
        let allowed = model.canControl(machineID: entry.machineID)
        let accepts = header.acceptsMessages
        Task {
            let capabilities = await capabilities()
            await state.send(configuration: configuration, generation: generation, canControl: allowed,
                             acceptsMessages: accepts, capabilities: capabilities) {
                model.connectionGeneration == generation
                    && model.firstMateConfiguration(machineID: entry.machineID) == configuration
                    && model.canControl(machineID: entry.machineID)
            }
        }
    }
}
