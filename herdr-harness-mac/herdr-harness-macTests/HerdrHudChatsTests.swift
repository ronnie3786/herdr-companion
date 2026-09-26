import Foundation
import Synchronization
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("Independent HUD chats", .serialized)
@MainActor
struct HerdrHudChatsTests {
    @Test("Two live chats finish independently; follow-ups, drafts and cancellation stay with their owner")
    func concurrentChats() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let chats = fixture.chats
        let first = chats.composer
        first.draft = "Plan a garden"
        let firstTask = Task { await first.submit(model: fixture.model) { chats.submissionStarted(first) } }
        try await wait { first.thread != nil }
        #expect(first.isRunning)
        #expect(chats.composer !== first)

        let second = chats.composer
        second.draft = "Compare telescopes"
        let secondTask = Task { await second.submit(model: fixture.model) { chats.submissionStarted(second) } }
        try await wait { second.thread != nil }
        let firstID = try #require(first.thread?.lastRunID)
        let secondID = try #require(second.thread?.lastRunID)
        #expect(firstID != secondID)
        #expect(chats.visibleChats.count == 2)
        #expect(first.isRunning && second.isRunning)
        chats.composer.draft = "A third idea, not sent"

        HudChatsURLProtocol.finish(secondID)
        await secondTask.value
        #expect(first.isRunning)
        #expect(second.hasUnseenAnswer)
        #expect(second.exchanges.last?.response == "Answer for Compare telescopes")
        #expect(chats.composer.draft == "A third idea, not sent")
        #expect(chats.selectedID == nil)

        let secondChat = try #require(chats.visibleChats.first { $0.session === second })
        chats.select(secondChat.id)
        second.markSeen()
        second.draft = "Which is portable?"
        let followUp = Task { await second.submit(model: fixture.model) { chats.submissionStarted(second) } }
        try await wait { HudChatsURLProtocol.state.withLock { $0.starts.count == 3 } }
        try await wait { second.thread?.lastRunID != secondID }
        let followUpID = try #require(second.thread?.lastRunID)
        #expect(second.thread?.rootRunID == secondID)
        #expect(chats.visibleChats.count == 2)
        #expect(chats.composer.draft == "A third idea, not sent")
        #expect(chats.selectedID == nil)
        #expect(!second.hasUnseenAnswer)

