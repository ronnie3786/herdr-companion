import Foundation
import Security
import Testing
@testable import herdr_harness_mac

@MainActor
struct AgentControlRoutingTests {
    @Test("PR Review agent-control segment routes to its dedicated destination")
    func prReviewSegmentRoutesToDedicatedDestination() async throws {
        let fixture = makeFixture()

        _ = try await fixture.controller.executeForTesting(
            command(action: "ui.segment", parameters: ["segment": .string("pr-review")]),
            serverMapping: [:]
        )

        #expect(fixture.shell.detailScope == .prReview)
    }

    @Test("PR Review scrolling validates files and reports applied visibility")
    func prReviewScrollWaitsForVisibleLine() async throws {
        let fixture = makeFixture()
        fixture.shell.configurePRReviewIfNeeded(
            configuration: nil,
            machineID: "demo",
            connectionGeneration: fixture.model.connectionGeneration,
            isDemo: true
        )
        await fixture.shell.prReview.refresh()
        fixture.shell.show(.prReview, model: fixture.model)
        let path = try #require(fixture.shell.prReview.snapshot?.files.first?.path)
        fixture.shell.prReview.visibleLines = (path, 1, 100, .after)

        let result = try await fixture.controller.executeForTesting(
            command(action: "pr-review.scroll-to-line", parameters: ["path": .string(path), "line": .number(5)]),
            serverMapping: [:]
        )

        #expect(result.values["visible"] == .bool(true))
        await #expect(throws: AgentControlCommandError.self) {
            try await fixture.controller.executeForTesting(
                command(action: "pr-review.scroll-to-line", parameters: ["path": .string("Sources/Missing.swift"), "line": .number(5)]),
                serverMapping: [:]
            )
        }
    }

    @Test("Exact pane routing rejects stale terminal, session, and server identities while accepting CLI aliases")
    func staleIdentityRejection() async throws {
        let fixture = makeFixture()
        let pane = try #require(fixture.model.workspaces.first?.panes.first)
        let exact = target(for: pane, serverID: "srv_demo")

        var staleTerminal = exact
        staleTerminal.terminalId = "term_reused"
        await #expect(throws: AgentControlCommandError.self) {
            try await fixture.controller.executeForTesting(
                command(action: "ui.open", target: staleTerminal, parameters: ["view": .string("terminal")]),
                serverMapping: ["srv_demo": pane.machineID]
            )
        }

        var staleSession = exact
        staleSession.sessionId = "session_that_is_not_live"
        await #expect(throws: AgentControlCommandError.self) {
            try await fixture.controller.executeForTesting(
                command(action: "ui.open", target: staleSession, parameters: ["view": .string("terminal")]),
                serverMapping: ["srv_demo": pane.machineID]
            )
        }

        var configuredAlias = exact
        configuredAlias.machineId = "cli-roster-alias"
        _ = try await fixture.controller.executeForTesting(
            command(action: "ui.open", target: configuredAlias, parameters: ["view": .string("terminal")]),
            serverMapping: ["srv_demo": pane.machineID]
        )

        var wrongServer = exact
        wrongServer.serverId = "srv_other"
        await #expect(throws: AgentControlCommandError.self) {
            try await fixture.controller.executeForTesting(
                command(action: "ui.open", target: wrongServer, parameters: ["view": .string("terminal")]),
                serverMapping: ["srv_demo": pane.machineID]
            )
        }
    }

    @Test("An old expected revision cannot race a newer human selection")
    func revisionRace() async throws {
        let fixture = makeFixture()
        let oldRevision = fixture.controller.currentState().revision
        fixture.shell.show(.activity, model: fixture.model)
        fixture.controller.stateDidChange()
        var request = command(action: "ui.segment", parameters: ["segment": .string("attention")])
        request.expectedRevision = oldRevision

        await #expect(throws: AgentControlCommandError.self) {
            try await fixture.controller.executeForTesting(request, serverMapping: [:])
        }
        #expect(fixture.shell.detailScope == .activity)
    }

    @Test("Git and Terminal stay on the same exact pane and produce distinct history stops")
    func samePaneModeTransitions() async throws {
        let fixture = makeFixture()
        let pane = try #require(fixture.model.workspaces.first?.panes.first)
        let exact = target(for: pane, serverID: "srv_demo")

        _ = try await fixture.controller.executeForTesting(
            command(action: "ui.open", target: exact, parameters: ["view": .string("git")]),
            serverMapping: ["srv_demo": pane.machineID]
        )
        #expect(fixture.model.selectedPaneID == pane.id)
        #expect(fixture.model.isPresentingPane(id: pane.id, mode: .git))
        #expect(fixture.controller.currentState().segment == "git")
        #expect(fixture.controller.currentState().selection?.paneId == pane.paneID)
        #expect(fixture.shell.history.current == .git(pane.id))

        _ = try await fixture.controller.executeForTesting(
            command(action: "ui.segment", parameters: ["segment": .string("terminal")]),
            serverMapping: ["srv_demo": pane.machineID]
        )
        #expect(fixture.model.selectedPaneID == pane.id)
        #expect(fixture.model.isPresentingPane(id: pane.id, mode: .terminal))
        #expect(fixture.shell.history.current == .pane(pane.id))
    }

    @Test("Automation mode requests do not override later human navigation or history")
    func automationThenHumanNavigation() async throws {
        let fixture = makeFixture()
        let panes = fixture.model.workspaces.flatMap(\.panes)
        let first = try #require(panes.first)
        let second = try #require(panes.dropFirst().first)

        _ = try await fixture.controller.executeForTesting(
            command(action: "ui.open", target: target(for: first, serverID: "srv_demo"), parameters: ["view": .string("git")]),
            serverMapping: ["srv_demo": first.machineID]
        )
        fixture.shell.openPane(id: first.id, model: fixture.model)
        fixture.model.notePaneDetailMode(.chat, gitIsAvailable: true, for: first.id)
        #expect(fixture.shell.agentControlPaneMode == nil)
        #expect(fixture.model.isPresentingPane(id: first.id, mode: .chat))

        _ = try await fixture.controller.executeForTesting(
            command(action: "ui.open", target: target(for: first, serverID: "srv_demo"), parameters: ["view": .string("terminal")]),
            serverMapping: ["srv_demo": first.machineID]
        )
        fixture.shell.openPane(id: second.id, model: fixture.model)
        fixture.model.notePaneDetailMode(.chat, gitIsAvailable: true, for: second.id)
        #expect(fixture.shell.agentControlPaneMode == nil)
        #expect(fixture.model.selectedPaneID == second.id)

        #expect(fixture.shell.goBack(model: fixture.model))
        fixture.model.notePaneDetailMode(.terminal, gitIsAvailable: true, for: first.id)
        #expect(fixture.shell.goForward(model: fixture.model))
        fixture.model.notePaneDetailMode(.chat, gitIsAvailable: true, for: second.id)
        #expect(fixture.model.selectedPaneID == second.id)
        #expect(fixture.model.currentPaneDetailMode == .chat)
    }

    @Test("A pane route does not complete from a requested mode without presentation acknowledgement")
    func requiresActualPresentation() async throws {
        let suite = "AgentControlPresentationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "herdr.agentControl.enabled.v1")
        let model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"], userDefaults: defaults)
        let shell = HerdrShellState(userDefaults: defaults)
        let controller = AgentControlController(
            defaults: defaults,
            secretStorage: TestAgentControlSecretStorage(),
            presentationWaiter: { _, _, _ in false }
        )
        controller.configure(
            model: model,
            shell: shell,
            hudController: HerdrHudController(userDefaults: defaults),
            openMainWindow: {},
            openSettingsWindow: {}
        )
        let pane = try #require(model.workspaces.first?.panes.first)

        await #expect(throws: AgentControlCommandError.self) {
            try await controller.executeForTesting(
                command(action: "ui.open", target: target(for: pane, serverID: "srv_demo"), parameters: ["view": .string("terminal")]),
                serverMapping: ["srv_demo": pane.machineID]
            )
        }
        #expect(!model.isPresentingPane(id: pane.id, mode: .terminal))
    }

    @Test("History pane navigation does not complete from requested state alone")
    func historyRequiresActualPresentation() async throws {
        let suite = "AgentControlHistoryPresentationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "herdr.agentControl.enabled.v1")
        let model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"], userDefaults: defaults)
        let shell = HerdrShellState(userDefaults: defaults)
        let controller = AgentControlController(
            defaults: defaults,
            secretStorage: TestAgentControlSecretStorage(),
            presentationWaiter: { _, _, _ in false }
        )
        controller.configure(
            model: model,
            shell: shell,
            hudController: HerdrHudController(userDefaults: defaults),
            openMainWindow: {},
            openSettingsWindow: {}
        )
        let panes = model.workspaces.flatMap(\.panes)
        let first = try #require(panes.first)
        let second = try #require(panes.dropFirst().first)
        shell.openPane(id: first.id, model: model)
        shell.openPane(id: second.id, model: model)

        await #expect(throws: AgentControlCommandError.self) {
            try await controller.executeForTesting(command(action: "ui.back"), serverMapping: [:])
        }
        #expect(model.selectedPaneID == first.id)
        #expect(!model.isPresentingPane(id: first.id, mode: first.supportsPiSemanticChat ? .chat : .terminal))
    }

    @Test("Back and Forward wait for the rendered Git and Chat history destinations")
    func renderedHistoryDestinations() async throws {
        let fixture = try await makeHistoryFixture()
        let panes = fixture.model.workspaces.flatMap(\.panes)
        let gitPane = try #require(panes.first(where: { $0.paneID == "git-pane" }))
        let chatPane = try #require(panes.first(where: {
            $0.paneID == "chat-pane" && $0.supportsPiSemanticChat
        }))

        _ = try await fixture.controller.executeForTesting(
            command(action: "ui.open", target: target(for: gitPane, serverID: "srv_history"), parameters: ["view": .string("git")]),
            serverMapping: ["srv_history": gitPane.machineID]
        )
        _ = try await fixture.controller.executeForTesting(
            command(action: "ui.open", target: target(for: chatPane, serverID: "srv_history"), parameters: ["view": .string("chat")]),
            serverMapping: ["srv_history": chatPane.machineID]
        )
        _ = try await fixture.controller.executeForTesting(command(action: "ui.back"), serverMapping: [:])
        #expect(fixture.model.isPresentingPane(id: gitPane.id, mode: .git))
        #expect(fixture.shell.history.current == .git(gitPane.id))

        _ = try await fixture.controller.executeForTesting(command(action: "ui.forward"), serverMapping: [:])
        #expect(fixture.model.isPresentingPane(id: chatPane.id, mode: .chat))
        #expect(fixture.shell.history.current == .pane(chatPane.id))
    }

    @Test("Same-host First Mate feature navigation preserves cached drafts")
    func sameHostFirstMateNavigationPreservesDrafts() throws {
        let store = FirstMateStore()
        store.configure(client: nil, demo: true)
        let first = try #require(store.features.first)
        let second = FirstMateDemo.newFeature(
            title: "Synthetic second feature",
            goal: "Verify draft isolation",
            cwd: "/tmp/synthetic",
            id: "synthetic-second"
        )
        store.receive(second)
        store.select(first.id)
        store.draft = "unsent first-feature direction"
        store.select(second.feature.id)

        #expect(store.draft.isEmpty)
        #expect(store.hasUnsentDrafts)
        // This is the same operation the navigation-request task performs. It
        // deliberately does not call configure for another feature on one host.
        store.select(first.id)
        #expect(store.draft == "unsent first-feature direction")
    }

    @Test("Recreating a window with the same First Mate identity preserves every draft")
    func firstMateConnectionGuardSurvivesWindowRecreation() throws {
        let suite = "FirstMateConnectionGuardTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let shell = HerdrShellState(userDefaults: defaults)
        let configurationA = try #require(ServerConfiguration(
            urlString: "https://first-mate-a.example.invalid",
            token: "synthetic-token-a"
        ))
        let configurationB = try #require(ServerConfiguration(
            urlString: "https://first-mate-b.example.invalid",
            token: "synthetic-token-b"
        ))
        let first = try #require(FirstMateDemo.features(step: 0).first)
        let second = FirstMateDemo.newFeature(
            title: "Synthetic second feature",
            goal: "Verify process-owned connection identity",
            cwd: "/tmp/synthetic",
            id: "synthetic-second"
        )
        let clientA = SyntheticFirstMateClient(snapshot: first)
        let clientB = SyntheticFirstMateClient(snapshot: second)

        #expect(shell.configureFirstMateIfNeeded(
            configuration: configurationA,
            connectionGeneration: 1,
            isDemo: false,
            client: clientA
        ))
        shell.firstMate.receive(first)
        shell.firstMate.receive(second)
        shell.firstMate.select(first.feature.id)
        shell.firstMate.draft = "unsent feature A direction"
        shell.firstMate.select(second.feature.id)
        shell.firstMate.draft = "unsent feature B direction"
        let selectionBeforeRecreation = shell.firstMate.selectedFeatureID

        #expect(!shell.configureFirstMateIfNeeded(
            configuration: configurationA,
            connectionGeneration: 1,
            isDemo: false,
            client: clientA
        ))
        #expect(shell.firstMate.selectedFeatureID == selectionBeforeRecreation)
        #expect(shell.firstMate.draft == "unsent feature B direction")
        shell.firstMate.select(first.feature.id)
        #expect(shell.firstMate.draft == "unsent feature A direction")
        shell.firstMate.select(second.feature.id)
        #expect(shell.firstMate.draft == "unsent feature B direction")

        #expect(shell.configureFirstMateIfNeeded(
            configuration: configurationB,
            connectionGeneration: 2,
            isDemo: false,
            client: clientB
        ))
        #expect(!shell.configureFirstMateIfNeeded(
            configuration: configurationB,
            connectionGeneration: 2,
            isDemo: false,
            client: clientB
        ))
        #expect(shell.firstMate.features.isEmpty)
        #expect(shell.firstMate.selectedFeatureID == nil)
        #expect(!shell.firstMate.hasUnsentDrafts)
    }

    @Test("Agent navigation records First Mate identity before opening a recreated window")
    func firstMateAgentNavigationCommitsBeforeWindowOpen() async throws {
        let suite = "FirstMateAgentWindowRecreationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "herdr.agentControl.enabled.v1")
        let machine = HerdrMachine(
            id: "synthetic-first-mate",
            name: "Synthetic First Mate",
            urlString: "https://first-mate.example.invalid"
        )
        let credentials = TestCredentialStore()
        credentials.values["api-token.\(machine.id)"] = "synthetic-token"
        let model = HerdrAppModel(
            credentials: credentials,
            arguments: ["HerdrTests"],
            userDefaults: defaults,
            configuredMachines: []
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [FirstMateFleetURLProtocol.self]
        let fleetClient = HerdrAPIClient(
            configuration: try #require(ServerConfiguration(
                urlString: machine.urlString,
                token: "synthetic-token"
            )),
            session: URLSession(configuration: sessionConfiguration)
        )
        model.machines = [machine]
        model.clientFactory = { _ in fleetClient }
        model.prepareRuntime(for: machine, generation: model.connectionGeneration)
        model.machineStates[machine.id] = .live
        let configuration = try #require(model.firstMateConfiguration(machineID: machine.id))
        let snapshot = FirstMateDemo.newFeature(
            title: "Exact synthetic feature",
            goal: "Survive synchronous window creation",
            cwd: "/tmp/synthetic",
            id: "feature-window-recreation"
        )
        let firstMateClient = SyntheticFirstMateClient(snapshot: snapshot)
        let shell = HerdrShellState(userDefaults: defaults)
        var selectionAtWindowOpen: String?
        var repeatedConfigurationChanged: Bool?
        var draftAfterWindowTask: String?
        let controller = AgentControlController(
            defaults: defaults,
            secretStorage: TestAgentControlSecretStorage(),
            firstMateClientFactory: { _ in firstMateClient }
        )
        controller.configure(
            model: model,
            shell: shell,
            hudController: HerdrHudController(userDefaults: defaults),
            openMainWindow: {
                selectionAtWindowOpen = shell.firstMate.selectedFeatureID
                shell.firstMate.draft = "draft created while rebuilding the window"
                repeatedConfigurationChanged = shell.configureFirstMateIfNeeded(
                    machineID: machine.id,
                    configuration: configuration,
                    connectionGeneration: model.connectionGeneration,
                    isDemo: false,
                    client: firstMateClient
                )
                draftAfterWindowTask = shell.firstMate.draft
            },
            openSettingsWindow: {}
        )
        let target = AgentControlTarget(
            kind: "first-mate",
            serverId: "srv_first_mate",
            machineId: "cli-synthetic-alias",
            featureId: snapshot.feature.id,
            generation: model.connectionGeneration
        )

        _ = try await controller.executeForTesting(
            command(
                action: "ui.open",
                target: target,
                parameters: ["inspector": .string("documents")]
            ),
            serverMapping: ["srv_first_mate": machine.id]
        )

        #expect(selectionAtWindowOpen == snapshot.feature.id)
        #expect(repeatedConfigurationChanged == false)
        #expect(draftAfterWindowTask == "draft created while rebuilding the window")
        #expect(shell.firstMate.selectedFeatureID == snapshot.feature.id)
        #expect(shell.firstMate.inspector == .documents)
        #expect(shell.firstMate.draft == "draft created while rebuilding the window")
    }

    @Test("A First Mate host switch rejects any cached feature draft before mutation")
    func firstMateHostSwitchGuardsAllDrafts() throws {
        let store = FirstMateStore()
        store.configure(client: nil, demo: true)
        let first = try #require(store.features.first)
        let second = FirstMateDemo.newFeature(
            title: "Synthetic second feature",
            goal: "Verify host-switch guard",
            cwd: "/tmp/synthetic",
            id: "synthetic-second"
        )
        store.receive(second)
        store.select(first.id)
        store.draft = "saved on another feature"
        store.select(second.feature.id)
        let selectedBefore = store.selectedFeatureID
        let featuresBefore = store.features

        #expect(throws: AgentControlCommandError.self) {
            try AgentControlController.validateFirstMateHostSwitch(
                store: store,
                currentMachineID: "host-one",
                targetMachineID: "host-two"
            )
        }
        #expect(store.selectedFeatureID == selectedBefore)
        #expect(store.features == featuresBefore)
        #expect(store.hasUnsentDrafts)
        try AgentControlController.validateFirstMateHostSwitch(
            store: store,
            currentMachineID: "host-one",
            targetMachineID: "host-one"
        )
    }

    @Test("Opening a tab shows and highlights its overview without choosing a pane")
    func exactTabOverview() async throws {
        let fixture = makeFixture()
        let workspace = try #require(fixture.model.workspaces.first)
        let tab = try #require(workspace.tabs.first)
        let target = AgentControlTarget(
            kind: "tab",
            serverId: "srv_demo",
            machineId: workspace.machineID,
            workspaceId: workspace.workspaceID,
            tabId: tab.tabID,
            generation: fixture.model.connectionGeneration
        )

        _ = try await fixture.controller.executeForTesting(
            command(action: "ui.open", target: target),
            serverMapping: ["srv_demo": workspace.machineID]
        )
        #expect(fixture.shell.detailScope == .workspace)
        #expect(fixture.model.selectedWorkspaceID == workspace.id)
        #expect(fixture.model.selectedPaneID == nil)
        #expect(fixture.shell.highlightedOverviewTabID == tab.id)
        #expect(fixture.controller.currentState().selection?.kind == "tab")
        #expect(fixture.controller.currentState().selection?.tabId == tab.tabID)
    }

    @Test("Exact pane switches retain each pane's unsent draft")
    func paneSwitchDraftPreservation() async throws {
        let fixture = makeFixture()
        let panes = fixture.model.workspaces.flatMap(\.panes)
        let source = try #require(panes.first)
        let destination = try #require(panes.dropFirst().first)
        fixture.model.setComposerDraft("synthetic unsent draft", for: source.id)

        _ = try await fixture.controller.executeForTesting(
            command(action: "ui.open", target: target(for: destination, serverID: "srv_demo"), parameters: ["view": .string("terminal")]),
            serverMapping: ["srv_demo": destination.machineID]
        )
        let focusRequestAfterAcknowledgement = fixture.shell.paneModeFocusRequest
        fixture.shell.selectedPaneDidChange(model: fixture.model)
        #expect(fixture.shell.paneModeFocusRequest == focusRequestAfterAcknowledgement)
        _ = try await fixture.controller.executeForTesting(
            command(action: "ui.open", target: target(for: source, serverID: "srv_demo"), parameters: ["view": .string("terminal")]),
            serverMapping: ["srv_demo": source.machineID]
        )

        #expect(fixture.model.selectedPaneID == source.id)
        #expect(fixture.model.composerDraft(for: source.id) == "synthetic unsent draft")
    }

    @Test("Blocked navigation preserves the open modal and every pane draft")
    func modalAndDraftPreservation() async throws {
        let fixture = makeFixture()
        let panes = fixture.model.workspaces.flatMap(\.panes)
        let source = try #require(panes.first)
        let destination = try #require(panes.dropFirst().first)
        fixture.model.setComposerDraft("synthetic unsent draft", for: source.id)
        fixture.shell.isCreatingWorkspace = true

        await #expect(throws: AgentControlCommandError.self) {
            try await fixture.controller.executeForTesting(
                command(action: "ui.open", target: target(for: destination, serverID: "srv_demo"), parameters: ["view": .string("terminal")]),
                serverMapping: ["srv_demo": destination.machineID]
            )
        }
        #expect(fixture.shell.isCreatingWorkspace)
        #expect(fixture.model.composerDraft(for: source.id) == "synthetic unsent draft")
    }

    @Test("Mark unread executes without a second confirmation callback")
    func noExtraConfirmation() async throws {
        let fixture = makeFixture()
        let pane = try #require(fixture.model.workspaces.first?.panes.first)
        _ = try await fixture.controller.executeForTesting(
            command(action: "chat.mark-unread", target: target(for: pane, serverID: "srv_demo")),
            serverMapping: ["srv_demo": pane.machineID]
        )
        #expect(fixture.model.manuallyUnreadPaneIDs.contains(pane.id))
    }

    private func makeHistoryFixture() async throws -> (
        controller: AgentControlController,
        model: HerdrAppModel,
        shell: HerdrShellState
    ) {
        let suite = "AgentControlHistoryRoutingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "herdr.agentControl.enabled.v1")
        defaults.set(true, forKey: "herdr.completedSetup")
        let machine = HerdrMachine(
            id: "history-machine",
            name: "Synthetic History",
            urlString: "https://history.example.invalid"
        )
        let credentials = TestCredentialStore()
        credentials.values["api-token.\(machine.id)"] = "synthetic-token"
        let model = HerdrAppModel(
            credentials: credentials,
            arguments: ["HerdrTests"],
            userDefaults: defaults,
            configuredMachines: [machine]
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [HistoryRoutingURLProtocol.self]
        let client = HerdrAPIClient(
            configuration: try #require(ServerConfiguration(
                urlString: machine.urlString,
                token: "synthetic-token"
            )),
            session: URLSession(configuration: sessionConfiguration)
        )
        model.clientFactory = { _ in client }
        model.prepareRuntime(for: machine, generation: model.connectionGeneration)
        try await model.refreshForAgentControl(machineID: machine.id)

        let shell = HerdrShellState(userDefaults: defaults)
        let controller = AgentControlController(
            defaults: defaults,
            secretStorage: TestAgentControlSecretStorage(),
            presentationWaiter: { expectation, model, shell in
                switch expectation {
                case let .pane(id, mode):
                    model.notePaneDetailMode(mode, gitIsAvailable: true, for: id)
                    shell.agentControlPaneModeDidApply(mode, paneID: id)
                    return model.isPresentingPane(id: id, mode: mode)
                }
            }
        )
        controller.configure(
            model: model,
            shell: shell,
            hudController: HerdrHudController(userDefaults: defaults),
            openMainWindow: {},
            openSettingsWindow: {}
        )
        return (controller, model, shell)
    }

    private func makeFixture() -> (controller: AgentControlController, model: HerdrAppModel, shell: HerdrShellState) {
        let suite = "AgentControlRoutingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "herdr.agentControl.enabled.v1")
        let model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"], userDefaults: defaults)
        let shell = HerdrShellState(userDefaults: defaults)
        let controller = AgentControlController(
            defaults: defaults,
            secretStorage: TestAgentControlSecretStorage(),
            presentationWaiter: { expectation, model, shell in
                switch expectation {
                case let .pane(id, mode):
                    model.notePaneDetailMode(mode, gitIsAvailable: true, for: id)
                    shell.agentControlPaneModeDidApply(mode, paneID: id)
                    return model.isPresentingPane(id: id, mode: mode)
                }
            }
        )
        controller.configure(
            model: model,
            shell: shell,
            hudController: HerdrHudController(userDefaults: defaults),
            openMainWindow: {},
            openSettingsWindow: {}
        )
        return (controller, model, shell)
    }

    private func target(for pane: HerdrPane, serverID: String) -> AgentControlTarget {
        AgentControlTarget(
            kind: "pane",
            serverId: serverID,
            machineId: pane.machineID,
            workspaceId: pane.workspaceID,
            tabId: pane.tabID,
            paneId: pane.paneID,
            terminalId: pane.terminalID,
            sessionId: pane.piSemantic?.sessionID,
            generation: 0
        )
    }

    private func command(
        action: String,
        target: AgentControlTarget? = nil,
        parameters: [String: PiJSONValue] = [:]
    ) -> AgentControlCommand {
        AgentControlCommand(
            requestId: UUID().uuidString,
            clientId: "ui_test",
            instanceId: "instance",
            action: action,
            target: target,
            parameters: parameters,
            expectedRevision: nil,
            status: "running",
            createdAt: "2030-01-01T00:00:00Z",
            expiresAt: "2030-01-01T00:00:30Z",
            result: nil,
            error: nil
        )
    }
}

