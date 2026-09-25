import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("HUD workspace launcher")
@MainActor
struct HerdrHudWorkspaceLauncherTests {
    @Test("The main workspace store resolves the exact workspace ID across renames, reordering, and duplicate labels")
    func resolvesExactWorkspaceID() throws {
        let suiteName = "MainWorkspaceStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let machine = HerdrMachine(id: "machine-1", name: "Desk", urlString: "http://localhost:9092")
        let store = HerdrHudMainWorkspaceStore(userDefaults: defaults)
        let target = workspace(id: "w-main", label: "Main")
        #expect(store.remember(workspace: target, for: machine) != nil)

        // A duplicate label, a rename, and a different order must not matter.
        let renamed = workspace(id: "w-main", label: "Renamed")
        let duplicate = workspace(id: "w-other", label: "Main")
        let resolved = store.workspace(for: machine, in: [duplicate, renamed])
        #expect(resolved?.workspaceID == "w-main")
        #expect(resolved?.label == "Renamed")
    }

    @Test("The main workspace store invalidates a destination when the endpoint is replaced")
    func endpointReplacementInvalidatesDestination() throws {
        let suiteName = "MainWorkspaceStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let original = HerdrMachine(id: "machine-1", name: "Desk", urlString: "http://localhost:9092")
        let replaced = HerdrMachine(id: "machine-1", name: "Desk", urlString: "http://localhost:9093")
        let store = HerdrHudMainWorkspaceStore(userDefaults: defaults)
        #expect(store.remember(workspace: workspace(id: "w-main", label: "Main"), for: original) != nil)

        #expect(store.destination(for: replaced) == nil)
        #expect(store.workspace(for: replaced, in: [workspace(id: "w-main", label: "Main")]) == nil)
        #expect(store.destination(for: original)?.workspaceID == "w-main")
    }

    @Test("The main workspace store does not reassign a removed workspace to a same-labeled neighbor")
    func removedWorkspaceDoesNotReassign() throws {
        let suiteName = "MainWorkspaceStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let machine = HerdrMachine(id: "machine-1", name: "Desk", urlString: "http://localhost:9092")
        let store = HerdrHudMainWorkspaceStore(userDefaults: defaults)
        #expect(store.remember(workspace: workspace(id: "w-main", label: "Main"), for: machine) != nil)

        let replacement = workspace(id: "w-new", label: "Main")
        #expect(store.workspace(for: machine, in: [replacement]) == nil)
    }

    @Test("The main workspace store persists its choice across instances and can forget it")
    func persistsAndForgets() throws {
        let suiteName = "MainWorkspaceStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let machine = HerdrMachine(id: "machine-1", name: "Desk", urlString: "http://localhost:9092")
        let first = HerdrHudMainWorkspaceStore(userDefaults: defaults)
        #expect(first.remember(workspace: workspace(id: "w-main", label: "Main"), for: machine) != nil)

        let second = HerdrHudMainWorkspaceStore(userDefaults: defaults)
        #expect(second.destination(for: machine)?.workspaceID == "w-main")

        second.forget(for: machine)
        #expect(HerdrHudMainWorkspaceStore(userDefaults: defaults).destination(for: machine) == nil)
    }

    @Test("The main workspace store rejects a workspace stamped for another machine")
    func rejectsForeignWorkspace() throws {
        let suiteName = "MainWorkspaceStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let machine = HerdrMachine(id: "machine-1", name: "Desk", urlString: "http://localhost:9092")
        let other = HerdrMachine(id: "machine-2", name: "Build", urlString: "http://localhost:9093")
        let store = HerdrHudMainWorkspaceStore(userDefaults: defaults)

        let foreign = workspace(id: "w-main", label: "Main", machineID: "machine-2")
        #expect(store.remember(workspace: foreign, for: machine) == nil)
        #expect(store.destination(for: machine) == nil)

        #expect(store.remember(workspace: workspace(id: "w-main", label: "Main"), for: machine) != nil)
        #expect(store.destination(for: other) == nil)
    }

    private func workspace(id: String, label: String, machineID: String = "") -> HerdrWorkspace {
        var workspace = HerdrWorkspace(
            workspaceID: id,
            number: 1,
            label: label,
            focused: false,
            paneCount: 1,
            tabCount: 1,
            activeTabID: "\(id):t1",
            agentStatus: .idle
        )
        if !machineID.isEmpty { workspace = workspace.stamped(machineID: machineID) }
        return workspace
    }

