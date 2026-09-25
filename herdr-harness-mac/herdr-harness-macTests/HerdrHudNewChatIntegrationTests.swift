import Foundation
import Synchronization
import Testing
@testable import herdr_harness_mac

/// End-to-end tests for the two fresh-composer outcomes from issue #61:
/// a new chat starts on this Mac's declared default model, and the
/// "Create in main workspace" checkbox routes the submission through the
/// capability-gated quick-session launcher instead of a headless run.
@Suite("HUD new chat integration", .serialized)
@MainActor
struct HerdrHudNewChatIntegrationTests {
    @Test("A fresh composer defaults to this Mac and its declared default model")
    func freshComposerDefaultsToLocalMachineAndModel() async throws {
        let fixture = try Fixture(
            machines: [
                HerdrMachine(id: "remote", name: "Build", urlString: "https://build.example.invalid"),
                HerdrMachine(id: "local", name: "Desk", urlString: "https://local.example.invalid"),
            ],
            localHostNames: ["local.example.invalid"]
        )
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer

        #expect(session.selectedMachineID == nil)
        #expect(session.applyLocalMachineDefaultIfNeeded(in: fixture.model))
        #expect(session.selectedMachineID == "local")
        #expect(session.selectedModel == nil)
        #expect(session.isNewChat)

        session.draft = "Hello from this Mac"
        await submit(session, fixture: fixture)

        let start = try #require(fixture.client.headlessStarts.first)
        #expect(start.host == "local.example.invalid")
        #expect(start.model == "synthetic/local-default")
        #expect(start.prompt == "Hello from this Mac")
        #expect(session.exchanges.last?.machineID == "local")
        #expect(session.exchanges.last?.modelLabel == "Local Default")
        #expect(session.exchanges.last?.modelLabelIsProven == true)
    }

    @Test("An explicit draft choice survives refreshes and never becomes the next composer's default")
    func explicitDraftChoiceStaysWithItsDraft() async throws {
        let fixture = try Fixture(localHostNames: ["local.example.invalid"])
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.applyLocalMachineDefaultIfNeeded(in: fixture.model)
        await session.loadModels(model: fixture.model)

        let override = PiAvailableModel(
            provider: "synthetic",
            modelID: "explicit-choice",
            name: "Explicit Choice",
            reasoning: true,
            contextWindow: nil
        )
        session.setSelectedModel(override)
        // A refresh that lands after the choice must not replace it.
        await session.loadModels(model: fixture.model)
        #expect(session.selectedModel == override.id)

        session.draft = "Use my choice"
        await submit(session, fixture: fixture)
        let start = try #require(fixture.client.headlessStarts.first)
        #expect(start.model == "synthetic/explicit-choice")

        let next = fixture.chats.composer
        #expect(next !== session)
        // The collection applies this Mac's fresh-composer defaults as part of
        // the ordinary submission hand-off.
        #expect(next.selectedMachineID == "local")
        #expect(next.selectedModel == nil) // machine default again
        #expect(fixture.defaults.string(forKey: AgentModelSettings.hudModelKey) == nil)
    }

    @Test("Checked Send creates in the exact main workspace and prompts it once, before any answer")
    func checkedSendCreatesInExactWorkspace() async throws {
        let fixture = try Fixture(
            localHostNames: ["local.example.invalid"],
            workspaces: [
                (id: "w-other", label: "Main"),
                (id: "w-main", label: "Main"),
            ]
        )
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.applyLocalMachineDefaultIfNeeded(in: fixture.model)
        await session.loadMainWorkspaces(model: fixture.model)
        let workspace = try #require(session.mainWorkspaces.first { $0.workspaceID == "w-main" })
        #expect(session.selectMainWorkspace(workspace, in: fixture.model))
        #expect(session.mainWorkspace(in: fixture.model)?.workspaceID == "w-main")

        // No effect until Send.
        #expect(fixture.client.quickSessionCreates.isEmpty)
        #expect(fixture.client.topologyRequests > 0)

        session.createsInMainWorkspace = true
        session.draft = "Create the launch chat"
        var sentReceipt: HerdrHudWorkspaceLaunchReceipt?
        await session.submit(model: fixture.model) {
            if case let .sent(receipt) = session.workspaceLaunchState { sentReceipt = receipt }
            fixture.chats.workspaceLaunchCompleted(session)
            fixture.chats.applyFreshComposerDefaults(model: fixture.model)
        }

        #expect(fixture.client.quickSessionCreates.count == 1)
        let create = try #require(fixture.client.quickSessionCreates.first)
        #expect(create.workspaceID == "w-main")
        #expect(create.model == "synthetic/local-default")
        #expect(create.thinkingLevel == PiThinkingLevel.max.rawValue)
        #expect(create.focus == false)
        #expect(create.reuseNamedTab == false)
        #expect(create.tabID == nil)
        #expect(create.cwd == "~")
        // No duplicate headless conversation, and no later promotion click.
        #expect(fixture.client.headlessStarts.isEmpty)
        #expect(fixture.client.promptCalls.count == 1)
        #expect(fixture.client.promptCalls.first?.paneID == "w-main:p1")
        #expect(fixture.client.promptCalls.first?.text == "Create the launch chat")
        #expect(session.draft.isEmpty)
        #expect(session.pendingAttachments.isEmpty)
        let receipt = try #require(sentReceipt)
        #expect(receipt.workspaceID == "w-main")
        #expect(receipt.scopedPaneID == "local|w-main:p1")
        // The launch advances the same composer instead of replacing it, so
        // input added while the launch was in flight stays available.
        #expect(fixture.chats.composer === session)
        #expect(session.isNewChat)
        #expect(!session.createsInMainWorkspace)
        #expect(session.workspaceLaunchState == .idle)
    }

