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
        .background(HerdrTheme.cardFill, in: .rect(cornerRadius: HerdrTheme.cardRadius))
        .clipShape(.rect(cornerRadius: HerdrTheme.cardRadius))
        .overlay { RoundedRectangle(cornerRadius: HerdrTheme.cardRadius).strokeBorder(HerdrTheme.outline) }
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                DashboardStatusPill(status: header.status, awaitingTurn: header.awaitingTurn)
                Text([entry.machineName, entry.feature.workItemID].compactMap { $0 }.joined(separator: " · "))
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(HerdrTheme.tertiaryText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isOffline, let seen = [state.lastContact, entry.lastUpdated].compactMap({ $0 }).max() {
                    HStack(spacing: 3) {
                        Text("Last seen")
                        DashboardAgeText(date: seen)
                    }
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(HerdrTheme.attention)
                    .fixedSize()
                    .help(state.loadError ?? entry.hostError ?? "")
                }
                DashboardIconButton(title: "Open in First Mate", systemImage: "arrow.up.left.and.arrow.down.right",
                                    help: "Open \(header.title) in First Mate", action: openFullView)
            }
            .frame(minHeight: HerdrTheme.ControlHeight.titleBar)
            Text(header.title)
                .herdrFont(size: HerdrTheme.TextSize.reading, weight: .semibold)
                .foregroundStyle(HerdrTheme.primaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(header.title)
                .accessibilityAddTraits(.isHeader)
            DashboardNowBlock(stageTitle: header.stageTitle, stageIndex: header.stageIndex, style: .column)
                .padding(.top, 10)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var tabs: some View {
        // MonoCode's `.atabs`: 12pt labels, the selected one ink with an ink underline.
        HStack(spacing: 0) {
            ForEach(AgentBoardTab.allCases) { tab in
                let selected = state.tab == tab
                Button {
                    state.tab = tab
                } label: {
                    HStack(spacing: 4) {
                        Text(tab.rawValue)
                        if tab == .agents, let count = state.content?.agents.count, count > 0 {
                            Text("\(count)").monospacedDigit()
                        }
                    }
                    .herdrFont(size: HerdrTheme.TextSize.small)
                    .foregroundStyle(selected ? HerdrTheme.primaryText : HerdrTheme.tertiaryText)
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(selected ? HerdrTheme.primaryText : .clear).frame(height: 2)
                    }
                    .padding(.horizontal, 8)
                    .contentShape(.rect)
                }
                .buttonStyle(.herdrPlain)
                .accessibilityLabel(tab.rawValue)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
        .frame(minHeight: HerdrTheme.ControlHeight.row)
        .fixedSize(horizontal: false, vertical: true)
        .herdrHairline(.bottom)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Views for \(header.title)")
    }

    private func banner(_ prompt: String, status: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: status == "blocked" ? "exclamationmark.triangle.fill" : "diamond.fill")
                .herdrFont(size: HerdrTheme.TextSize.micro)
                .foregroundStyle(HerdrTheme.attention)
                .padding(.top, 3)
                .accessibilityHidden(true)
            Text(prompt)
                .herdrFont(size: HerdrTheme.TextSize.small, weight: .medium)
                .foregroundStyle(HerdrTheme.primaryText)
                .lineSpacing(3)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(prompt)
            Button("Reply") {
                state.tab = .chat
                composerFocused = true
            }
                .buttonStyle(.herdrPlain)
                .herdrFont(size: HerdrTheme.TextSize.small, weight: .medium)
                .foregroundStyle(HerdrTheme.accent)
                .contentShape(.rect.inset(by: -6))
                .disabled(!canSend)
                .accessibilityLabel("Reply to \(header.title)")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(HerdrTheme.attentionSurface, in: .rect(cornerRadius: HerdrTheme.Radius.control))
        .overlay { RoundedRectangle(cornerRadius: HerdrTheme.Radius.control).strokeBorder(HerdrTheme.attentionEdge) }
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
                    .herdrFont(size: HerdrTheme.TextSize.small, weight: .medium)
                    .foregroundStyle(HerdrTheme.secondaryText)
                Text(error).herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.tertiaryText).lineLimit(3)
                Button("Try again") {
                    Task {
                        let capabilities = await capabilities()
                        await state.refresh(capabilities: capabilities, force: true)
                    }
                }
                .buttonStyle(.herdrPlain).foregroundStyle(HerdrTheme.accent)
                .frame(minHeight: HerdrTheme.minHitTarget)
                .contentShape(.rect)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                DashboardSkeletonBar(width: 240)
                DashboardSkeletonBar(width: 180)
                DashboardSkeletonBar(width: 210)
                Text("Loading conversation…").herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.tertiaryText)
            }
            .padding(12)
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
                    Button("Retry", action: send).buttonStyle(.herdrPlain).foregroundStyle(HerdrTheme.accent)
                        .frame(minHeight: HerdrTheme.minHitTarget)
                        .contentShape(.rect)
                }
                .herdrFont(size: HerdrTheme.TextSize.caption)
                .foregroundStyle(HerdrTheme.attention)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $state.draft, prompt: Text(""), axis: .vertical)
                    .textFieldStyle(.plain)
                    .herdrPlaceholder(placeholder, isVisible: state.draft.isEmpty, alignment: .topLeading)
                    .herdrFont(size: HerdrTheme.TextSize.body)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .onSubmit(send)
                    .onExitCommand { composerFocused = false }
                    .padding(.vertical, 6)
                    .accessibilityLabel("Message to \(header.title)")
                    .accessibilityIdentifier("agent-board-composer-\(entry.id)")
                Button(action: send) {
                    Image(systemName: state.isSending ? "ellipsis" : "arrow.up")
                }
                .buttonStyle(HerdrPrimarySquareButtonStyle())
                .disabled(!sendEnabled)
                .accessibilityLabel(state.isSending ? "Sending to \(header.title)" : "Send to \(header.title)")
                .help(canSend ? "Send direction to this First Mate" : sendUnavailableReason)
            }
            .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 4)
            .frame(minHeight: HerdrTheme.ControlHeight.bar)
            .background(HerdrTheme.cardFill, in: .rect(cornerRadius: HerdrTheme.composerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: HerdrTheme.composerRadius)
                    .strokeBorder(composerFocused ? HerdrTheme.focusOutline : HerdrTheme.outline)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
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
        Task {
            let store = state.resources(capabilities: await capabilities())
            await store.open(resource)
        }
    }

    private func openSession(_ session: FirstMateSession) {
        if openLiveSession(session.nativeSessionID) { return }
        Task {
            let store = state.resources(capabilities: await capabilities())
            await store.open(.history(session))
        }
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
