import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Herdr HUD session")
@MainActor
struct HerdrHudSessionTests {
    private let credentials = TestCredentialStore()
    @Test("Submitting appends a completed exchange and clears running state")
    func submitAppendsCompletedExchangeAndClearsRunningState() async throws {
        let model = makeDemoModel()
        let session = makeSession()
        session.draft = "What needs attention?"

        await session.submit(model: model)

        #expect(session.exchanges.count == 1)
        let exchange = try #require(session.exchanges.first)
        #expect(exchange.status == .completed)
        #expect(exchange.response?.isEmpty == false)
        #expect(model.machines.map(\.id).contains(exchange.machineID))
        #expect(!session.isRunning)
        #expect(session.draft.isEmpty)
        #expect(session.validationError == nil)
    }

    @Test("Quote-only submissions send inline segments without file attachments")
    func quoteOnlySubmission() async throws {
        let model = makeDemoModel()
        let session = makeSession()
        let quotes = [ChatQuote(text: "First selected detail", comment: "Keep this.", source: "synthetic"),
                      ChatQuote(text: "Second selected detail", comment: "Revise this.", source: "synthetic")]
        quotes.forEach(session.addQuote)
        await session.submit(model: model)
        let run = try #require(session.lastHeadlessRunForTesting)
        #expect(run.prompt == ChatQuote.prompt("", quotes: quotes))
        #expect(!run.prompt.contains("Attachment:"))
        let exchange = try #require(session.exchanges.last)
        #expect(exchange.sentPrompt == run.prompt)
        #expect(exchange.localAttachments.isEmpty)
        #expect(exchange.attachmentFilenames.isEmpty)
        #expect(session.pendingQuotes.isEmpty)
        #expect(session.pendingAttachments.isEmpty)
    }

    @Test("First HUD submit starts a new thread")
    func firstSubmitStartsNewThread() async throws {
        let model = makeDemoModel()
        let session = makeSession()
        session.draft = "First turn"

        await session.submit(model: model)

        let run = try #require(session.lastHeadlessRunForTesting)
        let thread = try #require(session.thread)
        #expect(run.threadRootRunId == run.id)
        #expect(thread.rootRunID == run.threadRootRunId)
        #expect(thread.lastRunID == run.id)
        #expect(thread.turnCount == 1)
    }

    @Test("Demo HUD sends a second turn without saved-history preflight")
    func demoSecondTurnContinuesThread() async throws {
        let model = makeDemoModel()
        let session = makeSession()
        session.draft = "First turn"
        await session.submit(model: model)
        let firstRun = try #require(session.lastHeadlessRunForTesting)

        session.draft = "Second turn"
        await session.submit(model: model)

        let secondRun = try #require(session.lastHeadlessRunForTesting)
        let thread = try #require(session.thread)
        #expect(secondRun.id != firstRun.id)
        #expect(secondRun.threadRootRunId == firstRun.id)
        #expect(session.exchanges.map(\.prompt) == ["First turn", "Second turn"])
        #expect(session.validationError == nil)
        #expect(thread.rootRunID == firstRun.id)
        #expect(thread.lastRunID == secondRun.id)
        #expect(thread.turnCount == 2)
    }

    @Test("Demo continuations keep the thread's original root after the second turn")
    func demoLaterTurnsKeepThreadRoot() async throws {
        let model = makeDemoModel()
        let session = makeSession()
        session.draft = "First turn"
        await session.submit(model: model)
        let firstRun = try #require(session.lastHeadlessRunForTesting)

        for prompt in ["Second turn", "Third turn"] {
            session.draft = prompt
            await session.submit(model: model)
        }

        let thirdRun = try #require(session.lastHeadlessRunForTesting)
        let thread = try #require(session.thread)
        #expect(thirdRun.threadRootRunId == firstRun.id)
        #expect(thread.rootRunID == firstRun.id)
        #expect(thread.lastRunID == thirdRun.id)
        #expect(thread.turnCount == 3)
        #expect(session.exchanges.map(\.prompt) == ["First turn", "Second turn", "Third turn"])
    }

    @Test("A reaped continuation response resets the HUD thread")
    func reapedContinuationResponseResetsThread() async throws {
        let model = makeDemoModel()
        let session = makeSession()
        session.draft = "First turn"
        await session.submit(model: model)
        let firstThread = try #require(session.thread)
        #expect(firstThread.turnCount == 1)

        model.demoForcesFreshThreadForTesting = true
        session.draft = "Second turn, but the session was reaped"
        await session.submit(model: model)

        let run = try #require(session.lastHeadlessRunForTesting)
        let thread = try #require(session.thread)
        #expect(run.threadRootRunId == run.id)
        #expect(thread.rootRunID == run.id)
        #expect(thread.lastRunID == run.id)
        #expect(thread.turnCount == 1)
    }