    @Test("Advancing after a checked launch keeps input added during the launch")
    func checkedLaunchAdvancementPreservesResidualInput() async throws {
        let fixture = try Fixture(localHostNames: ["local.example.invalid"])
        defer { fixture.cleanUp() }
        let residualAttachment = fixture.directory.appendingPathComponent("residual.txt")
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try Data("synthetic residual attachment".utf8).write(to: residualAttachment)
        let session = fixture.chats.composer
        session.applyLocalMachineDefaultIfNeeded(in: fixture.model)
        await session.loadMainWorkspaces(model: fixture.model)
        let workspace = try #require(session.mainWorkspaces.first)
        #expect(session.selectMainWorkspace(workspace, in: fixture.model))
        session.createsInMainWorkspace = true
        session.draft = "Launch this once"

        await session.submit(model: fixture.model) {
            // The launch has consumed its snapshot and is about to advance the
            // composer; an edit and attachment added here must survive that
            // advancement.
            session.draft = "Residual idea"
            session.addAttachments([residualAttachment])
            fixture.chats.workspaceLaunchCompleted(session)
            fixture.chats.applyFreshComposerDefaults(model: fixture.model)
        }

        #expect(fixture.chats.composer === session)
        #expect(session.draft == "Residual idea")
        #expect(session.pendingAttachments.count == 1)
        #expect(session.pendingAttachments.first?.filename == "residual.txt")
        #expect(session.isNewChat)
        #expect(!session.createsInMainWorkspace)
        #expect(session.selectedMachineID == "local")
        #expect(fixture.client.promptCalls.first?.text == "Launch this once")
        #expect(!fixture.client.promptCalls.contains { $0.text.contains("Residual idea") })
    }

    @Test("Switching the selected machine reloads its destinations without toggling the checkbox")
    func machineSwitchReloadsDestinations() async throws {
        let fixture = try Fixture(
            machines: [
                HerdrMachine(id: "alpha", name: "Alpha", urlString: "https://alpha.example.invalid"),
                HerdrMachine(id: "beta", name: "Beta", urlString: "https://beta.example.invalid"),
            ],
            localHostNames: ["alpha.example.invalid"],
            workspacesByHost: [
                "alpha.example.invalid": [(id: "w-alpha", label: "Shared label")],
                "beta.example.invalid": [(id: "w-beta", label: "Shared label")],
            ]
        )
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.createsInMainWorkspace = true
        session.applyLocalMachineDefaultIfNeeded(in: fixture.model)
        #expect(session.selectedMachineID == "alpha")
        await session.loadMainWorkspaces(model: fixture.model)
        #expect(session.currentMainWorkspaces(in: fixture.model).map(\.workspaceID) == ["w-alpha"])

        let alphaKey = session.mainWorkspaceTopologyKey(in: fixture.model)
        session.selectedMachineID = "beta"
        // The machine switch drops the previous machine's list immediately...
        #expect(session.currentMainWorkspaces(in: fixture.model).isEmpty)
        #expect(session.mainWorkspaces.isEmpty)
        // ...and the key the picker task watches changed, so the new machine's
        // destinations become selectable without toggling or pressing Send.
        #expect(session.mainWorkspaceTopologyKey(in: fixture.model) != alphaKey)
        await session.loadMainWorkspaces(model: fixture.model)
        #expect(session.currentMainWorkspaces(in: fixture.model).map(\.workspaceID) == ["w-beta"])
    }

    @Test("A delayed topology response for the previous machine cannot repopulate the picker")
    func supersededTopologyCannotRepopulate() async throws {
        let fixture = try Fixture(
            machines: [
                HerdrMachine(id: "alpha", name: "Alpha", urlString: "https://alpha.example.invalid"),
                HerdrMachine(id: "beta", name: "Beta", urlString: "https://beta.example.invalid"),
            ],
            localHostNames: ["alpha.example.invalid"],
            workspacesByHost: [
                "alpha.example.invalid": [(id: "w-alpha", label: "Alpha Main")],
                "beta.example.invalid": [(id: "w-beta", label: "Beta Main")],
            ],
            topologyDelayHost: "alpha.example.invalid"
        )
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.createsInMainWorkspace = true
        session.applyLocalMachineDefaultIfNeeded(in: fixture.model)
        let alphaLoad = Task { await session.loadMainWorkspaces(model: fixture.model) }
        try await wait { fixture.client.topologyRequests > 0 }

        session.selectedMachineID = "beta"
        await session.loadMainWorkspaces(model: fixture.model)
        #expect(session.currentMainWorkspaces(in: fixture.model).map(\.workspaceID) == ["w-beta"])

        fixture.client.releaseDelayedTopology()
        await alphaLoad.value
        // The stale Alpha response must not replace Beta's list or spinner.
        #expect(session.currentMainWorkspaces(in: fixture.model).map(\.workspaceID) == ["w-beta"])
        #expect(!session.isLoadingMainWorkspaces)
    }