private final class SyntheticFirstMateClient: FirstMateClient, @unchecked Sendable {
    let snapshot: FirstMateSnapshot

    init(snapshot: FirstMateSnapshot) {
        self.snapshot = snapshot
    }

    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList {
        .init(ok: true, features: [snapshot.feature])
    }

    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot {
        guard id == snapshot.feature.id else { throw APIError.invalidResponse }
        return snapshot
    }

    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot {
        throw APIError.invalidResponse
    }

    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot {
        throw APIError.invalidResponse
    }

    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot {
        throw APIError.invalidResponse
    }

    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse {
        throw APIError.invalidResponse
    }

    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse {
        throw APIError.invalidResponse
    }
}

private final class HistoryRoutingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response: (status: Int, body: String)
        switch url.path {
        case "/api/v1/workspaces":
            response = (200, #"{"ok":true,"workspaces":[{"workspace_id":"history-workspace","number":1,"label":"Synthetic history","focused":true,"pane_count":2,"tab_count":1,"active_tab_id":"history-tab","agent_status":"idle","panes":[{"pane_id":"git-pane","terminal_id":"git-terminal","workspace_id":"history-workspace","tab_id":"history-tab","focused":true,"agent_status":"idle","revision":1,"cwd":"/tmp/synthetic-history","label":"Synthetic Git pane"},{"pane_id":"chat-pane","terminal_id":"chat-terminal","workspace_id":"history-workspace","tab_id":"history-tab","focused":false,"agent_status":"idle","revision":1,"cwd":"/tmp/synthetic-history","label":"Synthetic Pi pane","agent":"pi","display_agent":"Pi","pi_semantic":{"available":true,"connected":true,"protocol_version":1,"session_id":"synthetic-history-session"}}]}],"alerts":[]}"#)
        case "/api/v1/panes/git-pane/git":
            response = (200, #"{"ok":true,"workspace_id":"history-workspace","root_path":"/tmp/synthetic-history","branch":"synthetic/history","staged":[],"unstaged":[],"untracked":[],"commits":[]}"#)
        default:
            response = (404, #"{"ok":false,"error":{"code":"not_found","message":"Synthetic route not found"}}"#)
        }
        let http = HTTPURLResponse(
            url: url,
            statusCode: response.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class FirstMateFleetURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let isFleetRequest = request.url?.path == "/api/v1/workspaces"
        let status = isFleetRequest ? 200 : 404
        let body = isFleetRequest
            ? #"{"ok":true,"workspaces":[],"alerts":[]}"#
            : #"{"ok":false,"error":{"code":"not_found","message":"Synthetic route not found"}}"#
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct TestAgentControlSecretStorage: AgentControlSecretStorage {
    var readStatus: OSStatus = errSecItemNotFound
    var value: String? = nil

    func read(for account: String) -> AgentControlSecretRead {
        AgentControlSecretRead(status: readStatus, value: value)
    }

    func set(_ value: String, for account: String) -> OSStatus { errSecSuccess }
}