        await first.stop(model: fixture.model)
        await firstTask.value
        #expect(first.exchanges.last?.status == .cancelled)
        #expect(second.isRunning)
        HudChatsURLProtocol.finish(followUpID)
        await followUp.value
        #expect(second.thread?.turnCount == 2)
        #expect(second.exchanges.map(\.prompt) == ["Compare telescopes", "Which is portable?"])
        #expect(HudChatsURLProtocol.state.withLock { $0.starts.allSatisfy { $0.profile == "hud-chat-v1" } })
    }

    @Test("Fresh chats send their selected folder and reset the next composer to home")
    func freshChatFolderRouting() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let chats = fixture.chats
        let first = chats.composer
        let customPath = "/synthetic/remote/project"
        #expect(first.selectWorkingFolder(path: customPath) == false)
        _ = try first.addCustomWorkingFolder(path: customPath, machineID: "synthetic")
        #expect(first.selectedWorkingFolder.path == customPath)
        first.draft = "Work from the selected folder"

        let task = Task { await first.submit(model: fixture.model) { chats.submissionStarted(first) } }
        try await wait { first.thread != nil }
        let runID = try #require(first.thread?.lastRunID)
        let start = try #require(HudChatsURLProtocol.state.withLock { $0.starts.first })
        #expect(start.cwd == customPath)

        HudChatsURLProtocol.finish(runID)
        await task.value
        #expect(chats.composer.selectedWorkingFolder.isHome)
        #expect(chats.composer.workingDirectory == nil)
    }

    @Test("Older servers reject custom folders without consuming local input")
    func customFolderRequiresCapabilityAndPreservesInput() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        let customPath = "/synthetic/remote/requires-upgrade"
        _ = try session.addCustomWorkingFolder(path: customPath, machineID: "synthetic")
        let attachmentURL = fixture.directory.appendingPathComponent("draft.txt")
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try Data("Synthetic draft".utf8).write(to: attachmentURL)
        session.addAttachments([attachmentURL])
        session.addQuote(ChatQuote(text: "Keep this quote", comment: "Use it", source: "synthetic"))
        session.draft = "Keep this draft"
        HudChatsURLProtocol.state.withLock { $0.hudChatWorkingDirectory = false }

        await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) }

        #expect(fixture.chats.composer === session)
        #expect(fixture.chats.visibleChats.isEmpty)
        #expect(session.draft == "Keep this draft")
        #expect(session.pendingAttachments.count == 1)
        #expect(session.pendingQuotes.count == 1)
        #expect(session.validationError?.contains("Update") == true)
        #expect(HudChatsURLProtocol.state.withLock { $0.starts.isEmpty })
    }

    @Test("Rapid custom-folder sends have one preflight owner and one POST")
    func rapidDoubleSendDuringCapabilityPreflight() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        _ = try session.addCustomWorkingFolder(path: "/synthetic/remote/serialized", machineID: "synthetic")
        session.draft = "Send only once"
        HudChatsURLProtocol.state.withLock { $0.delayNextCapabilities = true }

        let first = Task { await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) } }
        try await wait { HudChatsURLProtocol.state.withLock { $0.capabilityRequestCount == 1 } }
        let second = Task { await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) } }
        await second.value
        #expect(HudChatsURLProtocol.state.withLock { $0.capabilityRequestCount } == 1)
        #expect(HudChatsURLProtocol.state.withLock { $0.starts.isEmpty })

        HudChatsURLProtocol.releaseCapabilities()
        try await wait { HudChatsURLProtocol.state.withLock { $0.starts.count == 1 } }
        let runID = try #require(HudChatsURLProtocol.state.withLock { $0.starts.first?.id })
        HudChatsURLProtocol.finish(runID)
        await first.value
        #expect(HudChatsURLProtocol.state.withLock { $0.starts.count } == 1)
    }

    @Test("Composer edits made during preflight are not consumed")
    func editDuringCapabilityPreflightIsPreserved() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        _ = try session.addCustomWorkingFolder(path: "/synthetic/remote/edit-safe", machineID: "synthetic")
        session.draft = "Original snapshot"
        HudChatsURLProtocol.state.withLock { $0.delayNextCapabilities = true }

        let task = Task { await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) } }
        try await wait { HudChatsURLProtocol.state.withLock { $0.capabilityRequestCount == 1 } }
        let attachmentURL = fixture.directory.appendingPathComponent("added-during-preflight.txt")
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try Data("Synthetic later attachment".utf8).write(to: attachmentURL)
        session.draft = "Replacement draft"
        session.addAttachments([attachmentURL])
        session.addQuote(ChatQuote(text: "Later quote", comment: "Keep", source: "synthetic"))

        HudChatsURLProtocol.releaseCapabilities()
        try await wait { HudChatsURLProtocol.state.withLock { $0.starts.count == 1 } }
        let start = try #require(HudChatsURLProtocol.state.withLock { $0.starts.first })
        #expect(start.prompt == "Original snapshot")
        #expect(session.draft == "Replacement draft")
        #expect(session.pendingAttachments.count == 1)
        #expect(session.pendingQuotes.count == 1)
        HudChatsURLProtocol.finish(start.id)
        await task.value
    }

    @Test("Cancelling delayed preflight releases ownership without posting")
    func cancellationReleasesSubmissionOwnership() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        _ = try session.addCustomWorkingFolder(path: "/synthetic/remote/cancel-safe", machineID: "synthetic")
        session.draft = "Keep after cancellation"
        HudChatsURLProtocol.state.withLock { $0.delayNextCapabilities = true }

        let task = Task { await session.submit(model: fixture.model) }
        try await wait { HudChatsURLProtocol.state.withLock { $0.capabilityRequestCount == 1 } }
        await session.stop(model: fixture.model)
        HudChatsURLProtocol.releaseCapabilities()
        await task.value

        #expect(!session.isRunning)
        #expect(session.draft == "Keep after cancellation")
        #expect(HudChatsURLProtocol.state.withLock { $0.starts.isEmpty })
    }

    @Test("Existing custom-folder roots continue without cwd capability or cwd payload")
    func customFolderContinuationOmitsWorkingDirectory() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        let canonicalPath = "/Users/example/synthetic-project"
        _ = try session.addCustomWorkingFolder(path: canonicalPath, machineID: "synthetic")
        session.draft = "Create the saved root"
        let first = Task { await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) } }
        try await wait { session.thread != nil }
        let root = try #require(session.thread?.rootRunID)
        HudChatsURLProtocol.finish(root)
        await first.value

        HudChatsURLProtocol.state.withLock { $0.hudChatWorkingDirectory = false }
        session.draft = "Continue on an older compatible server"
        let continuation = Task { await session.submit(model: fixture.model) }
        try await wait { HudChatsURLProtocol.state.withLock { $0.starts.count == 2 } }
        let second = try #require(HudChatsURLProtocol.state.withLock { $0.starts.last })
        #expect(second.parent == root)
        #expect(second.cwd == nil)
        HudChatsURLProtocol.finish(second.id)
        await continuation.value
        #expect(session.selectedWorkingFolder.path == canonicalPath)
    }

    @Test("History turns retain their original working folder")
    func historyRetainsWorkingFolder() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let customPath = "/synthetic/remote/original"
        let session = fixture.chats.composer
        _ = try session.addCustomWorkingFolder(path: customPath, machineID: "synthetic")
        session.draft = "Keep this folder"
        let task = Task { await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) } }
        try await wait { session.thread != nil }
        let rootID = try #require(session.thread?.rootRunID)
        let chatID = try #require(fixture.chats.visibleChats.first?.id)
        HudChatsURLProtocol.finish(rootID)
        await task.value
        let cache = fixture.directory.appendingPathComponent("hud-chats/\(chatID).json")
        try await wait { HerdrHudPersistenceSnapshot.load(from: cache)?.exchanges.last?.workingFolderPath == customPath }

        let restored = HerdrHudChats(legacySession: fixture.prototype, defaults: fixture.defaults)
        let cached = try #require(restored.chats.first { $0.id == chatID }?.session)
        await cached.waitForPersistenceRestore()
        #expect(cached.selectedWorkingFolder.path == customPath)
        #expect(cached.workingDirectory == customPath)
    }

    @Test("Reopening a dismissed history chat keeps its original folder")
    func dismissedHistoryRetainsWorkingFolder() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let customPath = "/synthetic/remote/reopened"
        let session = fixture.chats.composer
        _ = try session.addCustomWorkingFolder(path: customPath, machineID: "synthetic")
        session.draft = "Remember this folder"
        let task = Task { await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) } }
        try await wait { session.thread != nil }
        let rootID = try #require(session.thread?.rootRunID)
        let chatID = try #require(fixture.chats.visibleChats.first?.id)
        HudChatsURLProtocol.finish(rootID)
        await task.value

        let summary = HudChatSummary(id: rootID, title: "Remember this folder", updatedAt: "2026-09-01T12:00:00Z",
                                     latestRunId: rootID, turnCount: 1, status: .completed, cwd: customPath,
                                     sessionId: nil, promotedPaneId: nil)
        try await fixture.chats.dismiss(chatID, model: fixture.model)
        let reopenedID = try await fixture.chats.openHistory(summary, machineID: "synthetic", model: fixture.model)
        let reopened = try #require(fixture.chats.chats.first { $0.id == reopenedID })
        #expect(reopened.session.selectedWorkingFolder.path == customPath)
    }

    @Test("History reuses active roots and relaunch reattaches without another submission")
    func restorationAndHistoryDeduplication() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let submitted = fixture.chats.composer
        submitted.draft = "Sketch a reading nook"
        let task = Task { await submitted.submit(model: fixture.model) { fixture.chats.submissionStarted(submitted) } }
        try await wait { submitted.thread != nil }
        let runID = try #require(submitted.thread?.rootRunID)
        let chatID = try #require(fixture.chats.visibleChats.first?.id)
        let summary = HudChatSummary(id: runID, title: "Reading nook", updatedAt: "2026-09-01T12:00:00Z",
                                     latestRunId: runID, turnCount: 1, status: .running, cwd: nil,
                                     sessionId: nil, promotedPaneId: nil)
        let reopened = try await fixture.chats.openHistory(summary, machineID: "synthetic", model: fixture.model)
        #expect(reopened == chatID)
        #expect(fixture.chats.visibleChats.count == 1)

        let cache = fixture.directory.appendingPathComponent("hud-chats/\(chatID).json")
        try await wait { HerdrHudPersistenceSnapshot.load(from: cache)?.thread?.rootRunID == runID }
        let restored = HerdrHudChats(legacySession: fixture.prototype, defaults: fixture.defaults)
        await restored.restore(model: fixture.model)
        let restoredSession = try #require(restored.visibleChats.first?.session)
        #expect(restoredSession !== submitted)
        #expect(restoredSession.isRunning)
        #expect(restoredSession.thread?.rootRunID == runID)
        #expect(HudChatsURLProtocol.state.withLock { $0.starts.count } == 1)

        HudChatsURLProtocol.finish(runID)
        await task.value
        try await wait { !restoredSession.isRunning }
        try await wait { restoredSession.exchanges.last?.status == .completed }
        #expect(restoredSession.hasUnseenAnswer)
        try await restored.dismiss(chatID, model: fixture.model)
        #expect(restored.visibleChats.isEmpty)
        #expect(HudChatsURLProtocol.state.withLock { $0.deleteCount } == 0)
        let afterDismiss = HerdrHudChats(legacySession: fixture.prototype, defaults: fixture.defaults)
        await afterDismiss.restore(model: fixture.model)
        #expect(afterDismiss.visibleChats.isEmpty)
    }

    @Test("Visible and pre-submit refreshes adopt remote turns without replacing local input")
    func crossDeviceRefreshPreservesComposerAndPreflightsContinuation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        let initialAttachmentURL = fixture.directory.appendingPathComponent("accepted-local-metadata.txt")
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try Data("Synthetic accepted metadata".utf8).write(to: initialAttachmentURL)
        session.addAttachments([initialAttachmentURL])
        session.draft = "Initial turn"
        let firstTask = Task { await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) } }
        try await wait { session.thread != nil }
        let root = try #require(session.thread?.rootRunID)
        HudChatsURLProtocol.finish(root)
        await firstTask.value
        session.isCollapsed = false
        session.markSeen()

        let attachmentURL = fixture.directory.appendingPathComponent("remote-refresh.txt")
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try Data("Synthetic attachment".utf8).write(to: attachmentURL)
        session.addAttachments([attachmentURL])
        session.addQuote(ChatQuote(text: "Quoted detail", comment: "Preserve", source: "synthetic"))
        session.draft = "Local unsent reply"
        let remote = HudChatsURLProtocol.appendExternal(root: root, prompt: "Reply from iPhone")

        #expect(await session.refreshSavedHistory(model: fixture.model))
        #expect(session.thread?.rootRunID == root)
        #expect(session.thread?.lastRunID == remote)
        #expect(session.exchanges.map(\.prompt) == ["Initial turn", "Reply from iPhone"])
        #expect(session.exchanges.first?.localAttachments.count == 1)
        #expect(session.draft == "Local unsent reply")
        #expect(session.pendingAttachments.count == 1)
        #expect(session.pendingQuotes.count == 1)
        #expect(!session.hasUnseenAnswer)

        let newerRemote = HudChatsURLProtocol.appendExternal(root: root, prompt: "Another device reply")
        let localTask = Task { await session.submit(model: fixture.model) }
        try await wait { HudChatsURLProtocol.state.withLock { $0.starts.count == 4 } }
        let local = try #require(HudChatsURLProtocol.state.withLock { $0.starts.last })
        #expect(local.parent == newerRemote)
        #expect(local.root == root)
        #expect(session.pendingAttachments.isEmpty)
        #expect(session.pendingQuotes.isEmpty)
        HudChatsURLProtocol.finish(local.id)
        await localTask.value
    }

    @Test("Unchanged passive refresh preserves client errors and local attachment metadata")
    func unchangedPassiveRefreshIsNonDestructive() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        let attachmentURL = fixture.directory.appendingPathComponent("local-metadata.txt")
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try Data("Synthetic metadata".utf8).write(to: attachmentURL)
        session.addAttachments([attachmentURL])
        session.draft = "Keep local attachment metadata"
        let task = Task { await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) } }
        try await wait { session.thread != nil }
        let root = try #require(session.thread?.rootRunID)
        HudChatsURLProtocol.finish(root)
        await task.value
        let revision = session.exchangesRevision
        session.reportAttachmentError("Actionable local error")

        #expect(await session.refreshSavedHistoryPassivelyForTesting(model: fixture.model))

        #expect(session.exchangesRevision == revision)
        #expect(session.validationError == "Actionable local error")
        #expect(session.exchanges.first?.localAttachments.count == 1)
        #expect(HudChatsURLProtocol.state.withLock { $0.historyRequestCount } == 1)
    }

    @Test("End Chat waits for delayed continuation preflight and stops its accepted run")
    func endDuringHistoryPreflightKeepsExclusiveOwnership() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.draft = "Create root"
        let first = Task { await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) } }
        try await wait { session.thread != nil }
        let root = try #require(session.thread?.rootRunID)
        HudChatsURLProtocol.finish(root)
        await first.value

        HudChatsURLProtocol.state.withLock { $0.delayNextHistory = true }
        session.draft = "Continuation under end ownership"
        let submission = Task { await session.submit(model: fixture.model) }
        try await wait { HudChatsURLProtocol.state.withLock { $0.historyRequestCount == 1 } }
        let duplicate = Task { await session.submit(model: fixture.model) }
        await duplicate.value
        #expect(HudChatsURLProtocol.state.withLock { $0.starts.count } == 1)
        let ending = Task { try await session.endChat(model: fixture.model) }
        HudChatsURLProtocol.releaseHistory()

        try await ending.value
        await submission.value
        #expect(session.hasEnded)
        #expect(HudChatsURLProtocol.state.withLock { $0.starts.count } == 2)
        #expect(session.exchanges.last?.status == .cancelled)
    }

    @Test("Retrying an accepted failed turn appends to its freshest saved root")
    func acceptedFailedRetryContinuesRoot() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.draft = "Accepted request that fails"
        let first = Task { await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) } }
        try await wait { session.thread != nil }
        let root = try #require(session.thread?.rootRunID)
        HudChatsURLProtocol.fail(root)
        await first.value
        let failed = try #require(session.exchanges.last)
        #expect(failed.id == root)
        #expect(failed.status == .failed)

        let retry = Task { await session.retry(failed, model: fixture.model) }
        try await wait { HudChatsURLProtocol.state.withLock { $0.starts.count == 2 } }
        let acceptedRetry = try #require(HudChatsURLProtocol.state.withLock { $0.starts.last })
        #expect(acceptedRetry.parent == root)
        #expect(acceptedRetry.cwd == nil)
        HudChatsURLProtocol.finish(acceptedRetry.id)
        await retry.value
        #expect(session.thread?.lastRunID == acceptedRetry.id)
    }

    @Test("Retry continues the saved root and remains authoritative after passive refresh")
    func retryContinuesSavedRootAndSurvivesRefresh() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.draft = "Create root"
        let first = Task { await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) } }
        try await wait { session.thread != nil }
        let root = try #require(session.thread?.rootRunID)
        HudChatsURLProtocol.finish(root)
        await first.value

        session.draft = "Retry this accepted intent"
        HudChatsURLProtocol.state.withLock { $0.rejectNextStart = true }
        await session.submit(model: fixture.model)
        let failed = try #require(session.exchanges.last { $0.id.hasPrefix("hud-pending-") })
        session.draft = "Unrelated draft"
        let unrelatedAttachmentURL = fixture.directory.appendingPathComponent("unrelated-retry-draft.txt")
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try Data("Synthetic unrelated attachment".utf8).write(to: unrelatedAttachmentURL)
        session.addAttachments([unrelatedAttachmentURL])
        session.addQuote(ChatQuote(text: "Unrelated quote", comment: "Keep", source: "synthetic"))

        let retry = Task { await session.retry(failed, model: fixture.model) }
        try await wait { HudChatsURLProtocol.state.withLock { $0.starts.count == 2 } }
        let retried = try #require(HudChatsURLProtocol.state.withLock { $0.starts.last })
        #expect(retried.parent == root)
        #expect(retried.cwd == nil)
        HudChatsURLProtocol.finish(retried.id)
        await retry.value
        #expect(session.draft == "Unrelated draft")
        #expect(session.pendingAttachments.count == 1)
        #expect(session.pendingQuotes.count == 1)

        #expect(await session.refreshSavedHistoryPassivelyForTesting(model: fixture.model))
        #expect(session.thread?.lastRunID == retried.id)
        #expect(session.exchanges.contains(where: { $0.id == retried.id }))

        session.draft = "Continue after explicit retry"
        let continuation = Task { await session.submit(model: fixture.model) }
        try await wait { HudChatsURLProtocol.state.withLock { $0.starts.count == 3 } }
        let next = try #require(HudChatsURLProtocol.state.withLock { $0.starts.last })
        #expect(next.parent == retried.id)
        HudChatsURLProtocol.finish(next.id)
        await continuation.value
    }

    @Test("Retrying an unaccepted first turn adopts its returned root")
    func preAcceptanceRetryAdoptsRoot() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.draft = "Initial start can fail"
        HudChatsURLProtocol.state.withLock { $0.rejectNextStart = true }
        await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) }
        let failed = try #require(session.exchanges.last)
        #expect(failed.id.hasPrefix("hud-pending-"))
        #expect(session.thread == nil)
        session.draft = "Unrelated draft"

        let retry = Task { await session.retry(failed, model: fixture.model) }
        try await wait { HudChatsURLProtocol.state.withLock { $0.starts.count == 1 } }
        let accepted = try #require(HudChatsURLProtocol.state.withLock { $0.starts.first })
        HudChatsURLProtocol.finish(accepted.id)
        await retry.value

        #expect(session.thread?.rootRunID == accepted.id)
        #expect(session.thread?.lastRunID == accepted.id)
        #expect(session.draft == "Unrelated draft")
        #expect(session.exchanges.contains(where: { $0.id == accepted.id }))
    }

    @Test("Accepted failed turns without a saved root require New chat")
    func acceptedRetryWithoutThreadDoesNotFork() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        let accepted = HerdrHudExchange(
            id: "agr_accepted001",
            machineID: "synthetic",
            prompt: "Accepted request",
            sentPrompt: "Accepted request",
            response: nil,
            error: "Synthetic server failure",
            status: .failed,
            costUSD: nil,
            createdAt: .now,
            promotedPaneID: nil,
            attachmentFilenames: []
        )
        session.seedExchangesForTesting([accepted])

        await session.retry(accepted, model: fixture.model)

        #expect(session.validationError?.contains("Start a new chat") == true)
        #expect(HudChatsURLProtocol.state.withLock { $0.starts.isEmpty })
    }

    @Test("A cross-device append conflict refreshes without resubmitting the preserved draft")
    func appendConflictRefreshesWithoutRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.draft = "Initial turn"
        let firstTask = Task { await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) } }
        try await wait { session.thread != nil }
        let root = try #require(session.thread?.rootRunID)
        HudChatsURLProtocol.finish(root)
        await firstTask.value
        session.isCollapsed = false
        session.draft = "Preserve this continuation"
        HudChatsURLProtocol.state.withLock { $0.conflictNextStart = true }

        await session.submit(model: fixture.model)

        try await wait { session.thread?.lastRunID != root }
        #expect(session.exchanges.last?.prompt == "Conflicting device reply")
        #expect(session.draft == "Preserve this continuation")
        #expect(session.validationError?.contains("changed on another device") == true)
        #expect(HudChatsURLProtocol.state.withLock { $0.starts.count } == 2)
        #expect(!session.isRunning)
    }

    @Test("Offline restored runs cannot submit a stale continuation")
    func offlineRestoration() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.draft = "Compare trail maps"
        let task = Task { await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) } }
        try await wait { session.thread != nil }
        let id = try #require(fixture.chats.visibleChats.first?.id)
        let cache = fixture.directory.appendingPathComponent("hud-chats/\(id).json")
        try await wait { HerdrHudPersistenceSnapshot.load(from: cache)?.thread != nil }
        let restored = HerdrHudChats(legacySession: fixture.prototype, defaults: fixture.defaults)
        let cached = try #require(restored.chats.first { $0.id == id }?.session)
        await cached.waitForPersistenceRestore()
        #expect(cached.needsHistoryRefresh)
        cached.draft = "Do not duplicate this run"
        await cached.submit(model: fixture.model)
        #expect(cached.draft == "Do not duplicate this run")
        #expect(cached.validationError != nil)
        #expect(HudChatsURLProtocol.state.withLock { $0.starts.count } == 1)
        fixture.model.machineStates["synthetic"] = .disconnected
        let cancellationCount = HudChatsURLProtocol.state.withLock { $0.cancellationCount }
        await #expect(throws: HerdrHudChatEndError.self) {
            try await restored.end(id, model: fixture.model)
        }
        #expect(restored.visibleChats.count == 1)
        #expect(!cached.hasEnded && !cached.isEnding)
        #expect(cached.draft == "Do not duplicate this run")
        #expect(HudChatsURLProtocol.state.withLock { $0.cancellationCount } == cancellationCount)

        fixture.model.machineStates["synthetic"] = .live
        #expect(try await restored.end(id, model: fixture.model) == false)
        #expect(restored.visibleChats.isEmpty)
        #expect(cached.hasEnded)
        #expect(HudChatsURLProtocol.state.withLock { $0.cancellationCount } == cancellationCount + 1)
        await task.value
    }

    @Test("A rejected stop keeps observing the same run instead of stranding its bubble")
    func failedCancellationKeepsObserving() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.draft = "Plan a picnic"
        let task = Task { await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) } }
        try await wait { session.thread != nil }
        let id = try #require(session.thread?.lastRunID)
        HudChatsURLProtocol.state.withLock { $0.rejectNextCancellation = true }
        await session.stop(model: fixture.model)
        #expect(session.isRunning)
        #expect(session.errorMessage != nil)
        HudChatsURLProtocol.finish(id)
        await task.value
        #expect(session.exchanges.last?.status == .completed)
        #expect(session.hasUnseenAnswer)
    }

    @Test("A rejected start retains its own draft and does not overwrite the fresh composer")
    func failedStartKeepsItsChat() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let submitted = fixture.chats.composer
        submitted.draft = "Keep this idea"
        HudChatsURLProtocol.state.withLock { $0.rejectNextStart = true }
        await submitted.submit(model: fixture.model) {
            fixture.chats.submissionStarted(submitted)
            fixture.chats.composer.draft = "Another unsent idea"
        }
        #expect(fixture.chats.visibleChats.count == 1)
        #expect(submitted.exchanges.last?.status == .failed)
        #expect(submitted.draft == "Keep this idea")
        #expect(submitted.hasUnseenAnswer)
        #expect(fixture.chats.composer.draft == "Another unsent idea")
    }

    @Test("End Chat stops one run, removes only its bubble, and retains history")
    func endActiveChat() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let chats = fixture.chats
        let first = chats.composer
        first.draft = "Plan a picnic"
        let firstTask = Task { await first.submit(model: fixture.model) { chats.submissionStarted(first) } }
        try await wait { first.thread != nil }
        let firstChat = try #require(chats.visibleChats.first)
        let root = try #require(first.thread?.rootRunID)
        let second = chats.composer
        second.draft = "Compare trail maps"
        let secondTask = Task { await second.submit(model: fixture.model) { chats.submissionStarted(second) } }
        try await wait { second.thread != nil }
        let secondID = try #require(chats.visibleChats.first { $0.session === second }?.id)
        chats.select(secondID)
        #expect(try await chats.end(firstChat.id, model: fixture.model) == false)
        await firstTask.value
        #expect(first.hasEnded)
        #expect(first.exchanges.last?.status == .cancelled)
        #expect(chats.selectedID == secondID)
        #expect(chats.visibleChats.count == 1)
        #expect(second.isRunning)
        #expect(HudChatsURLProtocol.state.withLock { $0.deleteCount } == 0)
        first.draft = "A stale view must not resubmit an ended chat"
        await first.submit(model: fixture.model)
        #expect(HudChatsURLProtocol.state.withLock { $0.starts.count } == 2)

        let summary = HudChatSummary(id: root, title: "Plan a picnic", updatedAt: "2026-09-01T12:00:00Z",
                                     latestRunId: root, turnCount: 1, status: .cancelled, cwd: nil,
                                     sessionId: nil, promotedPaneId: nil)
        let reopenedID = try await chats.openHistory(summary, machineID: "synthetic", model: fixture.model)
        let reopened = try #require(chats.chats.first { $0.id == reopenedID })
        #expect(reopened.id != firstChat.id)
        #expect(!reopened.session.hasEnded)
        #expect(reopened.session.exchanges.last?.status == .cancelled)
        await second.stop(model: fixture.model)
        await secondTask.value
    }

    @Test("Failed End Chat retains the running bubble and can be retried")
    func failedEndIsRetryable() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.draft = "Plan a garden"
        let task = Task { await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) } }
        try await wait { session.thread != nil }
        let id = try #require(fixture.chats.visibleChats.first?.id)
        HudChatsURLProtocol.state.withLock { $0.rejectNextCancellation = true }
        await #expect(throws: HerdrHudChatEndError.self) {
            try await fixture.chats.end(id, model: fixture.model)
        }
        #expect(fixture.chats.visibleChats.count == 1)
        #expect(session.isRunning)
        #expect(!session.hasEnded && !session.isEnding)
        _ = try await fixture.chats.end(id, model: fixture.model)
        await task.value
        #expect(fixture.chats.visibleChats.isEmpty)
        #expect(session.hasEnded)
    }

    @Test("Smart Rename follows its chat across selection changes and persists for reopened history")
    func smartRenamePersistsForHistory() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.draft = "Plan a pollinator garden"
        let task = Task { await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) } }
        try await wait { session.thread != nil }
        let rootID = try #require(session.thread?.rootRunID)
        HudChatsURLProtocol.finish(rootID)
        await task.value
        let original = try #require(fixture.chats.visibleChats.first)
        fixture.chats.select(original.id)

        let runner = FakeNoteAIRunner()
        runner.mode = .succeed(#"{"title":"Pollinator Garden Plan"}"#)
        runner.onRun = { fixture.chats.select(nil) }
        try await fixture.chats.smartRename(original.id, model: fixture.model, runner: runner)

        let renamed = try #require(fixture.chats.chats.first { $0.id == original.id })
        #expect(renamed.displayTitle == "Pollinator Garden Plan")
        #expect(fixture.chats.selectedID == nil)
        let call = try #require(runner.calls.first)
        #expect(call.prompt.contains("Plan a pollinator garden"))
        #expect(call.prompt.contains("Answer for Plan a pollinator garden"))
        #expect(call.thinkingLevel == "low")

        let relaunched = HerdrHudChats(legacySession: fixture.prototype, defaults: fixture.defaults)
        #expect(relaunched.chats.first(where: { $0.id == original.id })?.displayTitle == "Pollinator Garden Plan")

        try await fixture.chats.dismiss(original.id, model: fixture.model)
        let summary = HudChatSummary(
            id: rootID,
            title: "Plan a pollinator garden",
            updatedAt: "2026-09-01T12:00:00Z",
            latestRunId: rootID,
            turnCount: 1,
            status: .completed,
            cwd: nil,
            sessionId: nil,
            promotedPaneId: nil
        )
        let reopenedID = try await fixture.chats.openHistory(summary, machineID: "synthetic", model: fixture.model)
        let reopened = try #require(fixture.chats.chats.first { $0.id == reopenedID })
        #expect(reopened.displayTitle == "Pollinator Garden Plan")
    }

    @Test("Smart Rename rejects duplicate work, invalid output, and stale results after removal")
    func smartRenameGuards() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.draft = "Compare synthetic trail maps"
        let task = Task { await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) } }
        try await wait { session.thread != nil }
        HudChatsURLProtocol.finish(try #require(session.thread?.lastRunID))
        await task.value
        let chat = try #require(fixture.chats.visibleChats.first)

        let invalid = FakeNoteAIRunner()
        invalid.mode = .succeed("not JSON")
        var duplicateError: Error?
        invalid.onRun = {
            do {
                try await fixture.chats.smartRename(chat.id, model: fixture.model, runner: invalid)
            } catch {
                duplicateError = error
            }
        }
        await #expect(throws: SmartRenameModelRouting.invalidOutputError(
            resolution: SmartRenameModelResolution(
                modelID: "synthetic/naming",
                thinkingLevel: .low,
                machineName: "Example Mac",
                notice: nil
            )
        )) {
            try await fixture.chats.smartRename(chat.id, model: fixture.model, runner: invalid)
        }
        #expect(duplicateError as? HerdrHudChats.SmartRenameError == .busy)
        #expect(fixture.chats.smartRenamingChatIDs.isEmpty)
        #expect(fixture.chats.chats.first(where: { $0.id == chat.id })?.displayTitle == chat.displayTitle)

        let stale = FakeNoteAIRunner()
        stale.mode = .succeed(#"{"title":"Stale Trail Map Title"}"#)
        stale.onRun = { try? await fixture.chats.dismiss(chat.id, model: fixture.model) }
        await #expect(throws: HerdrHudChats.SmartRenameError.changed) {
            try await fixture.chats.smartRename(chat.id, model: fixture.model, runner: stale)
        }
        #expect(!fixture.chats.chats.contains(where: { $0.id == chat.id }))
        #expect(fixture.chats.smartRenamingChatIDs.isEmpty)
    }

    @Test("A submitted prompt names a running chat before any assistant reply")
    func promptOnlyRunningChatRenames() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.draft = "Investigate the synthetic irrigation leak"
        let task = Task { await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) } }
        try await wait { session.thread != nil }
        #expect(session.isRunning)
        #expect(session.exchanges.last?.response == nil)
        // The accepted run identity is persisted separately while the visible
        // exchange remains the local placeholder until the run completes.
        #expect(session.exchanges.last?.id.hasPrefix("hud-pending-") == true)
        let chat = try #require(fixture.chats.chats.first { $0.session === session })

        let runner = FakeNoteAIRunner()
        runner.mode = .succeed(#"{"title":"Synthetic irrigation leak"}"#)
        let notice = try await fixture.chats.smartRename(chat.id, model: fixture.model, runner: runner)

        #expect(notice == nil)
        #expect(session.isRunning)
        #expect(fixture.chats.chats.first { $0.id == chat.id }?.displayTitle == "Synthetic irrigation leak")
        let call = try #require(runner.calls.first)
        #expect(call.machineID == "synthetic")
        #expect(call.mode == .ask)
        #expect(call.profile == "smart-rename-v1")
        #expect(call.systemPrompt == nil)
        #expect(call.model == "synthetic/naming")
        #expect(call.thinkingLevel == "low")
        #expect(call.prompt.contains("Investigate the synthetic irrigation leak"))
        #expect(!call.prompt.contains("Assistant:"))
        await session.stop(model: fixture.model)
        await task.value
    }

    @Test("A reply arriving during naming does not invalidate the rename")
    func completionDuringSmartRenameKeepsTitle() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.draft = "Compare synthetic trail maps"
        let task = Task { await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) } }
        try await wait { session.thread != nil }
        let runID = try #require(session.thread?.lastRunID)
        let chat = try #require(fixture.chats.chats.first { $0.session === session })
        let revisions = session.exchangesRevision

        let runner = FakeNoteAIRunner()
        runner.mode = .succeed(#"{"title":"Trail Map Comparison"}"#)
        runner.onRun = {
            HudChatsURLProtocol.finish(runID)
            await task.value
            #expect(session.exchangesRevision != revisions)
        }
        let notice = try await fixture.chats.smartRename(chat.id, model: fixture.model, runner: runner)

        #expect(notice == nil)
        #expect(session.exchanges.last?.id == runID)
        #expect(session.exchanges.last?.response == "Answer for Compare synthetic trail maps")
        #expect(fixture.chats.chats.first { $0.id == chat.id }?.displayTitle == "Trail Map Comparison")
    }

    @Test("A title created before acceptance follows the run into saved history")
    func pendingTitleFollowsAcceptedRun() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.draft = "Plan a synthetic water feature"
        HudChatsURLProtocol.state.withLock { $0.delayNextStart = true }
        let task = Task { await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) } }
        try await wait { session.exchanges.last?.id.hasPrefix("hud-pending-") == true }
        #expect(session.historyIdentity == nil)
        let chat = try #require(fixture.chats.chats.first { $0.session === session })

        let runner = FakeNoteAIRunner()
        runner.mode = .succeed(#"{"title":"Synthetic Water Feature"}"#)
        let notice = try await fixture.chats.smartRename(chat.id, model: fixture.model, runner: runner)

        #expect(notice == nil)
        #expect(session.exchanges.last?.id.hasPrefix("hud-pending-") == true)
        #expect(fixture.chats.chats.first { $0.id == chat.id }?.displayTitle == "Synthetic Water Feature")

        HudChatsURLProtocol.releaseStart()
        try await wait { session.historyIdentity != nil }
        let rootID = try #require(session.thread?.rootRunID)
        #expect(session.historyIdentity == "synthetic:\(rootID)")
        HudChatsURLProtocol.finish(rootID)
        await task.value

        try await fixture.chats.dismiss(chat.id, model: fixture.model)
        #expect(fixture.chats.visibleChats.isEmpty)
        let summary = HudChatSummary(id: rootID, title: "Plan a synthetic water feature",
                                     updatedAt: "2026-09-01T12:00:00Z", latestRunId: rootID, turnCount: 1,
                                     status: .completed, cwd: nil, sessionId: nil, promotedPaneId: nil)
        let reopenedID = try await fixture.chats.openHistory(summary, machineID: "synthetic", model: fixture.model)
        let reopened = try #require(fixture.chats.chats.first { $0.id == reopenedID })
        #expect(reopened.displayTitle == "Synthetic Water Feature")
    }

    @Test("A replaced conversation is not mistaken for the pending run's acceptance")
    func replacedConversationIsRejected() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.draft = "Plan a synthetic water feature"
        HudChatsURLProtocol.state.withLock { $0.delayNextStart = true }
        let task = Task { await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) } }
        try await wait { session.exchanges.last?.id.hasPrefix("hud-pending-") == true }
        let chat = try #require(fixture.chats.chats.first { $0.session === session })

        let runner = FakeNoteAIRunner()
        runner.mode = .succeed(#"{"title":"Wrong Conversation"}"#)
        runner.onRun = {
            let replacement = HerdrHudExchange(
                id: "agr_replacement0001",
                machineID: "synthetic",
                prompt: "A different synthetic conversation",
                sentPrompt: "A different synthetic conversation",
                response: nil,
                error: nil,
                status: .running,
                costUSD: nil,
                createdAt: .now,
                promotedPaneID: nil,
                attachmentFilenames: []
            )
            session.seedExchangesForTesting([replacement])
            session.seedThreadForTesting(HerdrHudSession.HerdrHudThread(
                machineID: "synthetic",
                rootRunID: "agr_replacement0001",
                lastRunID: "agr_replacement0001",
                turnCount: 1
            ))
        }
        await #expect(throws: HerdrHudChats.SmartRenameError.changed) {
            try await fixture.chats.smartRename(chat.id, model: fixture.model, runner: runner)
        }
        #expect(fixture.chats.chats.first { $0.id == chat.id }?.displayTitle == chat.displayTitle)
        #expect(fixture.chats.smartRenamingChatIDs.isEmpty)
        HudChatsURLProtocol.releaseStart()
        try await wait { HudChatsURLProtocol.state.withLock { !$0.starts.isEmpty } }
        let accepted = try #require(HudChatsURLProtocol.state.withLock { $0.starts.first?.id })
        HudChatsURLProtocol.finish(accepted)
        await task.value
    }

    @Test("A replaced saved root blocks a stale rename")
    func replacedSavedRootIsRejected() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.draft = "Compare synthetic trail maps"
        let task = Task { await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) } }
        try await wait { session.thread != nil }
        HudChatsURLProtocol.finish(try #require(session.thread?.lastRunID))
        await task.value
        let chat = try #require(fixture.chats.chats.first { $0.session === session })

        let runner = FakeNoteAIRunner()
        runner.mode = .succeed(#"{"title":"Stale Root Title"}"#)
        runner.onRun = {
            let other = HerdrHudExchange(
                id: "agr_otherroot0001",
                machineID: "synthetic",
                prompt: "Another synthetic conversation",
                sentPrompt: "Another synthetic conversation",
                response: "Synthetic reply",
                error: nil,
                status: .completed,
                costUSD: nil,
                createdAt: .now,
                promotedPaneID: nil,
                attachmentFilenames: []
            )
            session.seedExchangesForTesting([other])
            session.seedThreadForTesting(HerdrHudSession.HerdrHudThread(
                machineID: "synthetic",
                rootRunID: "agr_otherroot0001",
                lastRunID: "agr_otherroot0001",
                turnCount: 1
            ))
        }
        await #expect(throws: HerdrHudChats.SmartRenameError.changed) {
            try await fixture.chats.smartRename(chat.id, model: fixture.model, runner: runner)
        }
        #expect(fixture.chats.chats.first { $0.id == chat.id }?.displayTitle == chat.displayTitle)
    }

    @Test("A manual title edit during naming wins over the late AI title")
    func manualTitleEditWinsOverLateRename() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.draft = "Compare synthetic trail maps"
        let task = Task { await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) } }
        try await wait { session.thread != nil }
        HudChatsURLProtocol.finish(try #require(session.thread?.lastRunID))
        await task.value
        let chat = try #require(fixture.chats.chats.first { $0.session === session })

        let runner = FakeNoteAIRunner()
        runner.mode = .succeed(#"{"title":"Late AI Title"}"#)
        runner.onRun = { fixture.chats.setTitleForTesting("Manual Title", for: chat.id) }
        await #expect(throws: HerdrHudChats.SmartRenameError.changed) {
            try await fixture.chats.smartRename(chat.id, model: fixture.model, runner: runner)
        }

        let current = try #require(fixture.chats.chats.first { $0.id == chat.id })
        #expect(current.title == "Manual Title")
        #expect(current.displayTitle == "Manual Title")
    }

    @Test("HUD naming resolves the selected machine's catalog and rejects a missing preference")
    func hudRenameUsesSelectedMachineCatalog() async throws {
        let alpha = HerdrMachine(id: "alpha", name: "Alpha", urlString: "https://alpha.example.invalid")
        let beta = HerdrMachine(id: "beta", name: "Beta", urlString: "https://beta.example.invalid")
        let fixture = try Fixture(machines: [alpha, beta], catalogByHost: [
            "alpha.example.invalid": #"{"ok":true,"models":[{"provider":"alpha","id":"alpha-only","name":"Alpha Only","reasoning":true}],"default":{"provider":"alpha","id":"alpha-only","name":"Alpha Only"}}"#,
            "beta.example.invalid": #"{"ok":true,"models":[{"provider":"beta","id":"beta-only","name":"Beta Only","reasoning":true}],"default":{"provider":"beta","id":"beta-only","name":"Beta Only"}}"#,
        ])
        defer { fixture.cleanUp() }
        fixture.defaults.set("alpha/alpha-only", forKey: AgentModelSettings.smartRenameModelKey)
        fixture.defaults.set("high", forKey: AgentModelSettings.smartRenameThinkingLevelKey)
        let seeded = try seedPendingChat(fixture, machineID: "beta", prompt: "Synthetic beta task")

        let runner = FakeNoteAIRunner()
        runner.mode = .succeed(#"{"title":"Should not run"}"#)
        await #expect(throws: SmartRenameModelRoutingError.modelUnavailable(
            machineName: "Beta",
            model: "alpha/alpha-only"
        )) {
            try await fixture.chats.smartRename(seeded.chat.id, model: fixture.model, runner: runner)
        }

        #expect(runner.calls.isEmpty)
        #expect(fixture.chats.chats.first { $0.id == seeded.chat.id }?.title == "Synthetic beta task")
        #expect(fixture.chats.smartRenamingChatIDs.isEmpty)
        #expect(HudChatsURLProtocol.catalogHosts() == ["beta.example.invalid"])
        #expect(fixture.defaults.string(forKey: AgentModelSettings.smartRenameModelKey) == "alpha/alpha-only")
        #expect(fixture.defaults.string(forKey: AgentModelSettings.smartRenameThinkingLevelKey) == "high")
    }

    @Test("HUD naming sends an offered selection and selected effort unchanged")
    func hudRenameSendsOfferedSelectionUnchanged() async throws {
        let alpha = HerdrMachine(id: "alpha", name: "Alpha", urlString: "https://alpha.example.invalid")
        let beta = HerdrMachine(id: "beta", name: "Beta", urlString: "https://beta.example.invalid")
        let fixture = try Fixture(machines: [alpha, beta], catalogByHost: [
            "alpha.example.invalid": #"{"ok":true,"models":[{"provider":"alpha","id":"alpha-only","name":"Alpha Only","reasoning":true}],"default":{"provider":"alpha","id":"alpha-only","name":"Alpha Only"}}"#,
            "beta.example.invalid": #"{"ok":true,"models":[{"provider":"beta","id":"beta-only","name":"Beta Only","reasoning":true}],"default":{"provider":"beta","id":"beta-only","name":"Beta Only"}}"#,
        ])
        defer { fixture.cleanUp() }
        fixture.defaults.set("beta/beta-only", forKey: AgentModelSettings.smartRenameModelKey)
        fixture.defaults.set("high", forKey: AgentModelSettings.smartRenameThinkingLevelKey)
        let seeded = try seedPendingChat(fixture, machineID: "beta", prompt: "Synthetic beta task")

        let runner = FakeNoteAIRunner()
        runner.mode = .succeed(#"{"title":"Synthetic Beta Task"}"#)
        let notice = try await fixture.chats.smartRename(seeded.chat.id, model: fixture.model, runner: runner)

        let call = try #require(runner.calls.first)
        #expect(call.machineID == "beta")
        #expect(call.model == "beta/beta-only")
        #expect(call.thinkingLevel == "high")
        #expect(notice == nil)
        #expect(fixture.chats.chats.first { $0.id == seeded.chat.id }?.displayTitle == "Synthetic Beta Task")
        #expect(HudChatsURLProtocol.catalogHosts() == ["beta.example.invalid"])
    }

    @Test("A non-reasoning naming model rejects non-Off effort and keeps the saved effort")
    func nonReasoningNamingModelRejectsNonOffEffort() async throws {
        let fixture = try Fixture(catalogByHost: [
            "hud.example.invalid": #"{"ok":true,"models":[{"provider":"synthetic","id":"legacy","name":"Legacy","reasoning":false}],"default":{"provider":"synthetic","id":"legacy","name":"Legacy"}}"#,
        ])
        defer { fixture.cleanUp() }
        fixture.defaults.set("high", forKey: AgentModelSettings.smartRenameThinkingLevelKey)
        let seeded = try seedPendingChat(fixture, prompt: "Synthetic legacy model task")

        let runner = FakeNoteAIRunner()
        runner.mode = .succeed(#"{"title":"Should not run"}"#)
        await #expect(throws: SmartRenameModelRoutingError.thinkingLevelUnsupported(
            machineName: "Example Mac",
            model: "synthetic/legacy",
            level: .high
        )) {
            try await fixture.chats.smartRename(seeded.chat.id, model: fixture.model, runner: runner)
        }
        #expect(runner.calls.isEmpty)
        #expect(fixture.chats.chats.first { $0.id == seeded.chat.id }?.title == "Synthetic legacy model task")
        #expect(fixture.defaults.string(forKey: AgentModelSettings.smartRenameThinkingLevelKey) == "high")
    }

    @Test("A non-reasoning naming model runs with Off when Off is selected")
    func nonReasoningNamingModelRunsWithOff() async throws {
        let fixture = try Fixture(catalogByHost: [
            "hud.example.invalid": #"{"ok":true,"models":[{"provider":"synthetic","id":"legacy","name":"Legacy","reasoning":false}],"default":{"provider":"synthetic","id":"legacy","name":"Legacy"}}"#,
        ])
        defer { fixture.cleanUp() }
        fixture.defaults.set("off", forKey: AgentModelSettings.smartRenameThinkingLevelKey)
        let seeded = try seedPendingChat(fixture, prompt: "Synthetic legacy model task")

        let runner = FakeNoteAIRunner()
        runner.mode = .succeed(#"{"title":"Synthetic Legacy Task"}"#)
        let notice = try await fixture.chats.smartRename(seeded.chat.id, model: fixture.model, runner: runner)

        let call = try #require(runner.calls.first)
        #expect(call.model == "synthetic/legacy")
        #expect(call.thinkingLevel == "off")
        #expect(notice == nil)
        #expect(fixture.chats.chats.first { $0.id == seeded.chat.id }?.displayTitle == "Synthetic Legacy Task")
        #expect(fixture.defaults.string(forKey: AgentModelSettings.smartRenameThinkingLevelKey) == "off")
    }

    @Test("A whitespace-only HUD context is rejected with context-oriented wording")
    func whitespaceOnlyContextIsRejected() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let seeded = try seedPendingChat(fixture, prompt: "   \n\t ")

        let runner = FakeNoteAIRunner()
        runner.mode = .succeed(#"{"title":"Should not run"}"#)
        await #expect(throws: HerdrHudChats.SmartRenameError.unavailable) {
            try await fixture.chats.smartRename(seeded.chat.id, model: fixture.model, runner: runner)
        }
        #expect(runner.calls.isEmpty)
        #expect(
            HerdrHudChats.SmartRenameError.unavailable.errorDescription
                == "This HUD chat has no readable context to name yet."
        )
        #expect(fixture.chats.chats.first { $0.id == seeded.chat.id }?.displayTitle == "   ") // title fallback uses the raw prompt prefix
        #expect(fixture.chats.smartRenamingChatIDs.isEmpty)
    }

    @Test("A HUD naming-run failure names the selection and machine and keeps the title")
    func hudExecutionFailurePreservesTitle() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let seeded = try seedPendingChat(fixture, prompt: "Synthetic HUD failure task")

        let runner = FakeNoteAIRunner()
        runner.mode = .throwing(HudChatsFixtureError(message: "Synthetic provider failure"))
        await #expect(throws: SmartRenameExecutionError(
            machineName: "Example Mac",
            model: "synthetic/naming",
            thinkingLevel: .low,
            reason: "Synthetic provider failure"
        )) {
            try await fixture.chats.smartRename(seeded.chat.id, model: fixture.model, runner: runner)
        }

        #expect(runner.calls.count == 1)
        #expect(fixture.chats.chats.first { $0.id == seeded.chat.id }?.title == "Synthetic HUD failure task")
        #expect(fixture.chats.smartRenamingChatIDs.isEmpty)
    }

    @Test("Catalog failures preserve the title and explain what to fix")
    func catalogFailuresPreserveTitle() async throws {
        let cases: [(catalog: String, expected: SmartRenameModelRoutingError)] = [
            (#"{"ok":false,"error":{"code":"synthetic_catalog","message":"Synthetic catalog failure"}}"#,
             .catalogUnavailable(machineName: "Example Mac")),
            (#"{"ok":true,"models":[],"default":null}"#,
             .catalogEmpty(machineName: "Example Mac")),
            (#"{"ok":true,"models":[{"provider":"synthetic","id":"offered","name":"Offered","reasoning":true}],"default":{"provider":"synthetic","id":"missing","name":"Ghost Model"}}"#,
             .defaultModelUnavailable(machineName: "Example Mac", model: "Ghost Model")),
        ]
        for entry in cases {
            let fixture = try Fixture(catalogByHost: ["hud.example.invalid": entry.catalog])
            defer { fixture.cleanUp() }
            let seeded = try seedPendingChat(fixture, prompt: "Synthetic catalog failure task")
            let runner = FakeNoteAIRunner()
            runner.mode = .succeed(#"{"title":"Should Not Run"}"#)
            await #expect(throws: entry.expected) {
                try await fixture.chats.smartRename(seeded.chat.id, model: fixture.model, runner: runner)
            }
            #expect(runner.calls.isEmpty)
            #expect(fixture.chats.chats.first { $0.id == seeded.chat.id }?.title == "Synthetic catalog failure task")
            #expect(fixture.chats.smartRenamingChatIDs.isEmpty)
        }
    }

    @Test("Invalid HUD naming output reports the selection, keeps the title, and clears busy state")
    func invalidHudOutputIsActionable() async throws {
        let responses = [
            "not JSON",
            #"{"title":"HUD RAW-MARKER\ncontrol"}"#,
            #"{"title":"\#(String(repeating: "x", count: 81))"}"#,
        ]
        for response in responses {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            let seeded = try seedPendingChat(fixture, prompt: "Synthetic HUD invalid output")
            let runner = FakeNoteAIRunner()
            runner.mode = .succeed(response)

            do {
                _ = try await fixture.chats.smartRename(seeded.chat.id, model: fixture.model, runner: runner)
                Issue.record("Expected invalid HUD naming output to throw")
            } catch let error as SmartRenameExecutionError {
                #expect(error.machineName == "Example Mac")
                #expect(error.model == "synthetic/naming")
                #expect(error.thinkingLevel == .low)
                #expect(error.reason == SmartRenameModelRouting.invalidTitleReason)
            }
            #expect(runner.calls.count == 1)
            #expect(fixture.chats.chats.first { $0.id == seeded.chat.id }?.title == "Synthetic HUD invalid output")
            #expect(fixture.chats.smartRenamingChatIDs.isEmpty)
            #expect(fixture.defaults.string(forKey: AgentModelSettings.smartRenameModelKey) == nil)
        }
    }

    @Test("A placeholder adopted from saved history maps only to its exact root")
    func adoptedHistoryPlaceholderMapsToItsRoot() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.seedExchangesForTesting([
            HerdrHudExchange(
                id: "hud-pending-adopted",
                machineID: "synthetic",
                prompt: "Synthetic adopted submission",
                sentPrompt: "Synthetic adopted submission",
                response: nil,
                error: nil,
                status: .running,
                costUSD: nil,
                createdAt: .now,
                promotedPaneID: nil,
                attachmentFilenames: []
            )
        ])
        let acceptedID = HudChatsURLProtocol.appendExternal(
            root: "agr_adoptedroot01",
            prompt: "Synthetic adopted submission"
        )
        session.seedThreadForTesting(HerdrHudSession.HerdrHudThread(
            machineID: "synthetic",
            rootRunID: "agr_adoptedroot01",
            lastRunID: acceptedID,
            turnCount: 1
        ))

        try await session.openHistory(
            id: "agr_adoptedroot01",
            machineID: "synthetic",
            model: fixture.model
        )

        #expect(session.acceptedSubmissionID(forHistoryIdentity: "synthetic:agr_adoptedroot01") == "hud-pending-adopted")
        #expect(session.acceptedSubmissionID(forHistoryIdentity: "synthetic:agr_otherroot01") == nil)
    }

    @Test("A failed submission's pending title never attaches to a later accepted root")
    func pendingTitleDoesNotLeakToLaterSubmission() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        let sharedPrompt = "Synthetic failed submission"
        session.draft = sharedPrompt
        HudChatsURLProtocol.state.withLock { $0.rejectNextStart = true }
        await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) }
        let failedSubmissionID = try #require(session.exchanges.last?.id)
        #expect(failedSubmissionID.hasPrefix("hud-pending-"))
        #expect(session.exchanges.last?.status == .failed)
        #expect(session.thread == nil)
        let chat = try #require(fixture.chats.chats.first { $0.session === session })

        let runner = FakeNoteAIRunner()
        runner.mode = .succeed(#"{"title":"Failed Submission Title"}"#)
        _ = try await fixture.chats.smartRename(chat.id, model: fixture.model, runner: runner)
        #expect(fixture.chats.chats.first { $0.id == chat.id }?.displayTitle == "Failed Submission Title")

        // The next submission in the same chat reuses the same prompt text and
        // is accepted while the failed placeholder is still retained. Its root
        // must map to itself, never to the failed submission that was renamed
        // first, even though prompt matching alone cannot tell them apart.
        session.draft = sharedPrompt
        let accepted = Task { await session.submit(model: fixture.model) }
        try await wait { session.thread != nil }
        let acceptedRoot = try #require(session.thread?.rootRunID)
        let acceptedSubmissionID = try #require(session.exchanges.last?.id)
        #expect(acceptedSubmissionID.hasPrefix("hud-pending-"))
        #expect(session.acceptedSubmissionID(forHistoryIdentity: "synthetic:\(acceptedRoot)") == acceptedSubmissionID)
        #expect(session.acceptedSubmissionID(forHistoryIdentity: "synthetic:\(acceptedRoot)") != failedSubmissionID)
        HudChatsURLProtocol.finish(acceptedRoot)
        await accepted.value

        // Relaunch, remove the chat, and reopen the accepted root from saved
        // history: the failed submission's title must not surface there.
        let cache = fixture.directory.appendingPathComponent("hud-chats/\(chat.id).json")
        try await wait {
            HerdrHudPersistenceSnapshot.load(from: cache)?.exchanges.last?.id == acceptedRoot
        }
        let relaunched = HerdrHudChats(legacySession: fixture.prototype, defaults: fixture.defaults)
        await relaunched.restore(model: fixture.model)
        let relaunchedChat = try #require(relaunched.chats.first { $0.id == chat.id })
        try await relaunched.dismiss(relaunchedChat.id, model: fixture.model)
        let summary = HudChatSummary(
            id: acceptedRoot,
            title: "Synthetic accepted submission",
            updatedAt: "2026-09-01T12:00:00Z",
            latestRunId: acceptedRoot,
            turnCount: 1,
            status: .completed,
            cwd: nil,
            sessionId: nil,
            promotedPaneId: nil
        )
        let reopenedID = try await relaunched.openHistory(summary, machineID: "synthetic", model: fixture.model)
        let reopened = try #require(relaunched.chats.first { $0.id == reopenedID })
        #expect(reopened.displayTitle == "Synthetic accepted submission")
        #expect(reopened.displayTitle != "Failed Submission Title")
    }

    @Test("An explicit retry of a failed submission adopts its pending title")
    func pendingTitleFollowsExplicitRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.draft = "Synthetic retry target"
        HudChatsURLProtocol.state.withLock { $0.rejectNextStart = true }
        await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) }
        let failed = try #require(session.exchanges.last)
        #expect(failed.id.hasPrefix("hud-pending-"))
        #expect(failed.status == .failed)
        #expect(session.thread == nil)
        let chat = try #require(fixture.chats.chats.first { $0.session === session })

        let runner = FakeNoteAIRunner()
        runner.mode = .succeed(#"{"title":"Retried Submission Title"}"#)
        _ = try await fixture.chats.smartRename(chat.id, model: fixture.model, runner: runner)
        #expect(fixture.chats.chats.first { $0.id == chat.id }?.displayTitle == "Retried Submission Title")

        let retry = Task { await session.retry(failed, model: fixture.model) }
        try await wait { session.thread != nil }
        let retryRoot = try #require(session.thread?.rootRunID)
        #expect(session.acceptedSubmissionID(forHistoryIdentity: "synthetic:\(retryRoot)") == failed.id)
        HudChatsURLProtocol.finish(retryRoot)
        await retry.value

        try await fixture.chats.dismiss(chat.id, model: fixture.model)
        let summary = HudChatSummary(
            id: retryRoot,
            title: "Synthetic retry target",
            updatedAt: "2026-09-01T12:00:00Z",
            latestRunId: retryRoot,
            turnCount: 1,
            status: .completed,
            cwd: nil,
            sessionId: nil,
            promotedPaneId: nil
        )
        let reopenedID = try await fixture.chats.openHistory(summary, machineID: "synthetic", model: fixture.model)
        let reopened = try #require(fixture.chats.chats.first { $0.id == reopenedID })
        #expect(reopened.displayTitle == "Retried Submission Title")
    }

    @Test("A pending title belongs to its own chat and submission when another chat is accepted first")
    func pendingTitleStaysWithItsOwnSubmission() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let prefix = String(repeating: "Synthetic shared pending prefix ", count: 5)
        let first = fixture.chats.composer
        first.draft = prefix + "alpha detail"
        HudChatsURLProtocol.state.withLock { $0.delayNextStart = true }
        let firstTask = Task { await first.submit(model: fixture.model) { fixture.chats.submissionStarted(first) } }
        try await wait { first.exchanges.last?.id.hasPrefix("hud-pending-") == true }
        let firstChat = try #require(fixture.chats.chats.first { $0.session === first })
        let firstSubmissionID = try #require(first.exchanges.last?.id)
        #expect(firstSubmissionID.hasPrefix("hud-pending-"))

        let runner = FakeNoteAIRunner()
        runner.mode = .succeed(#"{"title":"Alpha Pending Title"}"#)
        _ = try await fixture.chats.smartRename(firstChat.id, model: fixture.model, runner: runner)
        #expect(fixture.chats.chats.first { $0.id == firstChat.id }?.displayTitle == "Alpha Pending Title")

        // A second chat on the same machine submits the same 120-character
        // prefix while the first submission is still pending. Its acceptance
        // must not consume the first chat's pending title.
        let second = fixture.chats.composer
        second.draft = prefix + "beta detail"
        let secondTask = Task { await second.submit(model: fixture.model) { fixture.chats.submissionStarted(second) } }
        try await wait { second.thread != nil }
        let secondChat = try #require(fixture.chats.chats.first { $0.session === second })
        #expect(secondChat.displayTitle == String((prefix + "beta detail").prefix(120)))
        #expect(secondChat.displayTitle != "Alpha Pending Title")

        // Release the first submission. Its own acceptance adopts the title.
        HudChatsURLProtocol.releaseStart()
        try await wait { first.thread != nil }
        let firstRoot = try #require(first.thread?.rootRunID)
        HudChatsURLProtocol.finish(firstRoot)
        await firstTask.value
        let secondRoot = try #require(second.thread?.rootRunID)
        HudChatsURLProtocol.finish(secondRoot)
        await secondTask.value
        #expect(fixture.chats.chats.first { $0.id == firstChat.id }?.displayTitle == "Alpha Pending Title")

        // Relaunch and reopen both from saved history: the first keeps its
        // title, and the second never inherits it.
        try await fixture.chats.dismiss(firstChat.id, model: fixture.model)
        try await fixture.chats.dismiss(secondChat.id, model: fixture.model)
        let relaunched = HerdrHudChats(legacySession: fixture.prototype, defaults: fixture.defaults)
        await relaunched.restore(model: fixture.model)
        let firstSummary = HudChatSummary(
            id: firstRoot,
            title: prefix + "alpha detail",
            updatedAt: "2026-09-01T12:00:00Z",
            latestRunId: firstRoot,
            turnCount: 1,
            status: .completed,
            cwd: nil,
            sessionId: nil,
            promotedPaneId: nil
        )
        let secondSummary = HudChatSummary(
            id: secondRoot,
            title: "Second summary title",
            updatedAt: "2026-09-01T12:00:00Z",
            latestRunId: secondRoot,
            turnCount: 1,
            status: .completed,
            cwd: nil,
            sessionId: nil,
            promotedPaneId: nil
        )
        let reopenedFirstID = try await relaunched.openHistory(firstSummary, machineID: "synthetic", model: fixture.model)
        let reopenedSecondID = try await relaunched.openHistory(secondSummary, machineID: "synthetic", model: fixture.model)
        #expect(relaunched.chats.first { $0.id == reopenedFirstID }?.displayTitle == "Alpha Pending Title")
        #expect(relaunched.chats.first { $0.id == reopenedSecondID }?.displayTitle == "Second summary title")
    }

    private func seedPendingChat(
        _ fixture: Fixture,
        machineID: String = "synthetic",
        prompt: String
    ) throws -> (chat: HerdrHudChats.Chat, session: HerdrHudSession) {
        let session = fixture.chats.composer
        session.selectedMachineID = machineID
        session.seedExchangesForTesting([
            HerdrHudExchange(
                id: "hud-pending-\(UUID().uuidString)",
                machineID: machineID,
                prompt: prompt,
                sentPrompt: prompt,
                response: nil,
                error: nil,
                status: .running,
                costUSD: nil,
                createdAt: .now,
                promotedPaneID: nil,
                attachmentFilenames: []
            )
        ])
        fixture.chats.submissionStarted(session)
        let chat = try #require(fixture.chats.chats.first { $0.session === session })
        return (chat, session)
    }

    @Test("Ending during submission waits for its accepted identity before stopping it")
    func endDuringSubmission() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.draft = "Plan a reading nook"
        var endTask: Task<Bool, Error>?
        await session.submit(model: fixture.model) {
            fixture.chats.submissionStarted(session)
            let id = fixture.chats.visibleChats.first!.id
            endTask = Task { try await fixture.chats.end(id, model: fixture.model) }
        }
        _ = try await #require(endTask).value
        #expect(session.hasEnded)
        #expect(session.exchanges.last?.status == .cancelled)
        #expect(fixture.chats.visibleChats.isEmpty)
        #expect(HudChatsURLProtocol.state.withLock { $0.starts.count } == 1)
    }

    @Test("Mini HUDs render running and ready states beside ordinary workspace agents")
    func renderIndependentChats() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(false, forKey: "herdr.hud.enabled")
        let controller = HerdrHudController(userDefaults: fixture.defaults)
        let notes = HerdrHudNotesState(userDefaults: fixture.defaults,
                                      agentSettings: AgentModelSettingsStore(defaults: fixture.defaults),
                                      promptSettings: HerdrPromptSettingsStore(defaults: fixture.defaults),
                                      persistenceURL: fixture.directory.appendingPathComponent("notes.json"))
        controller.configure(model: fixture.model, session: fixture.prototype, notes: notes, fontScale: HerdrFontScaleStore())
        let chats = try #require(controller.chats)
        let first = chats.composer
        first.draft = "Plan a small courtyard garden with native plants"
        let firstTask = Task { await controller.submitChat(first, model: fixture.model) }
        try await wait { first.thread != nil }
        let second = chats.composer
        second.draft = "Compare portable telescopes for a weekend camping trip"
        let secondTask = Task { await controller.submitChat(second, model: fixture.model) }
        try await wait { second.thread != nil }
        HudChatsURLProtocol.finish(try #require(second.thread?.lastRunID))
        await secondTask.value
        let chips = [HerdrHudSessionChips.Chip(id: "synthetic|w1:p1", title: "Main project agent", status: .working,
                                             isMuted: false, since: .now, emoji: "", activity: "Running tests")]
        let stack = try await HerdrRenderHarness.render("hud-independent-chats.png", size: CGSize(width: 310, height: 420)) {
            HerdrHudSessionChipsView(model: fixture.model, session: fixture.prototype, chips: chips,
                                     overflow: 0, chatController: controller)
                .padding(20)
                .preferredColorScheme(.dark)
        }
        stack.expectSubstantial()
        let selected = try #require(chats.visibleChats.first { $0.session === second })
        chats.select(selected.id)
        let card = try await HerdrRenderHarness.render("hud-independent-chat-expanded.png", size: CGSize(width: 430, height: 600)) {
            HerdrHudCardView(model: fixture.model, controller: controller, session: second)
                .preferredColorScheme(.dark)
        }
        card.expectSubstantial()
        controller.resizeChat(to: CGSize(width: 640, height: 680))
        let larger = try await HerdrRenderHarness.render("hud-chat-resized.png",
            size: CGSize(width: controller.chatCardSize.width + 20, height: controller.chatCardSize.height + 20)) {
            HerdrHudCardView(model: fixture.model, controller: controller, session: second)
                .preferredColorScheme(.dark)
        }
        larger.expectSubstantial()
        await first.stop(model: fixture.model)
        await firstTask.value
        controller.setEnabled(false)
    }

    @Test("Independent sessions retain attachments in different directories")
    func attachmentIsolation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let source = fixture.directory.appendingPathComponent("example.txt")
        try Data("Synthetic attachment".utf8).write(to: source)
        let first = fixture.prototype.makeIndependentSession(id: UUID().uuidString)
        let second = fixture.prototype.makeIndependentSession(id: UUID().uuidString)
        first.addAttachments([source])
        second.addAttachments([source])
        let firstFile = try #require(first.pendingAttachments.first)
        let secondFile = try #require(second.pendingAttachments.first)
        #expect(firstFile.url != secondFile.url)
        first.removeAttachment(firstFile.id)
        #expect(!FileManager.default.fileExists(atPath: firstFile.url.path))
        #expect(FileManager.default.fileExists(atPath: secondFile.url.path))
    }

    @Test("HUD chat bubble metadata tracks live cost and the run's resolved model")
    func bubbleMetadataTracksLiveCostAndModel() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        let selected = PiAvailableModel(
            provider: "synthetic",
            modelID: "claude-sonnet-4-5",
            name: nil,
            reasoning: true,
            contextWindow: nil
        )
        session.seedModelsForTesting([selected], default: nil, machineID: "synthetic")
        session.setSelectedModel(selected)
        session.draft = "Track metadata"

        let task = Task { await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) } }
        try await wait { session.thread != nil }
        let runID = try #require(session.thread?.lastRunID)
        // The submission capture is the fallback until the server reports a run model.
        #expect(session.bubbleMetadata.cost == "$0.00")
        #expect(session.bubbleMetadata.modelName == "Claude Sonnet 4.5")

        // A composer change after submission never rewrites captured metadata.
        session.setSelectedModel(nil)
        #expect(session.bubbleMetadata.modelName == "Claude Sonnet 4.5")

        HudChatsURLProtocol.setCost(runID, 0.42)
        HudChatsURLProtocol.setModel(runID, "synthetic/claude-opus-4-5")
        try await wait { session.bubbleMetadata.cost == "$0.42" }
        #expect(session.bubbleMetadata.modelName == "Claude Opus 4.5")

        HudChatsURLProtocol.finish(runID)
        await task.value
        #expect(session.bubbleMetadata.cost == "$0.42")
        #expect(session.bubbleMetadata.modelName == "Claude Opus 4.5")
    }

    @Test("A machine switch never captures another machine's default model as run metadata")
    func machineSwitchDoesNotCaptureAnotherMachinesDefaultModel() async throws {
        let fixture = try Fixture(
            machines: [
                HerdrMachine(id: "machine-a", name: "Alpha", urlString: "https://alpha.example.invalid"),
                HerdrMachine(id: "machine-b", name: "Beta", urlString: "https://beta.example.invalid"),
            ],
            catalogByHost: [
                "alpha.example.invalid": #"{"ok":true,"models":[],"default":{"provider":"synthetic","id":"alpha-default","name":"Alpha Default"}}"#,
                "beta.example.invalid": #"{"ok":true,"models":[],"default":{"provider":"synthetic","id":"beta-default","name":"Beta Default"}}"#,
            ]
        )
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.selectedMachineID = "machine-a"
        await session.loadModels(model: fixture.model)
        #expect(session.defaultModel?.displayName == "Alpha Default")

        // Switching machines drops the previous catalog, so the fresh
        // submission must read Beta's own declared default instead of
        // capturing Alpha's.
        session.selectedMachineID = "machine-b"
        session.draft = "Run on Beta"
        let task = Task { await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) } }
        try await wait { session.thread != nil }
        let runID = try #require(session.thread?.lastRunID)
        let start = try #require(HudChatsURLProtocol.state.withLock { $0.starts.last })
        #expect(start.model == "synthetic/beta-default")
        #expect(session.exchanges.last?.machineID == "machine-b")
        #expect(session.exchanges.last?.modelLabel == "Beta Default")
        #expect(session.bubbleMetadata.modelName == "Beta Default")

        // A history refresh without an authoritative run model keeps the
        // pinned Beta identity rather than promoting Alpha's default.
        HudChatsURLProtocol.finish(runID)
        await task.value
        HudChatsURLProtocol.setMissingCost(runID, true)
        #expect(await session.refreshSavedHistoryPassivelyForTesting(model: fixture.model))
        #expect(session.bubbleMetadata.modelName == "Beta Default")
        #expect(session.exchanges.last?.modelLabel == "Beta Default")

        // A newer authoritative run report replaces the pinned label.
        HudChatsURLProtocol.setMissingCost(runID, false)
        HudChatsURLProtocol.setModel(runID, "synthetic/beta-model")
        #expect(await session.refreshSavedHistoryPassivelyForTesting(model: fixture.model))
        #expect(session.bubbleMetadata.modelName == "Beta Model")
        #expect(session.bubbleMetadata.modelName != session.defaultModel?.displayName)
    }

    @Test("A fresh submission pins the catalog default in the request and in metadata")
    func freshSubmissionPinsCatalogDefault() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.selectedMachineID = "synthetic"
        await session.loadModels(model: fixture.model)
        #expect(session.defaultModel?.displayName == "Synthetic Naming")

        // A new HUD chat pins the execution companion's exact declared default
        // rather than omitting `model` and letting a project default win.
        session.draft = "Use the project default"
        let task = Task { await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) } }
        try await wait { session.thread != nil }
        let runID = try #require(session.thread?.lastRunID)
        let start = try #require(HudChatsURLProtocol.state.withLock { $0.starts.last })
        #expect(start.model == "synthetic/naming")
        #expect(session.exchanges.last?.modelLabel == "Synthetic Naming")
        #expect(session.exchanges.last?.modelLabelIsProven == true)
        #expect(session.bubbleMetadata.modelName == "Synthetic Naming")

        // The pinned identity survives persistence and a history refresh.
        HudChatsURLProtocol.finish(runID)
        await task.value
        try await wait {
            guard let snapshot = HerdrHudPersistenceSnapshot.load(from: session.persistenceURLForTesting),
                  let metadata = snapshot.chatMetadata else {
                return false
            }
            return metadata.latestRunID == runID && metadata.latestRunModelName == "Synthetic Naming"
        }
        #expect(await session.refreshSavedHistoryPassivelyForTesting(model: fixture.model))
        #expect(session.bubbleMetadata.modelName == "Synthetic Naming")

        // A transcript row that holds an unproven catalog guess must not feed
        // a history reconcile; only the run report or the request itself can.
        var localGuess = try #require(session.exchanges.last)
        localGuess.modelLabel = "Catalog Guess"
        localGuess.modelLabelIsProven = false
        session.seedExchangesForTesting([localGuess])
        #expect(await session.refreshSavedHistory(model: fixture.model))
        #expect(session.bubbleMetadata.modelName == nil)
        #expect(session.exchanges.last?.modelLabel == "default")
        #expect(session.exchanges.last?.modelLabelIsProven == false)

        // A run report naming the project's actual model is authoritative.
        HudChatsURLProtocol.setModel(runID, "synthetic/project-model")
        #expect(await session.refreshSavedHistoryPassivelyForTesting(model: fixture.model))
        #expect(session.bubbleMetadata.modelName == "Project Model")
        #expect(session.bubbleMetadata.modelName != session.defaultModel?.displayName)
    }

    @Test("HUD chat bubble metadata sums distinct accepted turns across a continuation")
    func bubbleMetadataSumsContinuations() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.draft = "First turn"
        let first = Task { await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) } }
        try await wait { session.thread != nil }
        let root = try #require(session.thread?.lastRunID)
        HudChatsURLProtocol.setCost(root, 0.42)
        HudChatsURLProtocol.finish(root)
        await first.value
        #expect(session.bubbleMetadata.cost == "$0.42")

        session.draft = "Second turn"
        let second = Task { await session.submit(model: fixture.model) }
        try await wait { session.thread?.turnCount == 2 }
        let continuation = try #require(session.thread?.lastRunID)
        #expect(continuation != root)
        HudChatsURLProtocol.setCost(continuation, 1.00)
        HudChatsURLProtocol.finish(continuation)
        await second.value
        #expect(session.bubbleMetadata.cost == "$1.42")
        #expect(session.chatMetadata.observedRunCount == 2)
    }

    @Test("HUD chat bubble metadata counts a retried accepted turn once per run")
    func bubbleMetadataCountsRetryRunsDistinctly() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.draft = "Failing turn"
        let first = Task { await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) } }
        try await wait { session.thread != nil }
        let root = try #require(session.thread?.lastRunID)
        HudChatsURLProtocol.setCost(root, 0.10)
        HudChatsURLProtocol.fail(root)
        await first.value
        #expect(session.bubbleMetadata.cost == "$0.10")
        let failed = try #require(session.exchanges.last)

        let retry = Task { await session.retry(failed, model: fixture.model) }
        try await wait { session.thread?.lastRunID != root }
        let retried = try #require(session.thread?.lastRunID)
        HudChatsURLProtocol.setCost(retried, 0.20)
        HudChatsURLProtocol.finish(retried)
        await retry.value
        #expect(session.bubbleMetadata.cost == "$0.30")
        #expect(session.chatMetadata.observedRunCount == 2)
    }

    @Test("HUD chat bubble metadata includes a cancelled turn's reported cost")
    func bubbleMetadataIncludesCancelledCost() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.draft = "Cancel this"
        let task = Task { await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) } }
        try await wait { session.thread != nil }
        let runID = try #require(session.thread?.lastRunID)
        HudChatsURLProtocol.setCost(runID, 0.05)
        try await wait { session.bubbleMetadata.cost == "$0.05" }

        await session.stop(model: fixture.model)
        await task.value
        #expect(session.exchanges.last?.status == .cancelled)
        #expect(session.bubbleMetadata.cost == "$0.05")
    }

    @Test("A collapsed HUD chat receives a cost reported after cancellation")
    func cancelledCostAfterStopReachesCollapsedBubble() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        // The server marks cancellation terminal before stdout (and its cost)
        // finishes draining, so the accepted and cancelled reports omit it.
        HudChatsURLProtocol.setMissingCostForNewRuns(true)
        session.draft = "Cancel while stdout drains"
        let task = Task { await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) } }
        try await wait { session.thread != nil }
        let runID = try #require(session.thread?.lastRunID)
        await session.stop(model: fixture.model)
        await task.value
        #expect(session.exchanges.last?.status == .cancelled)
        #expect(session.isCollapsed)
        #expect(!session.isRunning)
        #expect(session.bubbleMetadata.cost == nil)

        // The late report arrives only after the card is already collapsed,
        // and no caller refreshes history for it.
        HudChatsURLProtocol.setMissingCostForNewRuns(false)
        HudChatsURLProtocol.setMissingCost(runID, false)
        HudChatsURLProtocol.setCost(runID, 0.04)
        try await wait { session.bubbleMetadata.cost == "$0.04" }

        // The drain can revise that first post-cancel number again.
        HudChatsURLProtocol.setCost(runID, 0.11)
        try await wait { session.bubbleMetadata.cost == "$0.11" }
        try await wait {
            HerdrHudPersistenceSnapshot.load(from: session.persistenceURLForTesting)?
                .chatMetadata?.totalCostUSD == 0.11
        }
    }

    @Test("Repeated equal cancellation costs do not end reconciliation before a revision")
    func repeatedEqualCancellationCostsKeepReconciling() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        // The server marks cancellation terminal before stdout (and its cost)
        // finishes draining, so the accepted and cancelled reports omit it.
        HudChatsURLProtocol.setMissingCostForNewRuns(true)
        session.draft = "Cancel while stdout drains in stages"
        let task = Task { await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) } }
        try await wait { session.thread != nil }
        let runID = try #require(session.thread?.lastRunID)
        await session.stop(model: fixture.model)
        await task.value
        #expect(session.exchanges.last?.status == .cancelled)
        #expect(session.isCollapsed)
        #expect(!session.isRunning)
        #expect(session.bubbleMetadata.cost == nil)

        // Let any in-flight controller poll finish before the fetch count is
        // reset, so the count below attributes only reconciliation requests.
        try await Task.sleep(for: .milliseconds(100))

        // The drain reports two identical numeric totals before correcting
        // itself to $0.11. Two equal samples must not end the window for a
        // cancelled run, because a collapsed bubble has no other refresher to
        // recover the revision.
        HudChatsURLProtocol.setCostScript(runID, [0.05, 0.05, 0.11])
        try await wait(iterations: 500) { session.bubbleMetadata.cost == "$0.11" }
        try await wait {
            HerdrHudPersistenceSnapshot.load(from: session.persistenceURLForTesting)?
                .chatMetadata?.totalCostUSD == 0.11
        }
        #expect(session.bubbleMetadata.cost == "$0.11")

        // The correction proves continued reconciliation, not a new poller:
        // the fixed window of six attempts finishes and then stops requesting
        // this run.
        await session.awaitTerminalMetadataReconciliationForTesting()
        let requests = HudChatsURLProtocol.runRequestCount(runID)
        #expect(requests >= 4)
        #expect(requests <= 6)
        try await Task.sleep(for: .milliseconds(800))
        #expect(HudChatsURLProtocol.runRequestCount(runID) == requests)
    }

    @Test("Reopened HUD history rebuilds cumulative metadata across pages")
    func historyReopenBuildsCumulativeMetadataAcrossPages() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let root = "agr_paginationroot"
        for index in 0..<51 {
            let id = HudChatsURLProtocol.appendExternal(root: root, prompt: "Turn \(index)")
            HudChatsURLProtocol.setCost(id, 0.01)
        }

        let chatID = try await fixture.chats.openHistory(id: root, machineID: "synthetic", model: fixture.model)
        let chat = try #require(fixture.chats.chats.first { $0.id == chatID })
        #expect(chat.session.exchanges.count == 51)
        #expect(chat.session.chatMetadata.observedRunCount == 51)
        #expect(chat.session.bubbleMetadata.cost == "$0.51")
    }

    @Test("A passive history refresh notices changed cost and model metadata")
    func passiveRefreshReconcilesMetadataChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.draft = "Watch metadata"
        let task = Task { await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) } }
        try await wait { session.thread != nil }
        let root = try #require(session.thread?.lastRunID)
        HudChatsURLProtocol.setCost(root, 0.42)
        HudChatsURLProtocol.finish(root)
        await task.value
        #expect(session.bubbleMetadata.cost == "$0.42")
        // A fresh submission pins the catalog default, so metadata starts with
        // that proven identity rather than unknown.
        #expect(session.bubbleMetadata.modelName == "Synthetic Naming")

        HudChatsURLProtocol.setCost(root, 0.99)
        #expect(await session.refreshSavedHistoryPassivelyForTesting(model: fixture.model))
        #expect(session.bubbleMetadata.cost == "$0.99")

        HudChatsURLProtocol.setModel(root, "synthetic/claude-sonnet-4-5")
        #expect(await session.refreshSavedHistoryPassivelyForTesting(model: fixture.model))
        #expect(session.bubbleMetadata.modelName == "Claude Sonnet 4.5")
    }

    @Test("A passive refresh reconciles metadata for a latest run on a later page")
    func passiveRefreshReconcilesPaginatedLatestMetadata() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let root = "agr_paginationmetadata"
        for index in 0..<51 {
            let id = HudChatsURLProtocol.appendExternal(root: root, prompt: "Turn \(index)")
            HudChatsURLProtocol.setCost(id, 0.01)
        }

        let chatID = try await fixture.chats.openHistory(id: root, machineID: "synthetic", model: fixture.model)
        let chat = try #require(fixture.chats.chats.first { $0.id == chatID })
        #expect(chat.session.bubbleMetadata.cost == "$0.51")

        // Page one holds fifty turns, so the latest sample is only visible on
        // the second page. Its late report must still reach the aggregate.
        let latest = try #require(chat.session.thread?.lastRunID)
        HudChatsURLProtocol.setCost(latest, 0.99)
        HudChatsURLProtocol.setModel(latest, "synthetic/claude-opus-4-5")
        #expect(await chat.session.refreshSavedHistoryPassivelyForTesting(model: fixture.model))

        #expect(chat.session.bubbleMetadata.cost == "$1.49")
        #expect(chat.session.bubbleMetadata.modelName == "Claude Opus 4.5")
    }

    @Test("A passive refresh recovers a previously missing historical cost")
    func passiveRefreshRecoversMissingHistoricalCost() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let root = "agr_missinghistory"
        let first = HudChatsURLProtocol.appendExternal(root: root, prompt: "First turn")
        HudChatsURLProtocol.setMissingCost(first, true)
        let second = HudChatsURLProtocol.appendExternal(root: root, prompt: "Second turn")
        HudChatsURLProtocol.setCost(second, 0.25)

        let chatID = try await fixture.chats.openHistory(id: root, machineID: "synthetic", model: fixture.model)
        let chat = try #require(fixture.chats.chats.first { $0.id == chatID })
        #expect(chat.session.chatMetadata.hasEstablishedCoverage)
        #expect(!chat.session.chatMetadata.isComplete)
        #expect(chat.session.bubbleMetadata.cost == nil)

        // The latest sample stays unchanged; the earlier turn's cost is what
        // finally arrives, so the fast path must not skip reconciliation.
        HudChatsURLProtocol.setMissingCost(first, false)
        HudChatsURLProtocol.setCost(first, 0.15)
        #expect(await chat.session.refreshSavedHistoryPassivelyForTesting(model: fixture.model))

        #expect(chat.session.bubbleMetadata.cost == "$0.40")
    }

    @Test("A passive refresh reconciles a revised earlier cost while the latest run is unchanged")
    func passiveRefreshReconcilesRevisedEarlierCost() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let root = "agr_earliercost"
        let first = HudChatsURLProtocol.appendExternal(root: root, prompt: "First turn")
        HudChatsURLProtocol.setCost(first, 0.10)
        let second = HudChatsURLProtocol.appendExternal(root: root, prompt: "Second turn")
        HudChatsURLProtocol.setCost(second, 0.25)

        let chatID = try await fixture.chats.openHistory(id: root, machineID: "synthetic", model: fixture.model)
        let chat = try #require(fixture.chats.chats.first { $0.id == chatID })
        #expect(chat.session.bubbleMetadata.cost == "$0.35")

        // A cancelled run's reported cost can arrive after it was already
        // marked terminal. The latest run stays untouched, so only comparing
        // the earlier turn can prove the aggregate is still current.
        HudChatsURLProtocol.setCost(first, 0.15)
        #expect(await chat.session.refreshSavedHistoryPassivelyForTesting(model: fixture.model))

        #expect(chat.session.bubbleMetadata.cost == "$0.40")
    }

    @Test("Observing a restored running turn keeps the bubble metadata live")
    func restoredRunningTurnKeepsMetadataLive() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let root = "agr_runningroot"
        let finished = HudChatsURLProtocol.appendExternal(root: root, prompt: "Finished turn")
        HudChatsURLProtocol.setCost(finished, 0.25)
        let running = HudChatsURLProtocol.appendExternal(root: root, prompt: "Running turn")
        HudChatsURLProtocol.state.withLock { $0.statuses[running] = "running" }
        HudChatsURLProtocol.setCost(running, 0.10)

        let chatID = try await fixture.chats.openHistory(id: root, machineID: "synthetic", model: fixture.model)
        let chat = try #require(fixture.chats.chats.first { $0.id == chatID })
        #expect(chat.session.bubbleMetadata.cost == "$0.35")

        HudChatsURLProtocol.setCost(running, 0.30)
        try await wait { chat.session.bubbleMetadata.cost == "$0.55" }
        HudChatsURLProtocol.finish(running)
        try await wait { chat.session.exchanges.last?.status == .completed }
        #expect(chat.session.bubbleMetadata.cost == "$0.55")
    }

    private func wait(iterations: Int = 300, _ condition: () -> Bool) async throws {
        for _ in 0..<iterations {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw WaitError.timedOut
    }

    private enum WaitError: Error { case timedOut }

    @MainActor
    private struct Fixture {
        let suite = "hud-chats-tests-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults: UserDefaults
        let model: HerdrAppModel
        let prototype: HerdrHudSession
        let chats: HerdrHudChats

        init(
            machines: [HerdrMachine]? = nil,
            catalogByHost: [String: String] = [:]
        ) throws {
            HudChatsURLProtocol.state.withLock {
                $0 = .init()
                $0.idPrefix = String(UUID().uuidString.prefix(8)).lowercased()
                $0.catalogByHost = catalogByHost
            }
            defaults = try #require(UserDefaults(suiteName: suite))
            let roster = machines ?? [
                HerdrMachine(id: "synthetic", name: "Example Mac", urlString: "https://hud.example.invalid")
            ]
            // Explicit local identity: the roster host is this Mac, so a fresh
            // composer selects it without relying on roster order or names.
            prototype = HerdrHudSession(
                userDefaults: defaults,
                persistenceURL: directory.appendingPathComponent("hud-thread.json"),
                hostIdentity: HerdrHudHostIdentity(hostNames: roster.compactMap {
                    URLComponents(string: $0.urlString)?.host
                }, addresses: [])
            )
            chats = HerdrHudChats(legacySession: prototype, defaults: defaults)
            let urlSessionConfiguration = URLSessionConfiguration.ephemeral
            urlSessionConfiguration.protocolClasses = [HudChatsURLProtocol.self]
            let urlSession = URLSession(configuration: urlSessionConfiguration)
            model = HerdrAppModel(credentials: TestCredentialStore(), arguments: [], userDefaults: defaults)
            model.machines = roster
            model.clientFactory = { configuration in
                HerdrAPIClient(configuration: configuration, session: urlSession)
            }
            for machine in roster {
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

private struct HudChatsFixtureError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The protocol adds no mutable instance state; synthetic server state is locked.
private final class HudChatsURLProtocol: URLProtocol, @unchecked Sendable {
    struct Start: Sendable {
        let id: String
        let root: String
        let parent: String?
        let prompt: String
        let cwd: String?
        let profile: String
        /// The `model` field exactly as the client sent it, so a test can prove
        /// an implicit submission omitted it.
        let model: String?
    }
    struct State: Sendable {
        var starts: [Start] = []
        /// Makes generated run identifiers unique to one fixture. A lingering
        /// task from an earlier test uses its own prefix, so it cannot match a
        /// run here, consume a scripted sample, or inflate a request count.
        var idPrefix = ""
        var statuses: [String: String] = [:]
        var runCosts: [String: Double] = [:]
        var missingCostIDs: Set<String> = []
        /// Newly accepted runs report no cost at all, matching a cancelled run
        /// whose stdout (and its cost) has not finished draining.
        var missingCostForNewRuns = false
        /// When present, each individual run fetch consumes one scripted value,
        /// so a test can deterministically model an in-flight drain that starts
        /// absent, repeats a numeric total, and is then revised.
        var runCostScripts: [String: [Double?]] = [:]
        /// How many individual run fetches each run has received, so a test can
        /// prove the bounded reconciliation window stays bounded.
        var runRequestCounts: [String: Int] = [:]
        var runModels: [String: String] = [:]
        var deleteCount = 0
        var cancellationCount = 0
        var rejectNextCancellation = false
        var rejectNextStart = false
        var conflictNextStart = false
        var hudChatWorkingDirectory = true
        var capabilityRequestCount = 0
        var historyRequestCount = 0
        var delayNextCapabilities = false
        var delayNextHistory = false
        var delayNextStart = false
        var catalogByHost: [String: String] = [:]
        var catalogHosts: [String] = []
        let capabilitiesGate = DispatchSemaphore(value: 0)
        let historyGate = DispatchSemaphore(value: 0)
        let startGate = DispatchSemaphore(value: 0)
    }
    static let fallbackCatalog = #"{"ok":true,"models":[{"provider":"synthetic","id":"naming","name":"Synthetic Naming","reasoning":true,"context_window":64000}],"default":{"provider":"synthetic","id":"naming","name":"Synthetic Naming"}}"#
    static let state = Mutex(State())
    static func finish(_ id: String) { state.withLock { $0.statuses[id] = "completed" } }
    static func fail(_ id: String) { state.withLock { $0.statuses[id] = "failed" } }
    static func releaseCapabilities() {
        state.withLock { state in
            state.delayNextCapabilities = false
            state.capabilitiesGate.signal()
        }
    }
    static func releaseHistory() {
        state.withLock { state in
            state.delayNextHistory = false
            state.historyGate.signal()
        }
    }
    static func releaseStart() {
        state.withLock { state in
            state.delayNextStart = false
            state.startGate.signal()
        }
    }
    static func catalogHosts() -> [String] { state.withLock { $0.catalogHosts } }
    static func setCost(_ id: String, _ cost: Double?) {
        state.withLock { state in
            if let cost { state.runCosts[id] = cost } else { state.runCosts[id] = nil }
        }
    }
    static func setMissingCost(_ id: String, _ missing: Bool) {
        state.withLock { state in
            if missing { state.missingCostIDs.insert(id) } else { state.missingCostIDs.remove(id) }
        }
    }
    static func setMissingCostForNewRuns(_ missing: Bool) {
        state.withLock { $0.missingCostForNewRuns = missing }
    }
    /// Installs a per-fetch cost script and restarts the run's fetch count, so
    /// a test can attribute and bound every request made after this point.
    static func setCostScript(_ id: String, _ costs: [Double?]) {
        state.withLock { state in
            state.runCostScripts[id] = costs
            state.runRequestCounts[id] = 0
        }
    }
    static func runRequestCount(_ id: String) -> Int {
        state.withLock { $0.runRequestCounts[id] ?? 0 }
    }
    static func setModel(_ id: String, _ model: String?) {
        state.withLock { state in
            if let model { state.runModels[id] = model } else { state.runModels[id] = nil }
        }
    }
    @discardableResult
    static func appendExternal(root: String, prompt: String, cwd: String? = nil) -> String {
        state.withLock { state in
            let id = "agr_\(state.idPrefix)\(String(format: "%012d", state.starts.count + 1))"
            let parent = state.starts.last(where: { $0.root == root })?.id
            state.starts.append(Start(id: id, root: root, parent: parent, prompt: prompt,
                                      cwd: cwd, profile: "hud-chat-v1", model: nil))
            state.statuses[id] = "completed"
            return id
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        let body = requestBody()
        let gate = Self.state.withLock { state -> DispatchSemaphore? in
            let path = url.path
            if path.hasSuffix("/capabilities") {
                state.capabilityRequestCount += 1
                if state.delayNextCapabilities {
                    state.delayNextCapabilities = false
                    return state.capabilitiesGate
                }
            }
            if path.contains("/hud-chats/"), request.httpMethod == "GET" {
                state.historyRequestCount += 1
                if state.delayNextHistory {
                    state.delayNextHistory = false
                    return state.historyGate
                }
            }
            if path == "/api/v1/agent-runs", request.httpMethod == "POST", state.delayNextStart {
                state.delayNextStart = false
                return state.startGate
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
            if path == "/api/v1/agent-runs/models" {
                state.catalogHosts.append(url.host ?? "")
                let body = state.catalogByHost[url.host ?? ""] ?? Self.fallbackCatalog
                return (200, Data(body.utf8))
            }
            if path.hasSuffix("/cancel") {
                state.cancellationCount += 1
                if state.rejectNextCancellation {
                    state.rejectNextCancellation = false
                    return (503, Data(#"{"ok":false,"error":{"message":"Synthetic stop failure"}}"#.utf8))
                }
            }
            if path == "/api/v1/agent-runs", request.httpMethod == "POST", state.rejectNextStart {
                state.rejectNextStart = false
                return (429, Data(#"{"ok":false,"error":{"message":"Synthetic capacity limit"}}"#.utf8))
            }
            if path == "/api/v1/agent-runs", request.httpMethod == "POST", state.conflictNextStart {
                state.conflictNextStart = false
                let input = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
                let parent = input["continueFromRunId"] as? String
                let root = state.starts.first(where: { $0.id == parent })?.root ?? parent ?? "agr_000000000001"
                let id = "agr_\(state.idPrefix)\(String(format: "%012d", state.starts.count + 1))"
                state.starts.append(Start(id: id, root: root, parent: parent,
                                          prompt: "Conflicting device reply", cwd: input["cwd"] as? String,
                                          profile: "hud-chat-v1", model: input["model"] as? String))
                state.statuses[id] = "completed"
                return (409, Data(#"{"ok":false,"error":{"message":"This chat has a newer reply."}}"#.utf8))
            }
            var response: [String: Any] = ["ok": true]
            if request.httpMethod == "DELETE" { state.deleteCount += 1 }
            if path.hasSuffix("/capabilities") {
                response["profiles"] = ["hud-chat-v1"]
                response["hudChatWorkingDirectory"] = state.hudChatWorkingDirectory
            } else if path == "/api/v1/agent-runs", request.httpMethod == "POST" {
                let input = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
                let id = "agr_\(state.idPrefix)\(String(format: "%012d", state.starts.count + 1))"
                let prior = input["continueFromRunId"] as? String
                let root = state.starts.first { $0.id == prior }?.root ?? id
                let start = Start(id: id, root: root, parent: prior,
                                  prompt: input["prompt"] as? String ?? "",
                                  cwd: input["cwd"] as? String, profile: input["profile"] as? String ?? "",
                                  model: input["model"] as? String)
                state.starts.append(start)
                state.statuses[id] = "running"
                if state.missingCostForNewRuns { state.missingCostIDs.insert(id) }
                response["run"] = Self.run(start, state: state)
            } else if path.contains("/hud-chats/"), request.httpMethod == "GET" {
                let root = url.lastPathComponent
                let turns = state.starts.filter { $0.root == root }
                let offset = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "offset" })?.value.flatMap(Int.init) ?? 0
                response["turns"] = turns.dropFirst(offset).prefix(50).map { Self.run($0, state: state) }
                response["rootRunId"] = root
                response["latestRunId"] = turns.last?.id ?? root
                if offset + 50 < turns.count { response["nextOffset"] = offset + 50 }
            } else if path.contains("/agent-runs/") {
                let id = path.hasSuffix("/cancel") ? url.deletingLastPathComponent().lastPathComponent : url.lastPathComponent
                if path.hasSuffix("/cancel") {
                    state.statuses[id] = "cancelled"
                }
                if let start = state.starts.first(where: { $0.id == id }) {
                    if request.httpMethod == "GET", !path.hasSuffix("/cancel") {
                        state.runRequestCounts[id, default: 0] += 1
                        // Consume one scripted sample per fetch: nil models a
                        // report whose cost has not drained yet, and the
                        // scripted amount stands in for the server's current
                        // total.
                        if var script = state.runCostScripts[id], !script.isEmpty {
                            let next = script.removeFirst()
                            state.runCostScripts[id] = script
                            state.runCosts[id] = next
                            if next == nil {
                                state.missingCostIDs.insert(id)
                            } else {
                                state.missingCostIDs.remove(id)
                            }
                        }
                    }
                    response["run"] = Self.run(start, state: state)
                }
            }
            return (200, (try? JSONSerialization.data(withJSONObject: response)) ?? Data())
        }
        guard let response = HTTPURLResponse(url: url, statusCode: payload.0, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload.1)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func run(_ start: Start, state: State) -> [String: Any] {
        var run: [String: Any] = ["id": start.id, "status": state.statuses[start.id] ?? "running",
                                  "prompt": start.prompt, "createdAt": "2026-09-01T12:00:00Z",
                                  "threadRootRunId": start.root, "sessionFile": "synthetic.jsonl"]
        if !state.missingCostIDs.contains(start.id) {
            run["costUSD"] = state.runCosts[start.id] ?? 0
        }
        if let model = state.runModels[start.id] { run["model"] = model }
        if let cwd = start.cwd { run["cwd"] = cwd }
        if state.statuses[start.id] == "completed" { run["response"] = "Answer for \(start.prompt)" }
        return run
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