    @Test("Creates in the exact workspace, pins options, and prompts only the returned pane")
    func createsInExactWorkspaceWithPinnedOptions() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let attachment = try makeAttachment(filename: "notes.txt", contents: "hello", in: directory)
        let client = FakeWorkspaceLaunchClient(
            capabilities: [HerdrHudWorkspaceLauncher.requiredCapability],
            workspaceIDs: ["w-other", "w-main"],
            paneID: "w-main:p9"
        )
        let launcher = HerdrHudWorkspaceLauncher(client: client, storeURL: storeURL(in: directory))
        let submission = makeSubmission(
            prompt: "Summarize this",
            folder: HerdrHudWorkingFolder(path: "/Users/example/project"),
            attachments: [attachment]
        )

        let receipt = try await launcher.launch(submission)

        #expect(receipt.phase == .sent)
        #expect(receipt.workspaceID == "w-main")
        #expect(receipt.paneID == "w-main:p9")
        #expect(receipt.scopedPaneID == "machine-1|w-main:p9")

        let creates = await client.createCalls
        #expect(creates.count == 1)
        let create = try #require(creates.first)
        #expect(create.workspaceID == "w-main")
        #expect(create.cwd == "/Users/example/project")
        #expect(create.reuseNamedTab == false)
        #expect(create.focus == false)
        #expect(create.thinkingLevel == "high")
        #expect(create.model == QuickPiSessionModel(provider: "anthropic", id: "claude-sonnet"))
        #expect(create.tabID == nil)
        #expect(create.workspaceLabel == nil)
        #expect(create.tabLabel == nil)