    @Test("An interrupted checked launch reconnects its request, draft, and pane after relaunch")
    func interruptedCheckedLaunchReconnectsAfterRelaunch() async throws {
        let fixture = try Fixture(localHostNames: ["local.example.invalid"], promptFailures: 1)
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.applyLocalMachineDefaultIfNeeded(in: fixture.model)
        await session.loadMainWorkspaces(model: fixture.model)
        let workspace = try #require(session.mainWorkspaces.first)
        #expect(session.selectMainWorkspace(workspace, in: fixture.model))
        session.createsInMainWorkspace = true
        session.draft = "Deliver exactly once"

        await submit(session, fixture: fixture)
        guard case .needsRecovery = session.workspaceLaunchState else {
            Issue.record("Expected a recovery state before relaunch")
            return
        }

        let relaunchedPrototype = HerdrHudSession(
            userDefaults: fixture.defaults,
            persistenceURL: fixture.directory.appendingPathComponent("hud-thread.json"),
            hostIdentity: HerdrHudHostIdentity(hostNames: ["local.example.invalid"], addresses: []),
            workspaceLauncherFactory: { model, machineID in
                HerdrHudWorkspaceLauncher(
                    client: try model.hudChatClient(machineID: machineID),
                    storeURL: fixture.directory.appendingPathComponent("launches-\(machineID).json")
                )
            }
        )
        let relaunched = HerdrHudChats(legacySession: relaunchedPrototype, defaults: fixture.defaults)
        let restored = relaunched.composer
        await restored.waitForPersistenceRestore()
        #expect(restored.draft == "Deliver exactly once")
        #expect(restored.createsInMainWorkspace)
        #expect(restored.selectedMachineID == "local")
        #expect(restored.workspaceLaunchPaneIDForOpening() == "local|w-main:p1")
        #expect(restored.workspaceLaunchRecoveryMessage != nil)

        // The same request ID and pane are retained: resending never creates a
        // second pane or sends a second prompt.
        await restored.submit(model: fixture.model) { relaunched.workspaceLaunchCompleted(restored) }
        #expect(fixture.client.quickSessionCreates.count == 1)
        #expect(fixture.client.promptCalls.count == 1)
    }

    @Test("An uncertain create restored after relaunch is never replayed with a new pane")
    func interruptedUncertainCreateReconnectsAfterRelaunch() async throws {
        let fixture = try Fixture(localHostNames: ["local.example.invalid"], createFailures: 1)
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.applyLocalMachineDefaultIfNeeded(in: fixture.model)
        await session.loadMainWorkspaces(model: fixture.model)
        let workspace = try #require(session.mainWorkspaces.first)
        #expect(session.selectMainWorkspace(workspace, in: fixture.model))
        session.createsInMainWorkspace = true
        session.draft = "Maybe created"

        await submit(session, fixture: fixture)
        guard case .needsRecovery = session.workspaceLaunchState else {
            Issue.record("Expected an uncertain-create recovery state before relaunch")
            return
        }
        #expect(session.draft == "Maybe created")

        let relaunchedPrototype = HerdrHudSession(
            userDefaults: fixture.defaults,
            persistenceURL: fixture.directory.appendingPathComponent("hud-thread.json"),
            hostIdentity: HerdrHudHostIdentity(hostNames: ["local.example.invalid"], addresses: []),
            workspaceLauncherFactory: { model, machineID in
                HerdrHudWorkspaceLauncher(
                    client: try model.hudChatClient(machineID: machineID),
                    storeURL: fixture.directory.appendingPathComponent("launches-\(machineID).json")
                )
            }
        )
        let relaunched = HerdrHudChats(legacySession: relaunchedPrototype, defaults: fixture.defaults)
        let restored = relaunched.composer
        await restored.waitForPersistenceRestore()
        #expect(restored.draft == "Maybe created")
        #expect(restored.createsInMainWorkspace)
        #expect(restored.workspaceLaunchRecoveryMessage != nil)
        #expect(restored.workspaceLaunchPaneIDForOpening() == nil)

        // The durable receipt proves a create was attempted, so a resend must
        // refuse instead of minting a second pane.
        await restored.submit(model: fixture.model) { relaunched.workspaceLaunchCompleted(restored) }
        #expect(fixture.client.quickSessionCreates.count == 1)
        #expect(fixture.client.promptCalls.isEmpty)
        guard case .needsRecovery = restored.workspaceLaunchState else {
            Issue.record("Expected the restored recovery state to remain")
            return
        }
    }