    @Test("Failed runs leave the live HUD thread unchanged")
    func failedRunLeavesThreadUnchanged() async throws {
        let demoModel = makeDemoModel()
        let session = makeSession()
        session.draft = "First turn"
        await session.submit(model: demoModel)
        let firstRun = try #require(session.lastHeadlessRunForTesting)
        let originalThread = try #require(session.thread)

        let defaults = makeDefaults(prefix: "thread-failure")
        let failingModel = HerdrAppModel(credentials: credentials, arguments: ["HerdrTests"], userDefaults: defaults)
        #expect(failingModel.addMachine(name: "Unavailable", urlString: "http://localhost:65534", token: "test"))
        let unavailableMachine = try #require(failingModel.machines.first)
        failingModel.machineStates[unavailableMachine.id] = .live
        session.selectedMachineID = unavailableMachine.id
        session.draft = "This will fail"
        await session.submit(model: failingModel)

        #expect(session.thread == originalThread)

        session.selectedMachineID = "demo1"
        session.draft = "Follow up after failure"
        await session.submit(model: demoModel)

        #expect(session.lastHeadlessRunForTesting?.threadRootRunId == firstRun.id)
    }

    @Test("Changing machines starts a new HUD thread")
    func changingMachinesStartsNewThread() async throws {
        let model = makeDemoModel()
        let session = makeSession()
        session.draft = "First machine"
        await session.submit(model: model)

        let secondMachine = try #require(model.machines.first(where: { $0.id == "demo2" }))
        session.selectedMachineID = secondMachine.id
        session.draft = "Second machine"
        await session.submit(model: model)

        let run = try #require(session.lastHeadlessRunForTesting)
        let thread = try #require(session.thread)
        #expect(run.threadRootRunId == run.id)
        #expect(thread.machineID == secondMachine.id)
        #expect(thread.turnCount == 1)
    }

    @Test("Promoting a HUD exchange ends the live thread")
    func promotingExchangeEndsThread() async throws {
        let model = makeDemoModel()
        let session = makeSession()
        session.draft = "Promote this"
        await session.submit(model: model)
        let exchange = try #require(session.exchanges.last)

        let pane = await session.promote(exchange: exchange, model: model)

        #expect(pane != nil)
        #expect(session.thread == nil)
    }

    @Test("Clearing the HUD ends the live thread")
    func clearingHudEndsThread() async throws {
        let model = makeDemoModel()
        let session = makeSession()
        session.draft = "Clear this"
        await session.submit(model: model)

        await session.clear(model: model)

        #expect(session.exchanges.isEmpty)
        #expect(session.thread == nil)
    }

    @Test("Failed submission marks the pending exchange failed and restores the draft")
    func failedSubmissionMarksPendingExchangeFailedAndRestoresDraft() async throws {
        let defaults = makeDefaults(prefix: "failed-submission")
        let model = HerdrAppModel(credentials: credentials, arguments: ["HerdrTests"], userDefaults: defaults)
        #expect(model.addMachine(name: "Unavailable", urlString: "http://localhost:65534", token: "test"))
        let machine = try #require(model.machines.first)
        model.machineStates[machine.id] = .live

        let session = makeSession()
        session.selectedMachineID = machine.id
        session.seedModelsForTesting(
            [PiAvailableModel(provider: "provider", modelID: "default", name: "Default", reasoning: true, contextWindow: nil)],
            default: PiModelIdentity(provider: "provider", id: "default", name: "Default"),
            machineID: machine.id
        )
        session.draft = "Keep this prompt"

        await session.submit(model: model)

        #expect(session.exchanges.count == 1)
        let exchange = try #require(session.exchanges.first)
        #expect(exchange.status == .failed)
        #expect(exchange.error != nil)
        #expect(session.draft == "Keep this prompt")
    }

    @Test("Submitting image attachments records names and uses vision routing")
    func submitImageAttachmentsRecordsNamesAndUsesVisionRouting() async throws {
        let url = temporaryURL(named: "hud-image.png")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)

        let model = makeDemoModel()
        let session = makeSession()
        session.addAttachments([url])
        session.draft = "Describe this image"

        await session.submit(model: model)

