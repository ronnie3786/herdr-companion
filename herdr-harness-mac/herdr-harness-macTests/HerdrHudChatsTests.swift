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
        await #expect(throws: HerdrHudChats.SmartRenameError.invalidTitle) {
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

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
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

        init() throws {
            HudChatsURLProtocol.state.withLock { $0 = .init() }
            defaults = try #require(UserDefaults(suiteName: suite))
            prototype = HerdrHudSession(userDefaults: defaults, persistenceURL: directory.appendingPathComponent("hud-thread.json"))
            chats = HerdrHudChats(legacySession: prototype, defaults: defaults)
            let configuration = try #require(ServerConfiguration(urlString: "https://hud.example.invalid", token: "synthetic-token"))
            let urlSession = URLSessionConfiguration.ephemeral
            urlSession.protocolClasses = [HudChatsURLProtocol.self]
            let client = HerdrAPIClient(configuration: configuration, session: URLSession(configuration: urlSession))
            model = HerdrAppModel(credentials: TestCredentialStore(), arguments: [], userDefaults: defaults)
            let machine = HerdrMachine(id: "synthetic", name: "Example Mac", urlString: "https://hud.example.invalid")
            model.machines = [machine]
            model.clientFactory = { _ in client }
            model.prepareRuntime(for: machine, generation: model.connectionGeneration)
            model.machineStates[machine.id] = .live
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

/// The protocol adds no mutable instance state; synthetic server state is locked.
private final class HudChatsURLProtocol: URLProtocol {
    struct Start: Sendable {
        let id: String
        let root: String
        let parent: String?
        let prompt: String
        let cwd: String?
        let profile: String
    }
    struct State: Sendable {
        var starts: [Start] = []
        var statuses: [String: String] = [:]
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
        let capabilitiesGate = DispatchSemaphore(value: 0)
        let historyGate = DispatchSemaphore(value: 0)
    }
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
    @discardableResult
    static func appendExternal(root: String, prompt: String, cwd: String? = nil) -> String {
        state.withLock { state in
            let id = String(format: "agr_%012d", state.starts.count + 1)
            let parent = state.starts.last(where: { $0.root == root })?.id
            state.starts.append(Start(id: id, root: root, parent: parent, prompt: prompt,
                                      cwd: cwd, profile: "hud-chat-v1"))
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
            return nil
        }
        gate?.wait()
        let payload = Self.state.withLock { state -> (Int, Data) in
            let path = url.path
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
                let id = String(format: "agr_%012d", state.starts.count + 1)
                state.starts.append(Start(id: id, root: root, parent: parent,
                                          prompt: "Conflicting device reply", cwd: input["cwd"] as? String,
                                          profile: "hud-chat-v1"))
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
                let id = String(format: "agr_%012d", state.starts.count + 1)
                let prior = input["continueFromRunId"] as? String
                let root = state.starts.first { $0.id == prior }?.root ?? id
                let start = Start(id: id, root: root, parent: prior,
                                  prompt: input["prompt"] as? String ?? "",
                                  cwd: input["cwd"] as? String, profile: input["profile"] as? String ?? "")
                state.starts.append(start)
                state.statuses[id] = "running"
                response["run"] = Self.run(start, state: state)
            } else if path.contains("/hud-chats/"), request.httpMethod == "GET" {
                let root = url.lastPathComponent
                let turns = state.starts.filter { $0.root == root }
                response["turns"] = turns.map { Self.run($0, state: state) }
                response["rootRunId"] = root
                response["latestRunId"] = turns.last?.id ?? root
            } else if path.contains("/agent-runs/") {
                let id = path.hasSuffix("/cancel") ? url.deletingLastPathComponent().lastPathComponent : url.lastPathComponent
                if path.hasSuffix("/cancel") { state.statuses[id] = "cancelled" }
                if let start = state.starts.first(where: { $0.id == id }) { response["run"] = Self.run(start, state: state) }
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