    @Test("Stop during a checked create prevents the prompt and preserves the created pane")
    func stopDuringCheckedCreatePreventsPrompt() async throws {
        let fixture = try Fixture(localHostNames: ["local.example.invalid"], delayCreate: true)
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.applyLocalMachineDefaultIfNeeded(in: fixture.model)
        await session.loadMainWorkspaces(model: fixture.model)
        let workspace = try #require(session.mainWorkspaces.first)
        #expect(session.selectMainWorkspace(workspace, in: fixture.model))
        session.createsInMainWorkspace = true
        session.draft = "Stop this launch"

        let task = Task {
            await session.submit(model: fixture.model) {
                if case .sent = session.workspaceLaunchState {
                    fixture.chats.workspaceLaunchCompleted(session)
                } else {
                    fixture.chats.submissionStarted(session)
                }
                fixture.chats.applyFreshComposerDefaults(model: fixture.model)
            }
        }
        try await wait { fixture.client.createRequestsStarted == 1 }
        await session.stop(model: fixture.model)
        fixture.client.releaseDelayedCreate()
        await task.value

        #expect(fixture.client.quickSessionCreates.count == 1)
        #expect(fixture.client.promptCalls.isEmpty)
        #expect(session.draft == "Stop this launch")
        guard case let .needsRecovery(_, receipt) = session.workspaceLaunchState else {
            Issue.record("Expected the late confirmed pane to be retained")
            return
        }
        #expect(receipt?.paneID == "w-main:p1")
        #expect(session.workspaceLaunchPaneIDForOpening() == "local|w-main:p1")
    }

    @Test("Checked Send without a chosen main workspace sends nothing and keeps the draft")
    func checkedSendRequiresDestination() async throws {
        let fixture = try Fixture(localHostNames: ["local.example.invalid"])
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.applyLocalMachineDefaultIfNeeded(in: fixture.model)
        session.createsInMainWorkspace = true
        session.draft = "Keep this draft"

        await submit(session, fixture: fixture)

        #expect(fixture.client.quickSessionCreates.isEmpty)
        #expect(fixture.client.promptCalls.isEmpty)
        #expect(fixture.client.headlessStarts.isEmpty)
        #expect(session.draft == "Keep this draft")
        #expect(session.validationError?.contains("Choose the main workspace") == true)
        #expect(session.workspaceLaunchState == .idle)
    }

    @Test("An offline local companion is retained and never silently dispatches elsewhere")
    func offlineLocalCompanionIsRetained() async throws {
        let fixture = try Fixture(
            machines: [
                HerdrMachine(id: "remote", name: "Build", urlString: "https://build.example.invalid"),
                HerdrMachine(id: "local", name: "Desk", urlString: "https://local.example.invalid"),
            ],
            localHostNames: ["local.example.invalid"]
        )
        defer { fixture.cleanUp() }
        fixture.model.machineStates["local"] = .disconnected
        let session = fixture.chats.composer
        session.applyLocalMachineDefaultIfNeeded(in: fixture.model)
        #expect(session.selectedMachineID == "local")
        session.createsInMainWorkspace = true
        session.draft = "Stay local"

        await submit(session, fixture: fixture)

        #expect(session.selectedMachineID == "local")
        #expect(session.validationError?.contains("not connected") == true)
        #expect(fixture.client.quickSessionCreates.isEmpty)
        #expect(fixture.client.promptCalls.isEmpty)
        #expect(fixture.client.headlessStarts.isEmpty)
        #expect(session.draft == "Stay local")
    }

    @Test("A continuation never creates a workspace chat even if the flag was left set")
    func continuationNeverCreatesWorkspaceChat() async throws {
        let fixture = try Fixture(localHostNames: ["local.example.invalid"])
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.applyLocalMachineDefaultIfNeeded(in: fixture.model)
        session.draft = "First turn"
        await submit(session, fixture: fixture)
        try await wait { fixture.client.headlessStarts.count == 1 }
        let root = try #require(session.thread?.rootRunID)

        #expect(!session.isNewChat)
        session.createsInMainWorkspace = true
        session.draft = "Second turn"
        await submit(session, fixture: fixture)
        try await wait { fixture.client.headlessStarts.count == 2 }

        #expect(fixture.client.quickSessionCreates.isEmpty)
        let second = try #require(fixture.client.headlessStarts.last)
        #expect(second.continueFromRunId == root)
        #expect(session.thread?.turnCount == 2)
    }