        let uploads = await client.uploadRequests
        #expect(uploads == ["notes.txt"])
        let prompts = await client.promptCalls
        #expect(prompts.count == 1)
        let prompt = try #require(prompts.first)
        #expect(prompt.paneID == "w-main:p9")
        #expect(prompt.disposition == .prompt)
        #expect(prompt.waitForIdle == false)
        #expect(prompt.text == "Summarize this\n\nAttachment: `/uploads/notes.txt`")
    }

    @Test("A machine's declared catalog default reaches the outgoing create request")
    func policyDefaultReachesCreate() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let declared = PiModelIdentity(provider: "openai-codex", id: "gpt-5.6-luna", name: nil)
        let catalog = HerdrHudMachineModelCatalog(
            machineID: "machine-2",
            isAvailable: true,
            models: [
                PiAvailableModel(provider: "openai-codex", modelID: "gpt-5.6-luna", name: nil, reasoning: true, contextWindow: nil)
            ],
            defaultModel: declared
        )
        let policy = HerdrHudNewChatPolicy()
        let resolved = try policy.resolveDefaultModel(for: "machine-2", catalog: catalog)

        let client = FakeWorkspaceLaunchClient()
        let launcher = HerdrHudWorkspaceLauncher(client: client, storeURL: storeURL(in: directory))
        _ = try await launcher.launch(makeSubmission(machineID: "machine-2", model: resolved))

        let creates = await client.createCalls
        #expect(creates.first?.model == QuickPiSessionModel(provider: "openai-codex", id: "gpt-5.6-luna"))
    }

    @Test("The home folder choice travels as the companion's home alias")
    func homeFolderUsesHomeAlias() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = FakeWorkspaceLaunchClient()
        let launcher = HerdrHudWorkspaceLauncher(client: client, storeURL: storeURL(in: directory))

        _ = try await launcher.launch(makeSubmission(folder: .home))

        let creates = await client.createCalls
        #expect(creates.first?.cwd == "~")
    }

    @Test("An older companion is refused before any launch fields are sent")
    func olderCompanionIsRefused() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = FakeWorkspaceLaunchClient(capabilities: ["pane-retirement-v1"])
        let launcher = HerdrHudWorkspaceLauncher(client: client, storeURL: storeURL(in: directory))

        await #expect(throws: HerdrHudWorkspaceLaunchError.unsupportedCompanion(machineName: "Desk")) {
            try await launcher.launch(makeSubmission())
        }

        let creates = await client.createCalls
        let prompts = await client.promptCalls
        let uploads = await client.uploadRequests
        #expect(creates.isEmpty)
        #expect(prompts.isEmpty)
        #expect(uploads.isEmpty)
        #expect(launcher.receipt(for: "launch-1") == nil)
    }

    @Test("A removed workspace is refused before create, even with a matching label elsewhere")
    func removedWorkspaceIsRefused() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = FakeWorkspaceLaunchClient(workspaceIDs: ["w-replacement"])
        let launcher = HerdrHudWorkspaceLauncher(client: client, storeURL: storeURL(in: directory))
        let submission = makeSubmission(workspaceID: "w-main", workspaceLabel: "Main")

        await #expect(throws: HerdrHudWorkspaceLaunchError.workspaceUnavailable) {
            try await launcher.launch(submission)
        }

        let creates = await client.createCalls
        let prompts = await client.promptCalls
        #expect(creates.isEmpty)
        #expect(prompts.isEmpty)
    }

    @Test("An upload failure leaves no pane and permits the same request to retry")
    func uploadFailureIsRecoverable() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let attachment = try makeAttachment(filename: "notes.txt", contents: "hello", in: directory)
        let client = FakeWorkspaceLaunchClient(uploadFailures: 1)
        let launcher = HerdrHudWorkspaceLauncher(client: client, storeURL: storeURL(in: directory))
        let submission = makeSubmission(attachments: [attachment])

        do {
            _ = try await launcher.launch(submission)
            Issue.record("Expected an upload failure")
        } catch let error as HerdrHudWorkspaceLaunchError {
            guard case let .attachmentUploadFailed(filename, _) = error else {
                Issue.record("Expected attachmentUploadFailed, got \(error)")
                return
            }
            #expect(filename == "notes.txt")
        }
        let failedCreateCalls = await client.createCalls
        #expect(failedCreateCalls.isEmpty)
        // The failed attempt never issued a create request, so its receipt is
        // replay-safe rather than an uncertain create.
        #expect(launcher.receipt(for: submission.requestID)?.phase == .prepared)

        let receipt = try await launcher.launch(submission)
        #expect(receipt.phase == .sent)
        let uploads = await client.uploadRequests
        let creates = await client.createCalls
        let prompts = await client.promptCalls
        #expect(uploads == ["notes.txt", "notes.txt"])
        #expect(creates.count == 1)
        #expect(prompts.count == 1)
    }

    @Test("A receipt that never attempted create safely reuses its request ID")
    func preparedReceiptRetriesSafely() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = FakeWorkspaceLaunchClient()
        let submission = makeSubmission()
        let prepared = HerdrHudWorkspaceLaunchReceipt(
            requestID: submission.requestID,
            fingerprint: submission.fingerprint,
            machineID: submission.machineID,
            endpoint: HerdrNotesSource.normalizedEndpoint(submission.endpoint),
            workspaceID: submission.workspaceID,
            tabID: nil,
            paneID: nil,
            phase: .prepared,
            createdAt: .now
        )
        try writeReceipts([prepared.requestID: prepared], to: storeURL(in: directory))

        let restarted = HerdrHudWorkspaceLauncher(client: client, storeURL: storeURL(in: directory))
        let receipt = try await restarted.launch(submission)

        #expect(receipt.phase == .sent)
        #expect(receipt.paneID == "w-main:p1")
        let creates = await client.createCalls
        let prompts = await client.promptCalls
        #expect(creates.count == 1)
        #expect(creates.first?.requestID == submission.requestID)
        #expect(prompts.count == 1)
    }

    @Test("A lost create response is never replayed, even after a restart")
    func lostCreateResponseIsNeverReplayed() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = FakeWorkspaceLaunchClient(createFailures: 1)
        let launcher = HerdrHudWorkspaceLauncher(client: client, storeURL: storeURL(in: directory))
        let submission = makeSubmission()

        do {
            _ = try await launcher.launch(submission)
            Issue.record("Expected an unconfirmed create")
        } catch let error as HerdrHudWorkspaceLaunchError {
            guard case let .createUnconfirmed(receipt, _) = error else {
                Issue.record("Expected createUnconfirmed, got \(error)")
                return
            }
            #expect(receipt?.phase == .creating)
            #expect(receipt?.paneID == nil)
        }
        #expect(launcher.receipt(for: submission.requestID)?.phase == .creating)
        let firstCreateCount = await client.createCalls.count
        let firstPromptCount = await client.promptCalls.count
        #expect(firstCreateCount == 1)
        #expect(firstPromptCount == 0)

        // The companion's request-ID cache is memory-only and expires. Even a
        // fresh launcher must refuse instead of creating a second pane.
        let restarted = HerdrHudWorkspaceLauncher(client: client, storeURL: storeURL(in: directory))
        do {
            _ = try await restarted.launch(submission)
            Issue.record("Expected the restarted launcher to refuse the uncertain create")
        } catch let error as HerdrHudWorkspaceLaunchError {
            guard case let .createUnconfirmed(receipt, _) = error else {
                Issue.record("Expected createUnconfirmed, got \(error)")
                return
            }
            #expect(receipt?.phase == .creating)
        }
        let restartedCreateCount = await client.createCalls.count
        let restartedPromptCount = await client.promptCalls.count
        #expect(restartedCreateCount == firstCreateCount)
        #expect(restartedPromptCount == firstPromptCount)
    }

    @Test("A failed prompt retains the confirmed pane and is never sent again, even after restart")
    func promptFailureNeverResends() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = FakeWorkspaceLaunchClient(promptFailures: 1)
        let launcher = HerdrHudWorkspaceLauncher(client: client, storeURL: storeURL(in: directory))
        let submission = makeSubmission()

        do {
            _ = try await launcher.launch(submission)
            Issue.record("Expected an unconfirmed prompt")
        } catch let error as HerdrHudWorkspaceLaunchError {
            guard case let .promptUnconfirmed(receipt, _) = error else {
                Issue.record("Expected promptUnconfirmed, got \(error)")
                return
            }
            #expect(receipt.paneID == "w-main:p1")
            #expect(receipt.scopedPaneID == "machine-1|w-main:p1")
            #expect(receipt.phase == .sending)
        }

        // The same process must not resend either.
        do {
            _ = try await launcher.launch(submission)
            Issue.record("Expected the launcher to refuse a resend")
        } catch let error as HerdrHudWorkspaceLaunchError {
            guard case let .promptUnconfirmed(receipt, _) = error else {
                Issue.record("Expected promptUnconfirmed, got \(error)")
                return
            }
            #expect(receipt.paneID == "w-main:p1")
        }
        let firstCreateCount = await client.createCalls.count
        let firstPromptCount = await client.promptCalls.count
        #expect(firstCreateCount == 1)
        #expect(firstPromptCount == 1)

        // A restarted launcher reads the durable sending receipt and refuses.
        let restarted = HerdrHudWorkspaceLauncher(client: client, storeURL: storeURL(in: directory))
        do {
            _ = try await restarted.launch(submission)
            Issue.record("Expected the restarted launcher to refuse")
        } catch let error as HerdrHudWorkspaceLaunchError {
            guard case let .promptUnconfirmed(receipt, _) = error else {
                Issue.record("Expected promptUnconfirmed, got \(error)")
                return
            }
            #expect(receipt.paneID == "w-main:p1")
        }
        let restartedCreateCount = await client.createCalls.count
        let restartedPromptCount = await client.promptCalls.count
        #expect(restartedCreateCount == 1)
        #expect(restartedPromptCount == 1)
    }

    @Test("A persisted unfinished create is refused instead of replayed after restart")
    func restartWithUnfinishedCreateRefusesReplay() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = FakeWorkspaceLaunchClient()
        let submission = makeSubmission()
        let pending = HerdrHudWorkspaceLaunchReceipt(
            requestID: submission.requestID,
            fingerprint: submission.fingerprint,
            machineID: submission.machineID,
            endpoint: HerdrNotesSource.normalizedEndpoint(submission.endpoint),
            workspaceID: submission.workspaceID,
            tabID: nil,
            paneID: nil,
            phase: .creating,
            createdAt: .now
        )
        try writeReceipts([pending.requestID: pending], to: storeURL(in: directory))

        let restarted = HerdrHudWorkspaceLauncher(client: client, storeURL: storeURL(in: directory))
        do {
            _ = try await restarted.launch(submission)
            Issue.record("Expected the persisted uncertain create to be refused")
        } catch let error as HerdrHudWorkspaceLaunchError {
            guard case let .createUnconfirmed(receipt, _) = error else {
                Issue.record("Expected createUnconfirmed, got \(error)")
                return
            }
            #expect(receipt?.requestID == submission.requestID)
        }

        let creates = await client.createCalls
        let prompts = await client.promptCalls
        #expect(creates.isEmpty)
        #expect(prompts.isEmpty)
    }

    @Test("A finished receipt returns its pane identity without touching the network")
    func finishedReceiptSkipsNetwork() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = FakeWorkspaceLaunchClient()
        let submission = makeSubmission()
        let receipt = HerdrHudWorkspaceLaunchReceipt(
            requestID: submission.requestID,
            fingerprint: submission.fingerprint,
            machineID: submission.machineID,
            endpoint: HerdrNotesSource.normalizedEndpoint(submission.endpoint),
            workspaceID: submission.workspaceID,
            tabID: "w-main:t1",
            paneID: "w-main:p1",
            phase: .sent,
            createdAt: .now
        )
        try writeReceipts([receipt.requestID: receipt], to: storeURL(in: directory))

        let launcher = HerdrHudWorkspaceLauncher(client: client, storeURL: storeURL(in: directory))
        let outcome = try await launcher.launch(submission)

        #expect(outcome.requestID == submission.requestID)
        #expect(outcome.phase == .sent)
        #expect(outcome.paneID == "w-main:p1")
        #expect(outcome.workspaceID == "w-main")
        #expect(outcome.scopedPaneID == "machine-1|w-main:p1")
        let capabilities = await client.capabilityRequests
        let creates = await client.createCalls
        let prompts = await client.promptCalls
        #expect(capabilities == 0)
        #expect(creates.isEmpty)
        #expect(prompts.isEmpty)
    }

    @Test("A reused request ID with changed content is rejected")
    func conflictingRequestIsRejected() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = FakeWorkspaceLaunchClient()
        let launcher = HerdrHudWorkspaceLauncher(client: client, storeURL: storeURL(in: directory))
        _ = try await launcher.launch(makeSubmission(prompt: "First"))

        await #expect(throws: HerdrHudWorkspaceLaunchError.conflictingRequest) {
            try await launcher.launch(makeSubmission(prompt: "Different"))
        }
        let creates = await client.createCalls
        let prompts = await client.promptCalls
        #expect(creates.count == 1)
        #expect(prompts.count == 1)
    }

    @Test("The durable receipt never contains the prompt")
    func receiptDoesNotPersistPromptContent() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = FakeWorkspaceLaunchClient()
        let store = storeURL(in: directory)
        let launcher = HerdrHudWorkspaceLauncher(client: client, storeURL: store)
        _ = try await launcher.launch(makeSubmission(prompt: "SECRET-PROMPT-CONTENT"))

        let saved = try String(contentsOf: store, encoding: .utf8)
        #expect(!saved.contains("SECRET-PROMPT-CONTENT"))
        #expect(saved.contains("machine-1"))
    }

    @Test("Unreadable attachments are refused before any upload or create")
    func unreadableAttachmentIsRefused() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = HerdrHudAttachment(
            id: UUID(),
            url: directory.appending(path: "missing.txt"),
            filename: "missing.txt",
            byteCount: 3,
            isImage: false
        )
        let client = FakeWorkspaceLaunchClient()
        let launcher = HerdrHudWorkspaceLauncher(client: client, storeURL: storeURL(in: directory))

        await #expect(throws: HerdrHudWorkspaceLaunchError.invalidSubmission(.unreadableAttachment(filename: "missing.txt"))) {
            try await launcher.launch(makeSubmission(attachments: [missing]))
        }
        let uploads = await client.uploadRequests
        let creates = await client.createCalls
        #expect(uploads.isEmpty)
        #expect(creates.isEmpty)
    }

    @Test("Too many attachments are refused before any upload")
    func tooManyAttachmentsAreRefused() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let attachments = try (0..<(HerdrHudSession.maxAttachments + 1)).map { index in
            try makeAttachment(filename: "file\(index).txt", contents: "x", in: directory)
        }
        let client = FakeWorkspaceLaunchClient()
        let launcher = HerdrHudWorkspaceLauncher(client: client, storeURL: storeURL(in: directory))

        await #expect(throws: HerdrHudWorkspaceLaunchError.invalidSubmission(
            .tooManyAttachments(maximum: HerdrHudSession.maxAttachments)
        )) {
            try await launcher.launch(makeSubmission(attachments: attachments))
        }
        let uploads = await client.uploadRequests
        #expect(uploads.isEmpty)
    }

    @Test("Stop during upload prevents the create request and the prompt")
    func stopDuringUploadPreventsDispatch() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let attachment = try makeAttachment(filename: "notes.txt", contents: "hello", in: directory)
        let client = GatedWorkspaceLaunchClient()
        let launcher = HerdrHudWorkspaceLauncher(client: client, storeURL: storeURL(in: directory))
        let submission = makeSubmission(attachments: [attachment])
        let stopped = StopFlag()

        let task = Task { try await launcher.launch(submission) { stopped.isStopped } }
        try await waitUntil { await !client.uploadRequests.isEmpty }
        stopped.isStopped = true
        await client.releaseUpload()

        do {
            _ = try await task.value
            Issue.record("Expected the launch to stop")
        } catch let error as HerdrHudWorkspaceLaunchError {
            guard case let .stopped(receipt) = error else {
                Issue.record("Expected stopped, got \(error)")
                return
            }
            #expect(receipt?.scopedPaneID == nil)
        }
        let creates = await client.createCalls
        let prompts = await client.promptCalls
        #expect(creates.isEmpty)
        #expect(prompts.isEmpty)
        // The create was never attempted, so the same request ID stays safely
        // retryable.
        #expect(launcher.receipt(for: submission.requestID)?.phase == .prepared)
    }

    @Test("Stop during create retains the confirmed pane and never sends the prompt")
    func stopDuringCreatePreservesConfirmedPane() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = GatedWorkspaceLaunchClient()
        let launcher = HerdrHudWorkspaceLauncher(client: client, storeURL: storeURL(in: directory))
        let submission = makeSubmission()
        let stopped = StopFlag()

        let task = Task { try await launcher.launch(submission) { stopped.isStopped } }
        try await waitUntil { await !client.createCalls.isEmpty }
        stopped.isStopped = true
        await client.releaseCreate()

        do {
            _ = try await task.value
            Issue.record("Expected the launch to stop")
        } catch let error as HerdrHudWorkspaceLaunchError {
            guard case let .stopped(receipt) = error else {
                Issue.record("Expected stopped, got \(error)")
                return
            }
            #expect(receipt?.paneID == "w-main:p1")
            #expect(receipt?.phase == .created)
            #expect(receipt?.scopedPaneID == "machine-1|w-main:p1")
        }
        let prompts = await client.promptCalls
        #expect(prompts.isEmpty)
        #expect(launcher.receipt(for: submission.requestID)?.phase == .created)

        // A later attempt keeps the pane and still refuses to send the
        // undispatched prompt automatically.
        do {
            _ = try await launcher.launch(submission)
            Issue.record("Expected the retained pane to block a replay")
        } catch let error as HerdrHudWorkspaceLaunchError {
            guard case let .promptNotSent(receipt) = error else {
                Issue.record("Expected promptNotSent, got \(error)")
                return
            }
            #expect(receipt.scopedPaneID == "machine-1|w-main:p1")
        }
        let retriedPrompts = await client.promptCalls
        #expect(retriedPrompts.isEmpty)
    }

    private func makeSubmission(
        machineID: String = "machine-1",
        endpoint: String = "http://localhost:9092",
        workspaceID: String = "w-main",
        workspaceLabel: String? = "Main",
        requestID: String = "launch-1",
        prompt: String = "Hello",
        folder: HerdrHudWorkingFolder = .home,
        model: PiModelIdentity = PiModelIdentity(provider: "anthropic", id: "claude-sonnet", name: nil),
        attachments: [HerdrHudAttachment] = []
    ) -> HerdrHudWorkspaceLaunchSubmission {
        HerdrHudWorkspaceLaunchSubmission(
            machineID: machineID,
            endpoint: endpoint,
            machineName: "Desk",
            workspaceID: workspaceID,
            workspaceLabel: workspaceLabel,
            requestID: requestID,
            label: "hud chat",
            folder: folder,
            model: model,
            thinkingLevel: .high,
            prompt: prompt,
            attachments: attachments
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeAttachment(
        filename: String,
        contents: String,
        in directory: URL
    ) throws -> HerdrHudAttachment {
        // Keep the exact filename as the last path component so recorded upload
        // names remain deterministic.
        let url = directory.appending(path: UUID().uuidString).appending(path: filename)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return HerdrHudAttachment(
            id: UUID(),
            url: url,
            filename: filename,
            byteCount: contents.utf8.count,
            isImage: false
        )
    }

    private func storeURL(in directory: URL) -> URL {
        directory.appending(path: "receipts.json")
    }

    private func writeReceipts(
        _ receipts: [String: HerdrHudWorkspaceLaunchReceipt],
        to url: URL
    ) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(receipts).write(to: url)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            guard clock.now < deadline else { throw LauncherWaitError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private enum LauncherWaitError: Error { case timedOut }
}

private actor FakeWorkspaceLaunchClient: HerdrHudWorkspaceLaunchClient {
    struct CreateCall: Equatable, Sendable {
        let label: String
        let requestID: String
        let workspaceID: String?
        let tabID: String?
        let cwd: String?
        let workspaceLabel: String?
        let tabLabel: String?
        let reuseNamedTab: Bool?
        let model: QuickPiSessionModel?
        let thinkingLevel: String?
        let focus: Bool?
    }

    struct PromptCall: Equatable, Sendable {
        let paneID: String
        let text: String
        let disposition: PiPromptDisposition
        let waitForIdle: Bool
    }

    private let capabilities: [String]
    private let workspaceIDs: [String]
    private let tabID: String
    private let paneID: String
    private var uploadFailuresRemaining: Int
    private var createFailuresRemaining: Int
    private var promptFailuresRemaining: Int

    private(set) var capabilityRequests = 0
    private(set) var topologyRequests = 0
    private(set) var uploadRequests: [String] = []
    private(set) var createCalls: [CreateCall] = []
    private(set) var promptCalls: [PromptCall] = []

    init(
        capabilities: [String] = [HerdrHudWorkspaceLauncher.requiredCapability],
        workspaceIDs: [String] = ["w-main"],
        uploadFailures: Int = 0,
        createFailures: Int = 0,
        promptFailures: Int = 0,
        tabID: String = "w-main:t1",
        paneID: String = "w-main:p1"
    ) {
        self.capabilities = capabilities
        self.workspaceIDs = workspaceIDs
        self.tabID = tabID
        self.paneID = paneID
        self.uploadFailuresRemaining = uploadFailures
        self.createFailuresRemaining = createFailures
        self.promptFailuresRemaining = promptFailures
    }

    func serverCapabilities() async throws -> ServerCapabilities {
        capabilityRequests += 1
        return ServerCapabilities(capabilities: capabilities)
    }

    func fetchWorkspaces() async throws -> WorkspacesResponse {
        topologyRequests += 1
        return WorkspacesResponse(workspaces: workspaceIDs.enumerated().map { index, id in
            HerdrWorkspace(
                workspaceID: id,
                number: index + 1,
                label: "Main",
                focused: false,
                paneCount: 1,
                tabCount: 1,
                activeTabID: "\(id):t1",
                agentStatus: .idle
            )
        })
    }

    func uploadAttachment(
        workspaceID: String,
        fileURL: URL,
        contentType: String
    ) async throws -> AttachmentUploadResponse {
        uploadRequests.append(fileURL.lastPathComponent)
        if uploadFailuresRemaining > 0 {
            uploadFailuresRemaining -= 1
            throw URLError(.timedOut)
        }
        let uploaded = UploadedAttachment(
            id: "attachment-\(uploadRequests.count)",
            filename: fileURL.lastPathComponent,
            originalFilename: fileURL.lastPathComponent,
            contentType: contentType,
            size: 1,
            path: "/uploads/\(fileURL.lastPathComponent)",
            workspaceID: workspaceID,
            createdAt: "2024-01-01T00:00:00Z"
        )
        return AttachmentUploadResponse(ok: true, attachment: uploaded, error: nil)
    }

    func createQuickPiSession(
        label: String,
        requestID: String,
        workspaceID: String?,
        tabID: String?,
        cwd: String?,
        sessionFile: String?,
        sessionID: String?,
        workspaceLabel: String?,
        tabLabel: String?,
        reuseNamedTab: Bool?,
        model: QuickPiSessionModel?,
        thinkingLevel: String?,
        focus: Bool?
    ) async throws -> QuickPiSessionResponse {
        createCalls.append(CreateCall(
            label: label,
            requestID: requestID,
            workspaceID: workspaceID,
            tabID: tabID,
            cwd: cwd,
            workspaceLabel: workspaceLabel,
            tabLabel: tabLabel,
            reuseNamedTab: reuseNamedTab,
            model: model,
            thinkingLevel: thinkingLevel,
            focus: focus
        ))
        if createFailuresRemaining > 0 {
            createFailuresRemaining -= 1
            throw URLError(.networkConnectionLost)
        }
        return QuickPiSessionResponse(
            ok: true,
            workspaceID: workspaceID ?? "w-created",
            tabID: self.tabID,
            paneID: paneID,
            createdWorkspace: false,
            createdTab: true,
            createdPane: true,
            piExtensionAttached: true,
            requestID: requestID,
            sessionID: nil
        )
    }

    func sendPiPrompt(
        paneID: String,
        text: String,
        disposition: PiPromptDisposition,
        waitForIdle: Bool
    ) async throws {
        promptCalls.append(PromptCall(
            paneID: paneID,
            text: text,
            disposition: disposition,
            waitForIdle: waitForIdle
        ))
        if promptFailuresRemaining > 0 {
            promptFailuresRemaining -= 1
            throw URLError(.timedOut)
        }
    }
}

/// A main-actor cancellation signal shared with a launcher's `isCancelled`
/// closure. The closure is synchronous and actor-isolated, so the test mutates
/// this value between the launcher's awaited network calls.
@MainActor
private final class StopFlag {
    var isStopped = false
}

/// One machine's client that parks uploads and creates until the test releases
/// them, so Stop can be proven to land at a deterministic point.
private actor GatedWorkspaceLaunchClient: HerdrHudWorkspaceLaunchClient {
    private let capabilities: [String]
    private var uploadGateIsOpen = false
    private var createGateIsOpen = false
    private var uploadWaiter: CheckedContinuation<Void, Never>?
    private var createWaiter: CheckedContinuation<Void, Never>?

    private(set) var uploadRequests: [String] = []
    private(set) var createCalls: [String] = []
    private(set) var promptCalls: [String] = []

    init(capabilities: [String] = [HerdrHudWorkspaceLauncher.requiredCapability]) {
        self.capabilities = capabilities
    }

    func serverCapabilities() async throws -> ServerCapabilities {
        ServerCapabilities(capabilities: capabilities)
    }

    func fetchWorkspaces() async throws -> WorkspacesResponse {
        WorkspacesResponse(workspaces: [
            HerdrWorkspace(
                workspaceID: "w-main",
                number: 1,
                label: "Main",
                focused: false,
                paneCount: 1,
                tabCount: 1,
                activeTabID: "w-main:t1",
                agentStatus: .idle
            )
        ])
    }

    func uploadAttachment(
        workspaceID: String,
        fileURL: URL,
        contentType: String
    ) async throws -> AttachmentUploadResponse {
        uploadRequests.append(fileURL.lastPathComponent)
        if !uploadGateIsOpen {
            await withCheckedContinuation { uploadWaiter = $0 }
        }
        let uploaded = UploadedAttachment(
            id: "attachment-\(uploadRequests.count)",
            filename: fileURL.lastPathComponent,
            originalFilename: fileURL.lastPathComponent,
            contentType: contentType,
            size: 1,
            path: "/uploads/\(fileURL.lastPathComponent)",
            workspaceID: workspaceID,
            createdAt: "2024-01-01T00:00:00Z"
        )
        return AttachmentUploadResponse(ok: true, attachment: uploaded, error: nil)
    }

    func releaseUpload() {
        uploadGateIsOpen = true
        uploadWaiter?.resume()
        uploadWaiter = nil
    }

    func createQuickPiSession(
        label: String,
        requestID: String,
        workspaceID: String?,
        tabID: String?,
        cwd: String?,
        sessionFile: String?,
        sessionID: String?,
        workspaceLabel: String?,
        tabLabel: String?,
        reuseNamedTab: Bool?,
        model: QuickPiSessionModel?,
        thinkingLevel: String?,
        focus: Bool?
    ) async throws -> QuickPiSessionResponse {
        createCalls.append(requestID)
        if !createGateIsOpen {
            await withCheckedContinuation { createWaiter = $0 }
        }
        return QuickPiSessionResponse(
            ok: true,
            workspaceID: workspaceID ?? "w-main",
            tabID: "w-main:t1",
            paneID: "w-main:p1",
            createdWorkspace: false,
            createdTab: true,
            createdPane: true,
            piExtensionAttached: true,
            requestID: requestID,
            sessionID: nil
        )
    }

    func releaseCreate() {
        createGateIsOpen = true
        createWaiter?.resume()
        createWaiter = nil
    }

    func sendPiPrompt(
        paneID: String,
        text: String,
        disposition: PiPromptDisposition,
        waitForIdle: Bool
    ) async throws {
        promptCalls.append(paneID)
    }
}