        #expect(session.exchanges.last?.attachmentFilenames == [url.lastPathComponent])
        let demoRun = try await model.startHeadlessAgent(
            prompt: "Describe this image",
            machineID: "demo1",
            mode: .act,
            model: HerdrHudModelRouting.visionModel,
            thinkingLevel: HerdrHudModelRouting.thinkingLevel,
            attachments: [HeadlessAgentAttachment(filename: "hud-image.png", dataBase64: "Zm9v")]
        )
        #expect(demoRun.model == HerdrHudModelRouting.visionModel)
        #expect(demoRun.thinkingLevel == HerdrHudModelRouting.thinkingLevel)
        #expect(demoRun.attachments == ["hud-image.png"])
    }

    @Test("A fresh text-only submission pins the machine's declared default with maximum thinking")
    func textOnlyFreshSubmissionPinsDefaultAndMaximumThinking() async throws {
        let model = makeDemoModel()
        let session = makeSession()
        session.draft = "What needs attention?"

        await session.submit(model: model)

        let demoRun = try await model.startHeadlessAgent(
            prompt: "What needs attention?",
            machineID: "demo1",
            mode: .act,
            model: nil,
            thinkingLevel: HerdrHudModelRouting.thinkingLevel
        )
        #expect(demoRun.model == nil)
        #expect(demoRun.thinkingLevel == HerdrHudModelRouting.thinkingLevel)
        // The HUD itself no longer omits the model for a new chat: it pins the
        // execution companion's declared default before dispatch.
        #expect(session.lastHeadlessRunForTesting?.model == "openai-codex/gpt-5.6-luna")
        #expect(session.lastHeadlessRunForTesting?.thinkingLevel == HerdrHudModelRouting.thinkingLevel)
    }

    @Test("Model routing only selects vision for image attachments")
    func modelRoutingOnlySelectsVisionForAttachments() {
        #expect(
            HerdrHudModelRouting.model(
                selection: nil,
                selectionSupportsImages: false,
                hasImageAttachments: false
            ) == nil
        )
        #expect(
            HerdrHudModelRouting.model(
                selection: nil,
                selectionSupportsImages: false,
                hasImageAttachments: true
            ) == HerdrHudModelRouting.visionModel
        )
        #expect(
            HerdrHudModelRouting.model(
                selection: "provider/text-only",
                selectionSupportsImages: false,
                hasImageAttachments: false
            ) == "provider/text-only"
        )
        #expect(
            HerdrHudModelRouting.model(
                selection: "provider/vision",
                selectionSupportsImages: true,
                hasImageAttachments: true
            ) == "provider/vision"
        )
        #expect(
            HerdrHudModelRouting.model(
                selection: "provider/text-only",
                selectionSupportsImages: false,
                hasImageAttachments: true
            ) == HerdrHudModelRouting.visionModel
        )
    }

    @Test("Image submissions keep a selected vision-capable model")
    func imageSubmissionKeepsSelectedVisionCapableModel() async throws {
        let url = temporaryURL(named: "selected-model-image.png")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)

        let model = makeDemoModel()
        let session = makeSession()
        let selected = PiAvailableModel(
            provider: "provider",
            modelID: "vision",
            name: "Vision Choice",
            reasoning: true,
            contextWindow: nil,
            supportsImages: true
        )
        session.seedModelsForTesting([selected], default: nil, machineID: "demo1")
        session.setSelectedModel(selected)
        session.addAttachments([url])
        session.draft = "Describe this image"

        await session.submit(model: model)

        #expect(session.exchanges.last?.modelLabel == "Vision Choice")
        #expect(session.lastHeadlessRunForTesting?.model == selected.id)
    }

    @Test("A fresh image submission never reroutes a text-only selection to the global vision model")
    func imageSubmissionRejectsTextOnlySelection() async throws {
        let url = temporaryURL(named: "fallback-model-image.png")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)

        let model = makeDemoModel()
        let session = makeSession()
        let selected = PiAvailableModel(
            provider: "provider",
            modelID: "text-only",
            name: "Text Choice",
            reasoning: true,
            contextWindow: nil
        )
        session.seedModelsForTesting([selected], default: nil, machineID: "demo1")
        session.setSelectedModel(selected)
        session.addAttachments([url])
        session.draft = "Describe this image"

        await session.submit(model: model)

        #expect(session.exchanges.isEmpty)
        #expect(session.lastHeadlessRunForTesting == nil)
        #expect(session.validationError?.contains("can't read images") == true)
        #expect(session.draft == "Describe this image")
        #expect(session.pendingAttachments.count == 1)
        #expect(session.selectedModel == selected.id)
    }

    @Test("A fresh submission pins the catalog default and labels it as proven")
    func exchangeModelLabelsReflectThePinnedChoice() async {
        let model = makeDemoModel()
        let session = makeSession()
        let defaultModel = PiModelIdentity(provider: "provider", id: "default", name: "Harness Default")
        let selected = PiAvailableModel(
            provider: "provider",
            modelID: "selected",
            name: "Selected Choice",
            reasoning: true,
            contextWindow: nil
        )
        session.seedModelsForTesting(
            [
                PiAvailableModel(provider: "provider", modelID: "default", name: "Harness Default", reasoning: true, contextWindow: nil),
                selected,
            ],
            default: defaultModel,
            machineID: "demo1"
        )
        session.draft = "Use the default"
        await session.submit(model: model)
        // The declared default is pinned in the request, so the label is an
        // explicit identity rather than a local guess.
        #expect(session.exchanges.last?.modelLabel == "Harness Default")
        #expect(session.exchanges.last?.modelLabelIsProven == true)
        #expect(session.lastHeadlessRunForTesting?.model == defaultModel.fullID)

        session.setSelectedModel(selected)
        session.draft = "Use the selection"
        await session.submit(model: model)
        #expect(session.exchanges.last?.modelLabel == "Selected Choice")
        #expect(session.exchanges.last?.modelLabelIsProven == true)
        #expect(session.lastHeadlessRunForTesting?.model == selected.id)
    }

    @Test("Attachments enforce count and file-size limits")
    func attachmentsEnforceCountAndFileSizeLimits() throws {
        let regularURL = temporaryURL(named: "attachment.png")
        let oversizedURL = temporaryURL(named: "oversized.png")
        defer {
            try? FileManager.default.removeItem(at: regularURL)
            try? FileManager.default.removeItem(at: oversizedURL)
        }
        try Data([1]).write(to: regularURL)
        try Data(repeating: 0, count: 21 * 1024 * 1024).write(to: oversizedURL)

        let countSession = makeSession()
        countSession.addAttachments(Array(repeating: regularURL, count: 5))
        #expect(countSession.pendingAttachments.count == 4)
        #expect(countSession.validationError != nil)

        let sizeSession = makeSession()
        sizeSession.addAttachments([oversizedURL])
        #expect(sizeSession.pendingAttachments.isEmpty)
        #expect(sizeSession.validationError != nil)
    }

    @Test("Attachments enforce the combined message-size limit")
    func attachmentsEnforceCombinedMessageSizeLimit() throws {
        let firstURL = temporaryURL(named: "first.png")
        let secondURL = temporaryURL(named: "second.png")
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        try Data(repeating: 0, count: 11 * 1024 * 1024).write(to: firstURL)
        try Data(repeating: 0, count: 11 * 1024 * 1024).write(to: secondURL)

        let session = makeSession()
        session.addAttachments([firstURL, secondURL])

        #expect(session.pendingAttachments.map(\.filename) == [firstURL.lastPathComponent])
        #expect(session.validationError == "Attachments can total up to 21 MB per message.")
    }

    @Test("Attachments reject unsupported file extensions")
    func attachmentsRejectUnsupportedFileExtensions() throws {
        let url = temporaryURL(named: "unsupported.exe")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([1]).write(to: url)

        let session = makeSession()
        session.addAttachments([url])

        #expect(session.pendingAttachments.isEmpty)
        #expect(session.validationError?.contains("isn't a supported file type") == true)
    }

    @Test("The exchange history retains the newest twenty entries")
    func exchangeHistoryCapsAtTwenty() async throws {
        let model = makeDemoModel()
        let session = makeSession()

        for index in 0...20 {
            session.draft = "prompt \(index)"
            await session.submit(model: model)
        }

        #expect(session.exchanges.count == 20)
        #expect(!session.exchanges.contains(where: { $0.prompt == "prompt 0" }))
        let newest = try #require(session.exchanges.last)
        #expect(newest.prompt == "prompt 20")
    }

    @Test("Cap eviction retains an in-flight exchange")
    func capEvictionRetainsInFlightExchange() {
        let session = makeSession()
        let exchanges = (0..<20).map { index in
            exchange(id: "seed-\(index)", status: index == 10 ? .running : .completed)
        }
        session.seedExchangesForTesting(exchanges)

        session.appendExchangeForTesting(exchange(id: "new", status: .completed))

        #expect(session.exchanges.count == 20)
        #expect(session.exchanges.contains(where: { $0.id == "seed-10" }))
        #expect(!session.exchanges.contains(where: { $0.id == "seed-0" }))
    }

    @Test("Clearing removes all submitted exchanges")
    func clearEmptiesExchanges() async {
        let model = makeDemoModel()
        let session = makeSession()

        for prompt in ["first", "second", "third"] {
            session.draft = prompt
            await session.submit(model: model)
        }
        #expect(!session.exchanges.isEmpty)

        await session.clear(model: model)

        #expect(session.exchanges.isEmpty)
    }

    @Test("Unseen answer state follows collapsed and expanded submission")
    func unseenAnswerLifecycleFollowsCollapsedState() async {
        let model = makeDemoModel()
        let session = makeSession()
        session.draft = "Answer while collapsed"

        await session.submit(model: model)

        #expect(session.hasUnseenAnswer)
        session.markSeen()
        #expect(!session.hasUnseenAnswer)

        session.isCollapsed = false
        session.draft = "Answer while expanded"
        await session.submit(model: model)

        #expect(!session.hasUnseenAnswer)
    }

    @Test("Retry preserves the active composer state and resends the original prompt")
    func retryPreservesComposerStateAndUsesStoredRequest() async throws {
        let model = makeDemoModel()
        let session = makeSession()
        let original = exchange(
            id: "failed-run",
            status: .failed,
            prompt: "Display prompt",
            sentPrompt: "Stored request",
            error: "Failed",
            attachmentFilenames: ["original.png"],
            attachments: [HeadlessAgentAttachment(filename: "original.png", dataBase64: "b3JpZ2luYWw=")]
        )
        session.seedExchangesForTesting([original])
        session.seedThreadForTesting(.init(
            machineID: original.machineID,
            rootRunID: original.id,
            lastRunID: original.id,
            turnCount: 1
        ))
        session.draft = "New draft"
        session.selectedMachineID = "current-composer-machine"

        await session.retry(original, model: model)

        #expect(session.draft == "New draft")
        #expect(session.selectedMachineID == "current-composer-machine")
        #expect(session.exchanges.count == 2)
        let retried = try #require(session.exchanges.last)
        #expect(retried.machineID == original.machineID)
        #expect(retried.sentPrompt == original.sentPrompt)
        #expect(retried.attachmentFilenames == original.attachmentFilenames)
        #expect(retried.attachments.isEmpty)

        let demoRun = try await model.startHeadlessAgent(
            prompt: original.sentPrompt,
            machineID: original.machineID,
            mode: .act,
            model: HerdrHudModelRouting.visionModel,
            thinkingLevel: HerdrHudModelRouting.thinkingLevel,
            attachments: original.attachments
        )
        #expect(demoRun.model == HerdrHudModelRouting.visionModel)
        #expect(demoRun.thinkingLevel == HerdrHudModelRouting.thinkingLevel)
    }

    @Test("A fresh image submission pins the machine default rather than the global vision setting")
    func imageSubmissionsIgnoreConfiguredVisionModelForNewChats() async throws {
        let url = temporaryURL(named: "custom-vision.png")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)

        let defaults = makeDefaults(prefix: "custom-vision")
        let store = AgentModelSettingsStore(defaults: defaults)
        store.visionModel = "custom/vision"
        let session = HerdrHudSession(
            userDefaults: defaults,
            agentSettings: store,
            persistenceURL: temporaryURL(named: "hud-thread.json")
        )
        session.addAttachments([url])
        session.draft = "Describe this image"

        await session.submit(model: makeDemoModel())

        #expect(session.lastHeadlessRunForTesting?.model == "openai-codex/gpt-5.6-luna")
        #expect(session.lastHeadlessRunForTesting?.model != "custom/vision")
        #expect(session.exchanges.last?.modelLabel == "GPT-5.6 Luna")
        // The stored vision preference is retained for legacy conversations.
        #expect(store.visionModel == "custom/vision")
    }

    @Test("An existing conversation keeps the configured vision fallback for images")
    func legacyConversationKeepsConfiguredVisonFallback() async throws {
        let url = temporaryURL(named: "legacy-vision.png")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)

        let defaults = makeDefaults(prefix: "legacy-vision")
        let store = AgentModelSettingsStore(defaults: defaults)
        store.visionModel = "custom/vision"
        let persistenceURL = temporaryURL(named: "hud-thread.json")
        try HerdrHudPersistenceSnapshot(
            thread: .init(machineID: "demo1", rootRunID: "run-1", lastRunID: "run-1", turnCount: 1),
            exchanges: [exchange(id: "run-1", status: .completed)]
        ).save(to: persistenceURL)
        let session = HerdrHudSession(
            userDefaults: defaults,
            agentSettings: store,
            persistenceURL: persistenceURL
        )
        await session.waitForPersistenceRestore()
        session.addAttachments([url])
        session.draft = "Describe this image"

        await session.submit(model: makeDemoModel())

        #expect(session.lastHeadlessRunForTesting?.model == "custom/vision")
    }

    @Test("HUD submissions use the configured thinking level")
    func submissionsUseConfiguredThinkingLevel() async {
        let defaults = makeDefaults(prefix: "thinking-level")
        let store = AgentModelSettingsStore(defaults: defaults)
        store.hudThinkingLevel = .low
        let session = HerdrHudSession(
            userDefaults: defaults,
            agentSettings: store,
            persistenceURL: temporaryURL(named: "hud-thread.json")
        )
        session.draft = "What needs attention?"

        await session.submit(model: makeDemoModel())

        #expect(session.lastHeadlessRunForTesting?.thinkingLevel == "low")
    }

    @Test("HUD thinking selection persists, follows Settings, and applies to thread replies")
    func thinkingSelectionAppliesToThreadReplies() async {
        let defaults = makeDefaults(prefix: "hud-thinking-selection")
        let store = AgentModelSettingsStore(defaults: defaults)
        let session = HerdrHudSession(
            userDefaults: defaults,
            agentSettings: store,
            persistenceURL: temporaryURL(named: "hud-thread.json")
        )
        let model = makeDemoModel()
        store.hudThinkingLevel = .medium
        #expect(session.selectedThinkingLevel == .medium)

        session.selectedThinkingLevel = .high
        #expect(store.hudThinkingLevel == .high)
        #expect(AgentModelSettingsStore(defaults: defaults).hudThinkingLevel == .high)
        session.draft = "Summarize the sample project"
        await session.submit(model: model)
        #expect(session.lastHeadlessRunForTesting?.thinkingLevel == "high")
        #expect(session.thread != nil)

        session.selectedThinkingLevel = .low
        session.draft = "What should I do next?"
        await session.submit(model: model)
        #expect(session.lastHeadlessRunForTesting?.thinkingLevel == "low")
    }

    @Test("A fresh composer ignores the legacy shared HUD model and pins its machine default")
    func freshComposerIgnoresLegacySharedPreference() async {
        let model = makeDemoModel()
        let defaults = makeDefaults(prefix: "legacy-ignored")
        let store = AgentModelSettingsStore(defaults: defaults)
        store.hudModel = "missing/model"
        let session = HerdrHudSession(
            userDefaults: defaults,
            agentSettings: store,
            persistenceURL: temporaryURL(named: "hud-thread.json")
        )
        session.draft = "What needs attention?"

        await session.submit(model: model)

        #expect(session.lastHeadlessRunForTesting?.model == "openai-codex/gpt-5.6-luna")
        #expect(session.exchanges.last?.modelLabelIsProven == true)
        // The saved legacy preference is retained for existing conversations
        // and Notes; it is simply not the new chat's default.
        #expect(store.hudModel == "missing/model")
    }

    @Test("A restored legacy conversation keeps the shared HUD preference and its fallback")
    func legacyConversationKeepsSharedPreferenceFallback() async {
        let model = makeDemoModel()
        let defaults = makeDefaults(prefix: "legacy-preference")
        let store = AgentModelSettingsStore(defaults: defaults)
        store.hudModel = "missing/model"
        let persistenceURL = temporaryURL(named: "hud-thread.json")
        try? HerdrHudPersistenceSnapshot(
            thread: .init(machineID: "demo1", rootRunID: "run-1", lastRunID: "run-1", turnCount: 1),
            exchanges: [exchange(id: "run-1", status: .completed)]
        ).save(to: persistenceURL)
        let session = HerdrHudSession(
            userDefaults: defaults,
            agentSettings: store,
            persistenceURL: persistenceURL
        )
        await session.waitForPersistenceRestore()
        #expect(session.modelChoiceSource == .sharedPreference)
        #expect(session.selectedModel == "missing/model")
        await session.loadModels(model: model)
        session.draft = "What needs attention?"

        await session.submit(model: model)

        #expect(session.lastHeadlessRunForTesting?.model == nil)
        #expect(session.validationError != nil)
    }

    @Test("New-chat model selection is session-owned and never rewrites the legacy preference")
    func newChatModelSelectionIsSessionOwned() {
        let defaults = makeDefaults(prefix: "session-owned-model")
        let store = AgentModelSettingsStore(defaults: defaults)
        let session = HerdrHudSession(
            userDefaults: defaults,
            agentSettings: store,
            persistenceURL: temporaryURL(named: "hud-thread.json")
        )
        let candidate = PiAvailableModel(
            provider: "provider",
            modelID: "model",
            name: nil,
            reasoning: nil,
            contextWindow: nil
        )

        store.hudModel = "provider/direct"
        #expect(session.selectedModel == nil)
        #expect(session.modelChoice == .machineDefault)
        session.setSelectedModel(candidate)
        #expect(session.selectedModel == candidate.id)
        #expect(session.modelChoice == .explicit(PiModelIdentity(provider: "provider", id: "model", name: nil)))
        #expect(store.hudModel == "provider/direct")

        session.setSelectedModel(nil)
        #expect(session.selectedModel == nil)
        #expect(store.hudModel == "provider/direct")
    }

    @Test("A fresh composer selects the uniquely identified local machine, not the first roster entry")
    func freshComposerSelectsLocalMachine() {
        let defaults = makeDefaults(prefix: "local-machine")
        // A machine ID saved by an earlier chat is never inherited by a fresh
        // composer; it is only the Notes fallback.
        defaults.set("remote", forKey: HerdrHudSession.machineIDDefaultsKey)
        let session = HerdrHudSession(
            userDefaults: defaults,
            persistenceURL: temporaryURL(named: "hud-thread.json"),
            hostIdentity: HerdrHudHostIdentity(hostNames: ["this-mac.example.test"], addresses: [])
        )
        let model = HerdrAppModel(credentials: credentials, arguments: ["HerdrTests"], userDefaults: defaults)
        let remote = HerdrMachine(id: "remote", name: "Build", urlString: "https://build.example.test")
        let local = HerdrMachine(id: "local", name: "Renamed Desk", urlString: "https://this-mac.example.test")
        model.machines = [remote, local]

        #expect(session.selectedMachineID == nil)
        #expect(session.applyLocalMachineDefaultIfNeeded(in: model))
        #expect(session.selectedMachineID == local.id)

        // A previous remote choice is an explicit draft choice and is kept.
        session.selectedMachineID = remote.id
        #expect(!session.applyLocalMachineDefaultIfNeeded(in: model))
        #expect(session.selectedMachineID == remote.id)
    }

    @Test("A fresh composer resolves this Mac lazily instead of at session construction")
    func freshComposerHostIdentityIsLazy() {
        let defaults = makeDefaults(prefix: "lazy-host-identity")
        var resolutionCount = 0
        let session = HerdrHudSession(
            userDefaults: defaults,
            persistenceURL: temporaryURL(named: "hud-thread.json"),
            hostIdentityProvider: {
                resolutionCount += 1
                return HerdrHudHostIdentity(hostNames: ["this-mac.example.test"], addresses: [])
            }
        )
        let model = HerdrAppModel(credentials: credentials, arguments: ["HerdrTests"], userDefaults: defaults)
        model.machines = [HerdrMachine(id: "local", name: "Desk", urlString: "https://this-mac.example.test")]

        // Creating a session must not touch the resolver at all; every HUD
        // session paid that cost eagerly before the fresh-composer lookup.
        #expect(resolutionCount == 0)
        #expect(session.selectedMachineID == nil)

        #expect(session.applyLocalMachineDefaultIfNeeded(in: model))
        #expect(resolutionCount == 1)
        #expect(session.selectedMachineID == "local")

        // The resolved identity is cached: a second fresh resolution reuses it.
        session.selectedMachineID = nil
        #expect(session.applyLocalMachineDefaultIfNeeded(in: model))
        #expect(resolutionCount == 1)
        #expect(session.selectedMachineID == "local")
    }

    @Test("An unidentified local companion leaves a fresh composer unselected")
    func unidentifiedLocalMachineRequiresExplicitChoice() {
        let defaults = makeDefaults(prefix: "unidentified-machine")
        let session = HerdrHudSession(
            userDefaults: defaults,
            persistenceURL: temporaryURL(named: "hud-thread.json"),
            hostIdentity: HerdrHudHostIdentity(hostNames: ["unknown.example.test"], addresses: [])
        )
        let model = HerdrAppModel(credentials: credentials, arguments: ["HerdrTests"], userDefaults: defaults)
        model.machines = [HerdrMachine(id: "remote", name: "Build", urlString: "https://build.example.test")]

        #expect(!session.applyLocalMachineDefaultIfNeeded(in: model))
        #expect(session.selectedMachineID == nil)
        session.draft = "Where does this go?"
        #expect(session.isNewChat)
    }

    @Test("Switching a fresh draft's machine returns its model choice to that machine's default")
    func machineSwitchResetsFreshModelChoice() {
        let defaults = makeDefaults(prefix: "machine-switch-model")
        let session = HerdrHudSession(
            userDefaults: defaults,
            persistenceURL: temporaryURL(named: "hud-thread.json")
        )
        let candidate = PiAvailableModel(provider: "provider", modelID: "model", name: nil, reasoning: nil, contextWindow: nil)
        session.selectedMachineID = "first"
        session.setSelectedModel(candidate)
        #expect(session.selectedModel == candidate.id)

        session.selectedMachineID = "second"
        #expect(session.selectedModel == nil)
        #expect(session.modelChoice == .machineDefault)
    }

    @Test("An explicit draft choice survives collapsing and reopening the HUD")
    func explicitChoiceSurvivesCollapseAndReopen() {
        let session = makeSession()
        let candidate = PiAvailableModel(provider: "provider", modelID: "model", name: nil, reasoning: nil, contextWindow: nil)
        session.setSelectedModel(candidate)
        session.isCollapsed = true
        session.isCollapsed = false
        #expect(session.selectedModel == candidate.id)
        #expect(session.modelChoice == .explicit(PiModelIdentity(provider: "provider", id: "model", name: nil)))
    }

    @Test("A session-owned choice restores as session-owned; a legacy snapshot stays shared")
    func modelChoiceOwnershipRestores() async throws {
        let model = makeDemoModel()
        let defaults = makeDefaults(prefix: "restore-ownership")
        let store = AgentModelSettingsStore(defaults: defaults)
        let persistenceURL = temporaryURL(named: "hud-thread.json")

        let first = HerdrHudSession(
            userDefaults: defaults,
            agentSettings: store,
            persistenceURL: persistenceURL
        )
        let selected = PiAvailableModel(
            provider: "provider",
            modelID: "choice",
            name: "Choice",
            reasoning: true,
            contextWindow: nil
        )
        first.seedModelsForTesting(
            [selected],
            default: PiModelIdentity(provider: "openai-codex", id: "gpt-5.6-luna", name: nil),
            machineID: "demo1"
        )
        first.setSelectedModel(selected)
        first.draft = "First turn"
        await first.submit(model: model)
        var persisted: HerdrHudPersistenceSnapshot?
        for _ in 0..<200 {
            persisted = HerdrHudPersistenceSnapshot.load(from: persistenceURL)
            if persisted?.modelChoice != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(persisted?.modelChoice == .explicit(provider: "provider", id: "choice"))

        let restored = HerdrHudSession(
            userDefaults: defaults,
            agentSettings: store,
            persistenceURL: persistenceURL
        )
        await restored.waitForPersistenceRestore()
        #expect(restored.modelChoiceSource == .sessionOwned)
        #expect(restored.selectedModel == selected.id)

        // A version-1 cache without a choice record restores the conversation
        // on the shared legacy preference instead.
        let legacyURL = temporaryURL(named: "legacy-thread.json")
        try HerdrHudPersistenceSnapshot(
            thread: .init(machineID: "demo1", rootRunID: "run-1", lastRunID: "run-1", turnCount: 1),
            exchanges: [exchange(id: "run-1", status: .completed)]
        ).save(to: legacyURL)
        let legacy = HerdrHudSession(
            userDefaults: defaults,
            agentSettings: store,
            persistenceURL: legacyURL
        )
        await legacy.waitForPersistenceRestore()
        #expect(legacy.modelChoiceSource == .sharedPreference)
    }

    private func exchange(
        id: String,
        status: HeadlessAgentRunStatus,
        prompt: String? = nil,
        sentPrompt: String? = nil,
        error: String? = nil,
        attachmentFilenames: [String] = [],
        attachments: [HeadlessAgentAttachment] = []
    ) -> HerdrHudExchange {
        HerdrHudExchange(
            id: id,
            machineID: "demo1",
            prompt: prompt ?? id,
            sentPrompt: sentPrompt ?? id,
            response: status == .completed ? "Done" : nil,
            error: error,
            status: status,
            costUSD: nil,
            createdAt: .now,
            promotedPaneID: nil,
            attachmentFilenames: attachmentFilenames,
            attachments: attachments
        )
    }

    private func temporaryURL(named name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(name)")
    }

    private func makeDemoModel() -> HerdrAppModel {
        HerdrAppModel(credentials: credentials, 
            arguments: ["HerdrTests", "-HerdrDemoMode"],
            userDefaults: makeDefaults(prefix: "model")
        )
    }

    private func makeSession() -> HerdrHudSession {
        HerdrHudSession(
            userDefaults: makeDefaults(prefix: "session"),
            persistenceURL: temporaryURL(named: "hud-thread.json")
        )
    }

    private func makeDefaults(prefix: String) -> UserDefaults {
        let suiteName = "HerdrHudSessionTests.\(prefix).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not create isolated defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