    @Test("An uncertain prompt exposes Open chat and is never sent again")
    func uncertainPromptExposesRecovery() async throws {
        let fixture = try Fixture(localHostNames: ["local.example.invalid"], promptFailures: 1)
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.applyLocalMachineDefaultIfNeeded(in: fixture.model)
        await session.loadMainWorkspaces(model: fixture.model)
        let workspace = try #require(session.mainWorkspaces.first)
        #expect(session.selectMainWorkspace(workspace, in: fixture.model))
        session.createsInMainWorkspace = true
        session.draft = "Deliver exactly once"

        await submit(session, fixture: fixture)

        guard case let .needsRecovery(message, receipt) = session.workspaceLaunchState else {
            Issue.record("Expected a recovery state")
            return
        }
        #expect(message.contains("couldn't confirm"))
        #expect(receipt?.paneID == "w-main:p1")
        #expect(session.workspaceLaunchPaneIDForOpening() == "local|w-main:p1")
        // The uncertain prompt was not acknowledged, so the draft is retained.
        #expect(session.draft == "Deliver exactly once")
        #expect(fixture.client.quickSessionCreates.count == 1)
        #expect(fixture.client.promptCalls.count == 1)

        // A retry cannot duplicate the confirmed pane, even after the banner
        // is dismissed and the same draft is submitted again.
        session.dismissWorkspaceLaunchRecovery()
        await submit(session, fixture: fixture)
        #expect(fixture.client.quickSessionCreates.count == 1)
        #expect(fixture.client.promptCalls.count == 1)
        guard case .needsRecovery = session.workspaceLaunchState else {
            Issue.record("Expected the launcher to refuse the uncertain resend")
            return
        }
    }

    @Test("An attachment upload failure retries with the same request ID and sends one prompt")
    func uploadFailureRetriesIdempotently() async throws {
        let fixture = try Fixture(localHostNames: ["local.example.invalid"], uploadFailures: 1)
        defer { fixture.cleanUp() }
        let attachmentURL = fixture.directory.appendingPathComponent("notes.txt")
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: attachmentURL)
        let session = fixture.chats.composer
        session.applyLocalMachineDefaultIfNeeded(in: fixture.model)
        await session.loadMainWorkspaces(model: fixture.model)
        let workspace = try #require(session.mainWorkspaces.first)
        #expect(session.selectMainWorkspace(workspace, in: fixture.model))
        session.createsInMainWorkspace = true
        session.addAttachments([attachmentURL])
        session.draft = "With an attachment"

        await submit(session, fixture: fixture)

        #expect(fixture.client.quickSessionCreates.isEmpty)
        #expect(session.validationError?.contains("notes.txt") == true)
        #expect(session.draft == "With an attachment")
        #expect(session.pendingAttachments.count == 1)

        await submit(session, fixture: fixture)

        #expect(fixture.client.quickSessionCreates.count == 1)
        #expect(fixture.client.promptCalls.count == 1)
        let requestIDs = fixture.client.quickSessionCreates.map(\.requestID)
        #expect(Set(requestIDs).count == 1)
        #expect(fixture.client.promptCalls.first?.text.contains("Attachment: `/uploads/notes.txt`") == true)
    }

    @Test("A delayed catalog response cannot replace a newer machine's catalog")
    func delayedCatalogCannotReplaceNewerSelection() async throws {
        let fixture = try Fixture(
            machines: [
                HerdrMachine(id: "alpha", name: "Alpha", urlString: "https://alpha.example.invalid"),
                HerdrMachine(id: "beta", name: "Beta", urlString: "https://beta.example.invalid"),
            ],
            catalogDelayHost: "alpha.example.invalid"
        )
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.selectedMachineID = "alpha"
        let alphaLoad = Task { await session.loadModels(model: fixture.model) }
        try await wait { fixture.client.catalogHosts.contains("alpha.example.invalid") }

        session.selectedMachineID = "beta"
        await session.loadModels(model: fixture.model)
        #expect(session.modelsMachineID == "beta")
        #expect(session.defaultModel?.id == "beta-default")

        fixture.client.releaseDelayedCatalog()
        await alphaLoad.value
        // The stale Alpha response must not become Beta's catalog.
        #expect(session.modelsMachineID == "beta")
        #expect(session.defaultModel?.id == "beta-default")
        #expect(session.defaultModel?.id != "alpha-default")
    }

    private func submit(_ session: HerdrHudSession, fixture: Fixture) async {
        await session.submit(model: fixture.model) {
            if case .sent = session.workspaceLaunchState {
                fixture.chats.workspaceLaunchCompleted(session)
            } else {
                fixture.chats.submissionStarted(session)
            }
            fixture.chats.applyFreshComposerDefaults(model: fixture.model)
        }
    }

    private func wait(
        timeout: Duration = .seconds(2),
        _ condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                throw WaitError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private enum WaitError: Error { case timedOut }

    @MainActor
    private struct Fixture {
        let suite = "hud-new-chat-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults: UserDefaults
        let model: HerdrAppModel
        let prototype: HerdrHudSession
        let chats: HerdrHudChats
        let client: HudNewChatClient

        init(
            machines: [HerdrMachine] = [
                HerdrMachine(id: "local", name: "Desk", urlString: "https://local.example.invalid")
            ],
            localHostNames: [String] = ["local.example.invalid"],
            workspaces: [(id: String, label: String)] = [("w-main", "Main")],
            workspacesByHost: [String: [(id: String, label: String)]] = [:],
            promptFailures: Int = 0,
            uploadFailures: Int = 0,
            createFailures: Int = 0,
            catalogDelayHost: String? = nil,
            topologyDelayHost: String? = nil,
            delayCreate: Bool = false
        ) throws {
            let client = HudNewChatClient(
                workspaces: workspaces,
                workspacesByHost: workspacesByHost,
                promptFailures: promptFailures,
                uploadFailures: uploadFailures,
                createFailures: createFailures,
                catalogDelayHost: catalogDelayHost,
                topologyDelayHost: topologyDelayHost,
                delayCreate: delayCreate
            )
            self.client = client
            HudNewChatURLProtocol.state.withLock { $0 = client.initialState }
            defaults = try #require(UserDefaults(suiteName: suite))
            let launchDirectory = directory
            prototype = HerdrHudSession(
                userDefaults: defaults,
                persistenceURL: directory.appendingPathComponent("hud-thread.json"),
                hostIdentity: HerdrHudHostIdentity(hostNames: localHostNames, addresses: []),
                workspaceLauncherFactory: { model, machineID in
                    HerdrHudWorkspaceLauncher(
                        client: try model.hudChatClient(machineID: machineID),
                        storeURL: launchDirectory.appendingPathComponent("launches-\(machineID).json")
                    )
                }
            )
            chats = HerdrHudChats(legacySession: prototype, defaults: defaults)
            let urlSessionConfiguration = URLSessionConfiguration.ephemeral
            urlSessionConfiguration.protocolClasses = [HudNewChatURLProtocol.self]
            let urlSession = URLSession(configuration: urlSessionConfiguration)
            model = HerdrAppModel(credentials: TestCredentialStore(), arguments: [], userDefaults: defaults)
            model.machines = machines
            model.clientFactory = { configuration in
                HerdrAPIClient(configuration: configuration, session: urlSession)
            }
            for machine in machines {
                model.prepareRuntime(for: machine, generation: model.connectionGeneration)
                model.machineStates[machine.id] = .live
            }
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

/// One synthetic companion's recorded requests. `initialState` seeds the
/// URLProtocol's mutex; every observation and mutation goes through that
/// mutex so background URL loading and the main-actor test stay in sync.
private final class HudNewChatClient: Sendable {
    struct QuickSessionCreate: Equatable, Sendable {
        let requestID: String
        let workspaceID: String?
        let tabID: String?
        let cwd: String?
        let model: String?
        let thinkingLevel: String?
        let focus: Bool?
        let reuseNamedTab: Bool?
    }

    struct PromptCall: Equatable, Sendable {
        let paneID: String
        let text: String
    }

    struct HeadlessStart: Equatable, Sendable {
        let id: String
        let root: String
        let host: String
        let prompt: String
        let model: String?
        let continueFromRunId: String?
    }

    struct State: Sendable {
        var workspaces: [(id: String, label: String)]
        var workspacesByHost: [String: [(id: String, label: String)]] = [:]
        var catalogHosts: [String] = []
        var quickSessionCreates: [QuickSessionCreate] = []
        var promptCalls: [PromptCall] = []
        var headlessStarts: [HeadlessStart] = []
        var attachmentUploads: [String] = []
        var capabilityRequests = 0
        var topologyRequests = 0
        var promptFailuresRemaining: Int
        var createFailuresRemaining: Int
        var uploadFailuresRemaining: Int
        var catalogDelayHost: String?
        var topologyDelayHost: String?
        var delayCreate: Bool
        var createRequestsStarted = 0
        let catalogGate = DispatchSemaphore(value: 0)
        let topologyGate = DispatchSemaphore(value: 0)
        let createGate = DispatchSemaphore(value: 0)
        var delayedCatalogReleased = false
        var delayedTopologyReleased = false
        var delayedCreateReleased = false
    }

    let initialState: State

    var quickSessionCreates: [QuickSessionCreate] { HudNewChatURLProtocol.state.withLock { $0.quickSessionCreates } }
    var promptCalls: [PromptCall] { HudNewChatURLProtocol.state.withLock { $0.promptCalls } }
    var headlessStarts: [HeadlessStart] { HudNewChatURLProtocol.state.withLock { $0.headlessStarts } }
    var catalogHosts: [String] { HudNewChatURLProtocol.state.withLock { $0.catalogHosts } }
    var topologyRequests: Int { HudNewChatURLProtocol.state.withLock { $0.topologyRequests } }
    var createRequestsStarted: Int { HudNewChatURLProtocol.state.withLock { $0.createRequestsStarted } }

    init(
        workspaces: [(id: String, label: String)],
        workspacesByHost: [String: [(id: String, label: String)]] = [:],
        promptFailures: Int,
        uploadFailures: Int,
        createFailures: Int,
        catalogDelayHost: String?,
        topologyDelayHost: String? = nil,
        delayCreate: Bool = false
    ) {
        initialState = State(
            workspaces: workspaces,
            workspacesByHost: workspacesByHost,
            promptFailuresRemaining: promptFailures,
            createFailuresRemaining: createFailures,
            uploadFailuresRemaining: uploadFailures,
            catalogDelayHost: catalogDelayHost,
            topologyDelayHost: topologyDelayHost,
            delayCreate: delayCreate
        )
    }

    func releaseDelayedCatalog() {
        let gate = HudNewChatURLProtocol.state.withLock { state -> DispatchSemaphore in
            state.delayedCatalogReleased = true
            return state.catalogGate
        }
        gate.signal()
    }

    func releaseDelayedTopology() {
        let gate = HudNewChatURLProtocol.state.withLock { state -> DispatchSemaphore in
            state.delayedTopologyReleased = true
            return state.topologyGate
        }
        gate.signal()
    }

    func releaseDelayedCreate() {
        let gate = HudNewChatURLProtocol.state.withLock { state -> DispatchSemaphore in
            state.delayedCreateReleased = true
            return state.createGate
        }
        gate.signal()
    }
}

private final class HudNewChatURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = Mutex(HudNewChatClient.State(
        workspaces: [],
        promptFailuresRemaining: 0,
        createFailuresRemaining: 0,
        uploadFailuresRemaining: 0,
        catalogDelayHost: nil,
        topologyDelayHost: nil,
        delayCreate: false
    ))

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        let body = requestBody()
        let gate: DispatchSemaphore? = Self.state.withLock { state -> DispatchSemaphore? in
            let path = url.path
            if path == "/api/v1/agent-runs/models" {
                state.catalogHosts.append(url.host ?? "")
                guard url.host == state.catalogDelayHost,
                      !state.delayedCatalogReleased else { return nil }
                return state.catalogGate
            }
            if path == "/api/v1/workspaces" {
                state.topologyRequests += 1
                guard url.host == state.topologyDelayHost,
                      !state.delayedTopologyReleased else { return nil }
                return state.topologyGate
            }
            if path == "/api/v1/quick-sessions/pi", request.httpMethod == "POST" {
                state.createRequestsStarted += 1
                guard state.delayCreate,
                      !state.delayedCreateReleased else { return nil }
                return state.createGate
            }
            return nil
        }
        if let gate {
            DispatchQueue.global().async { [self] in
                gate.wait()
                completeLoading(url: url, body: body)
            }
            return
        }
        completeLoading(url: url, body: body)
    }

    private func completeLoading(url: URL, body: Data) {
        let payload = Self.state.withLock { state -> (Int, Data) in
            let path = url.path
            if path == "/api/v1" {
                state.capabilityRequests += 1
                return (200, Data(#"{"ok":true,"capabilities":["quick-session-launch-options-v1"]}"#.utf8))
            }
            if path == "/api/v1/workspaces" {
                let hostWorkspaces = state.workspacesByHost[url.host ?? ""] ?? state.workspaces
                let workspaces = hostWorkspaces.map { workspace -> [String: Any] in
                    [
                        "workspace_id": workspace.id,
                        "number": 1,
                        "label": workspace.label,
                        "focused": false,
                        "pane_count": 1,
                        "tab_count": 1,
                        "active_tab_id": "\(workspace.id):t1",
                        "agent_status": "idle",
                    ]
                }
                let response: [String: Any] = ["ok": true, "workspaces": workspaces]
                return (200, (try? JSONSerialization.data(withJSONObject: response)) ?? Data())
            }
            if path == "/api/v1/agent-runs/models" {
                return (200, Data(Self.catalog(host: url.host ?? "").utf8))
            }
            if path == "/api/v1/agent-runs/capabilities" {
                return (200, Data(#"{"ok":true,"profiles":["hud-chat-v1"],"hudChatWorkingDirectory":true}"#.utf8))
            }
            if path.hasSuffix("/attachments"), request.httpMethod == "POST" {
                let input = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
                let filename = input["filename"] as? String ?? "attachment"
                state.attachmentUploads.append(filename)
                if state.uploadFailuresRemaining > 0 {
                    state.uploadFailuresRemaining -= 1
                    return (503, Data(#"{"ok":false,"error":"Synthetic upload failure"}"#.utf8))
                }
                let response: [String: Any] = [
                    "ok": true,
                    "attachment": [
                        "id": "attachment-\(state.attachmentUploads.count)",
                        "filename": filename,
                        "original_filename": filename,
                        "content_type": input["content_type"] as? String ?? "text/plain",
                        "size": 1,
                        "path": "/uploads/\(filename)",
                        "created_at": "2026-09-01T12:00:00Z",
                    ],
                ]
                return (200, (try? JSONSerialization.data(withJSONObject: response)) ?? Data())
            }
            if path == "/api/v1/quick-sessions/pi", request.httpMethod == "POST" {
                let input = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
                let workspaceID = input["workspaceId"] as? String
                let requestID = input["requestId"] as? String ?? ""
                let model = input["model"] as? [String: Any]
                let recorded = HudNewChatClient.QuickSessionCreate(
                    requestID: requestID,
                    workspaceID: workspaceID,
                    tabID: input["tabId"] as? String,
                    cwd: input["cwd"] as? String,
                    model: (model?["provider"] as? String).flatMap { provider in
                        (model?["id"] as? String).map { "\(provider)/\($0)" }
                    },
                    thinkingLevel: input["thinkingLevel"] as? String,
                    focus: input["focus"] as? Bool,
                    reuseNamedTab: input["reuseNamedTab"] as? Bool
                )
                state.quickSessionCreates.append(recorded)
                if state.createFailuresRemaining > 0 {
                    state.createFailuresRemaining -= 1
                    return (503, Data(#"{"ok":false,"error":"Synthetic create failure"}"#.utf8))
                }
                let response: [String: Any] = [
                    "ok": true,
                    "workspace_id": workspaceID ?? "w-created",
                    "tab_id": "\(workspaceID ?? "w-created"):t1",
                    "pane_id": "\(workspaceID ?? "w-created"):p1",
                    "created_workspace": false,
                    "created_tab": true,
                    "created_pane": true,
                    "pi_extension_attached": true,
                    "request_id": requestID,
                    "session_id": NSNull(),
                ]
                return (200, (try? JSONSerialization.data(withJSONObject: response)) ?? Data())
            }
            if path.hasSuffix("/pi/prompt"), request.httpMethod == "POST" {
                let input = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
                let components = path.split(separator: "/").map(String.init)
                let paneIndex = components.firstIndex(of: "panes").map { $0 + 1 }
                let paneID = paneIndex.flatMap { components.indices.contains($0) ? components[$0] : nil } ?? ""
                state.promptCalls.append(
                    HudNewChatClient.PromptCall(paneID: paneID, text: input["text"] as? String ?? "")
                )
                if state.promptFailuresRemaining > 0 {
                    state.promptFailuresRemaining -= 1
                    return (503, Data(#"{"ok":false,"error":"Synthetic prompt failure"}"#.utf8))
                }
                return (200, Data(#"{"ok":true}"#.utf8))
            }
            if path == "/api/v1/agent-runs", request.httpMethod == "POST" {
                let input = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
                let id = "agr_synthetic_\(state.headlessStarts.count + 1)"
                let parent = input["continueFromRunId"] as? String
                let root = state.headlessStarts.first { $0.id == parent }?.root ?? parent ?? id
                state.headlessStarts.append(
                    HudNewChatClient.HeadlessStart(
                        id: id,
                        root: root,
                        host: url.host ?? "",
                        prompt: input["prompt"] as? String ?? "",
                        model: input["model"] as? String,
                        continueFromRunId: parent
                    )
                )
                let run: [String: Any] = [
                    "id": id,
                    "status": "completed",
                    "prompt": input["prompt"] as? String ?? "",
                    "createdAt": "2026-09-01T12:00:00Z",
                    "threadRootRunId": root,
                    "sessionFile": "synthetic.jsonl",
                    "response": "Synthetic answer",
                    "costUSD": 0.01,
                ]
                return (200, (try? JSONSerialization.data(withJSONObject: ["ok": true, "run": run])) ?? Data())
            }
            if path.hasPrefix("/api/v1/hud-chats/"), request.httpMethod == "GET" {
                let root = url.lastPathComponent
                let turns = state.headlessStarts.filter { $0.root == root || $0.id == root }
                let runs: [[String: Any]] = turns.map { start in
                    var run: [String: Any] = [
                        "id": start.id,
                        "status": "completed",
                        "prompt": start.prompt,
                        "createdAt": "2026-09-01T12:00:00Z",
                        "threadRootRunId": start.root,
                        "sessionFile": "synthetic.jsonl",
                        "response": "Synthetic answer",
                        "costUSD": 0.01,
                    ]
                    if let model = start.model { run["model"] = model }
                    return run
                }
                let response: [String: Any] = [
                    "ok": true,
                    "turns": runs,
                    "rootRunId": root,
                    "latestRunId": turns.last?.id ?? root,
                ]
                return (200, (try? JSONSerialization.data(withJSONObject: response)) ?? Data())
            }
            if path.contains("/agent-runs/"), request.httpMethod == "GET" {
                let run: [String: Any] = [
                    "id": url.lastPathComponent,
                    "status": "completed",
                    "prompt": "",
                    "createdAt": "2026-09-01T12:00:00Z",
                    "threadRootRunId": url.lastPathComponent,
                    "sessionFile": "synthetic.jsonl",
                    "response": "Synthetic answer",
                    "costUSD": 0.01,
                ]
                return (200, (try? JSONSerialization.data(withJSONObject: ["ok": true, "run": run])) ?? Data())
            }
            return (200, Data(#"{"ok":true}"#.utf8))
        }
        guard let response = HTTPURLResponse(url: url, statusCode: payload.0, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload.1)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func catalog(host: String) -> String {
        let id: String
        let name: String
        if host.hasPrefix("alpha") {
            id = "alpha-default"
            name = "Alpha Default"
        } else if host.hasPrefix("beta") {
            id = "beta-default"
            name = "Beta Default"
        } else {
            id = "local-default"
            name = "Local Default"
        }
        return """
        {"ok":true,"models":[{"provider":"synthetic","id":"\(id)","name":"\(name)","reasoning":true,"supports_images":true},{"provider":"synthetic","id":"explicit-choice","name":"Explicit Choice","reasoning":true,"supports_images":true}],"default":{"provider":"synthetic","id":"\(id)","name":"\(name)"}}
        """
    }

    private func requestBody() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        return body
    }
}
