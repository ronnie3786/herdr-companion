import Foundation
import Observation

/// Owns independent HUD conversations, not terminal panes. Selection only changes
/// the card being displayed; it never transfers a draft, cancels a run, or promotes it.
@MainActor
@Observable
final class HerdrHudChats {
    struct Chat: Identifiable {
        let id: String
        let title: String
        let session: HerdrHudSession

        @MainActor var displayTitle: String {
            title.isEmpty ? HerdrHudChats.title(for: session) : title
        }
    }

    private struct SavedChat: Codable {
        let id: String
        let title: String
    }

    private struct SavedHistoryTitle: Codable {
        let historyIdentity: String
        let title: String
        let updatedAt: Date
    }

    /// A title produced while its chat had no durable history identity yet.
    /// Ownership is the exact chat and the exact accepted submission, so a
    /// different chat or a later turn can never consume it. Only the
    /// submission recorded as the owner of the established root picks the
    /// title up once that root exists.
    private struct PendingHistoryTitle: Codable, Equatable {
        let chatID: String
        let submissionID: String
        let title: String
        let updatedAt: Date
    }

    /// The stable shape of one conversation frontier. Responses, tool steps,
    /// and completion can all change without changing this; a different
    /// prompt, turn, or history root does.
    private struct TurnIdentity: Equatable {
        let id: String
        let machineID: String
        let createdAt: Date
        let prompt: String
        let sentPrompt: String

        var isPendingPlaceholder: Bool { id.hasPrefix("hud-pending-") }
    }

    private struct ConversationSnapshot: Equatable {
        let historyIdentity: String?
        let count: Int
        let lastTurn: TurnIdentity?
    }

    enum SmartRenameError: LocalizedError, Equatable {
        case unavailable
        case busy
        case changed

        var errorDescription: String? {
            switch self {
            case .unavailable: "This HUD chat has no readable context to name yet."
            case .busy: "Smart Rename is already running for this HUD chat."
            case .changed: "The HUD chat changed while Smart Rename was running. Try again."
            }
        }
    }

    private static let defaultsKey = "herdr.hud.standaloneChats.v1"
    private static let historyTitlesDefaultsKey = "herdr.hud.historyTitles.v1"
    private static let pendingHistoryTitlesDefaultsKey = "herdr.hud.pendingHistoryTitles.v1"
    private static let maximumSavedHistoryTitles = 200
    private static let maximumPendingHistoryTitles = 200
    private let defaults: UserDefaults
    private let prototype: HerdrHudSession
    private(set) var chats: [Chat]
    private(set) var composer: HerdrHudSession
    private var composerID: String
    private(set) var selectedID: String?
    private var pendingRestorationIDs: Set<String>
    private var savedHistoryTitles: [SavedHistoryTitle]
    private var pendingHistoryTitles: [PendingHistoryTitle]
    private(set) var smartRenamingChatIDs: Set<String> = []

    var selectedChat: Chat? { chats.first { $0.id == selectedID } }
    var displayedSession: HerdrHudSession { selectedChat?.session ?? composer }
    var visibleChats: [Chat] { chats.filter { !$0.session.exchanges.isEmpty || $0.session.isLoadingHistory } }

    init(legacySession: HerdrHudSession, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        prototype = legacySession
        let saved = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([SavedChat].self, from: $0) }
            ?? [SavedChat(id: "legacy", title: "")]
        savedHistoryTitles = defaults.data(forKey: Self.historyTitlesDefaultsKey)
            .flatMap { try? JSONDecoder().decode([SavedHistoryTitle].self, from: $0) }
            ?? []
        pendingHistoryTitles = defaults.data(forKey: Self.pendingHistoryTitlesDefaultsKey)
            .flatMap { try? JSONDecoder().decode([PendingHistoryTitle].self, from: $0) }
            ?? []
        var seen: Set<String> = []
        chats = saved.compactMap { item in
            guard (item.id == "legacy" || UUID(uuidString: item.id) != nil), seen.insert(item.id).inserted else { return nil }
            return Chat(id: item.id, title: item.title, session: item.id == "legacy"
                        ? legacySession : legacySession.makeIndependentSession(id: item.id))
        }
        pendingRestorationIDs = seen
        let id = UUID().uuidString
        composerID = id
        composer = legacySession.makeIndependentSession(id: id)
        for chat in chats { own(chat.session) }
    }

    /// Called after the submission owns preflight and creates its local row.
    /// Keeping the submitted instance alive here lets its task outlive the card.
    func submissionStarted(_ session: HerdrHudSession) {
        if session === composer {
            chats.insert(Chat(id: composerID, title: Self.title(for: session), session: session), at: 0)
            own(session)
            let machineID = session.selectedMachineID
            composerID = UUID().uuidString
            composer = prototype.makeIndependentSession(id: composerID)
            composer.selectedMachineID = machineID
            composer.resetWorkingFolderForNewChat()
            persistIndex()
        }
        session.isCollapsed = true
        if displayedSession === session { selectedID = nil }
    }

    /// Registers the identity seam once for every session this collection
    /// owns. Overwriting it on re-ownership is deliberate: the collection is
    /// the only consumer.
    private func own(_ session: HerdrHudSession) {
        session.onHistoryIdentityEstablished = { [weak self, weak session] in
            guard let self, let session else { return }
            adoptPendingHistoryTitles(for: session)
        }
    }

    func select(_ id: String?) {
        displayedSession.isCollapsed = true
        selectedID = chats.contains(where: { $0.id == id }) ? id : nil
    }

    /// Runs a separate, bounded naming ask against the chat's own machine and
    /// applies the result title. A missing selection or failed run throws and
    /// keeps the original title; cancellation preserves the title and duplicate
    /// requests are refused.
    @discardableResult
    func smartRename(
        _ id: String,
        model: HerdrAppModel,
        runner: any HerdrNoteAIRunner = HerdrLiveNoteAIRunner()
    ) async throws -> String? {
        guard smartRenamingChatIDs.insert(id).inserted else { throw SmartRenameError.busy }
        defer { smartRenamingChatIDs.remove(id) }
        guard let chat = chats.first(where: { $0.id == id }),
              !chat.session.isEnding, !chat.session.hasEnded,
              !chat.session.isLoadingHistory, !chat.session.needsHistoryRefresh,
              let machineID = chat.session.selectedMachineID,
              model.canControl(machineID: machineID)
        else { throw SmartRenameError.unavailable }

        let context = Self.renameContext(for: chat.session)
        guard SmartPaneTitle.hasReadableText(context) else {
            throw SmartRenameError.unavailable
        }
        let expectedSession = chat.session
        let expectedTitle = chat.title
        let expectedConversation = Self.conversationSnapshot(of: chat.session)
        // Model availability resolves against the machine that will execute
        // the naming ask, never the primary machine's catalog.
        let resolution = try await SmartRenameModelRouting.resolve(
            settings: AgentModelSettings.load(from: defaults),
            executionMachineID: machineID,
            appModel: model
        )
        let response: String
        do {
            response = try await runner.run(
                prompt: SmartPaneTitle.prompt(context: context),
                machineID: machineID,
                mode: .ask,
                model: resolution.modelID,
                thinkingLevel: resolution.thinkingLevel.rawValue,
                systemPrompt: nil,
                profile: HerdrNoteAIProfiles.smartRename,
                deadline: .seconds(60),
                appModel: model,
                onProgress: { _ in }
            )
        } catch {
            throw SmartRenameModelRouting.executionError(error, resolution: resolution)
        }
        try Task.checkCancellation()
        guard let index = chats.firstIndex(where: { $0.id == id }),
              chats[index].session === expectedSession,
              chats[index].title == expectedTitle,
              chats[index].session.selectedMachineID == machineID,
              !chats[index].session.isEnding, !chats[index].session.hasEnded,
              !chats[index].session.isLoadingHistory, !chats[index].session.needsHistoryRefresh
        else { throw SmartRenameError.changed }
        let session = chats[index].session
        // Streaming responses, tool progress, and completion for the captured
        // submission leave this snapshot unchanged. A replaced history root,
        // a different prompt/turn, or a manual title edit does not.
        guard Self.conversationMatches(session: session, snapshot: expectedConversation) else {
            throw SmartRenameError.changed
        }
        guard let title = SmartPaneTitle.parse(response) else {
            throw SmartRenameModelRouting.invalidOutputError(resolution: resolution)
        }

        chats[index] = Chat(id: id, title: title, session: session)
        if let historyIdentity = session.historyIdentity {
            saveHistoryTitle(title, for: historyIdentity)
        } else if let turn = expectedConversation.lastTurn, turn.isPendingPlaceholder {
            // The first turn is still an unaccepted placeholder. Remember the
            // title against this exact chat and submission so only that
            // submission's accepted run can adopt it and a remove/reopen
            // cannot lose it.
            savePendingHistoryTitle(
                PendingHistoryTitle(
                    chatID: id,
                    submissionID: turn.id,
                    title: title,
                    updatedAt: .now
                )
            )
        }
        persistIndex()
        return resolution.notice
    }

    /// Whether the chat's frontier still describes the conversation the naming
    /// ask read. The only ID change accepted for a placeholder is the same
    /// submission becoming its accepted run; anything else is a replacement.
    private static func conversationMatches(
        session: HerdrHudSession,
        snapshot: ConversationSnapshot
    ) -> Bool {
        let exchanges = session.exchanges
        guard exchanges.count == snapshot.count,
              let expectedTurn = snapshot.lastTurn,
              let currentTurn = exchanges.last.map(turnIdentity)
        else { return false }

        if expectedTurn.isPendingPlaceholder {
            guard currentTurn.machineID == expectedTurn.machineID,
                  currentTurn.createdAt == expectedTurn.createdAt,
                  currentTurn.prompt == expectedTurn.prompt,
                  currentTurn.sentPrompt == expectedTurn.sentPrompt
            else { return false }
            if currentTurn.id != expectedTurn.id {
                guard !currentTurn.isPendingPlaceholder,
                      session.thread?.machineID == currentTurn.machineID,
                      session.thread?.lastRunID == currentTurn.id,
                      let root = session.thread?.rootRunID,
                      session.historyIdentity == "\(currentTurn.machineID):\(root)"
                else { return false }
                // A root may only appear for the captured submission itself.
                guard snapshot.historyIdentity == nil
                        || snapshot.historyIdentity == session.historyIdentity
                else { return false }
            } else if let capturedIdentity = snapshot.historyIdentity {
                guard session.historyIdentity == capturedIdentity else { return false }
            }
            return true
        }

        return currentTurn == expectedTurn && session.historyIdentity == snapshot.historyIdentity
    }

    private static func conversationSnapshot(of session: HerdrHudSession) -> ConversationSnapshot {
        ConversationSnapshot(
            historyIdentity: session.historyIdentity,
            count: session.exchanges.count,
            lastTurn: session.exchanges.last.map(turnIdentity)
        )
    }

    private static func turnIdentity(_ exchange: HerdrHudExchange) -> TurnIdentity {
        TurnIdentity(
            id: exchange.id,
            machineID: exchange.machineID,
            createdAt: exchange.createdAt,
            prompt: exchange.prompt,
            sentPrompt: exchange.sentPrompt
        )
    }

    /// Attaches remembered titles to the accepted conversation that owns them.
    /// Adoption consults the session's explicit accepted-submission-to-root
    /// mapping, so only the exact submission whose accepted run established the
    /// current history root can attach a title. A failed earlier submission
    /// retained in the transcript or a later turn can never claim it.
    private func adoptPendingHistoryTitles(for session: HerdrHudSession) {
        guard !pendingHistoryTitles.isEmpty,
              let identity = session.historyIdentity,
              let acceptedSubmissionID = session.acceptedSubmissionID(forHistoryIdentity: identity),
              let ownerChatID = chats.first(where: { $0.session === session })?.id else { return }
        let matches = pendingHistoryTitles.filter { record in
            record.chatID == ownerChatID && record.submissionID == acceptedSubmissionID
        }
        guard !matches.isEmpty else { return }
        for record in matches.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            saveHistoryTitle(record.title, for: identity)
        }
        pendingHistoryTitles.removeAll { record in matches.contains(record) }
        persistPendingHistoryTitles()
        persistIndex()
    }

    private func dropPendingHistoryTitles(chatID: String) {
        guard !pendingHistoryTitles.isEmpty else { return }
        let remaining = pendingHistoryTitles.filter { $0.chatID != chatID }
        guard remaining.count != pendingHistoryTitles.count else { return }
        pendingHistoryTitles = remaining
        persistPendingHistoryTitles()
    }

    private func savePendingHistoryTitle(_ record: PendingHistoryTitle) {
        pendingHistoryTitles.removeAll {
            $0.chatID == record.chatID && $0.submissionID == record.submissionID
        }
        pendingHistoryTitles.insert(record, at: 0)
        if pendingHistoryTitles.count > Self.maximumPendingHistoryTitles {
            pendingHistoryTitles.removeLast(pendingHistoryTitles.count - Self.maximumPendingHistoryTitles)
        }
        persistPendingHistoryTitles()
    }

    private func persistPendingHistoryTitles() {
        if let data = try? JSONEncoder().encode(pendingHistoryTitles) {
            defaults.set(data, forKey: Self.pendingHistoryTitlesDefaultsKey)
        }
    }

    /// Removing a bubble is local only. Server history and its Pi session remain.
    func dismiss(_ id: String, model: HerdrAppModel) async throws {
        guard let chat = chats.first(where: { $0.id == id }), !chat.session.isRunning,
              !chat.session.isEnding, !chat.session.isLoadingHistory, !chat.session.needsHistoryRefresh,
              chat.session.promotingExchangeIDs.isEmpty else { return }
        try await chat.session.saveHistory(model: model)
        guard !chat.session.isRunning, !chat.session.isLoadingHistory else { return }
        if selectedID == id { select(nil) }
        chats.removeAll { $0.id == id }
        dropPendingHistoryTitles(chatID: id)
        persistIndex()
    }

    /// Returns whether the ended chat was selected at removal time. A caller
    /// must not collapse a different card the user opened while stopping it.
    func end(_ id: String, model: HerdrAppModel) async throws -> Bool {
        guard let chat = chats.first(where: { $0.id == id }) else { return false }
        try await chat.session.endChat(model: model)
        let wasSelected = selectedID == id
        if wasSelected { select(nil) }
        chats.removeAll { $0.id == id }
        pendingRestorationIDs.remove(id)
        dropPendingHistoryTitles(chatID: id)
        persistIndex()
        return wasSelected
    }

    func openHistory(_ summary: HudChatSummary, machineID: String, model: HerdrAppModel) async throws -> String {
        try await openHistory(id: summary.id, title: summary.title, machineID: machineID, model: model)
    }

    /// Exact-ID history loading for agent control. This uses the direct
    /// /hud-chats/{id} loader and never scans the paginated catalog or
    /// resubmits the saved prompt.
    func openHistory(id historyID: String, machineID: String, model: HerdrAppModel) async throws -> String {
        try await openHistory(id: historyID, title: "", machineID: machineID, model: model)
    }

    private func openHistory(
        id historyID: String,
        title: String,
        machineID: String,
        model: HerdrAppModel
    ) async throws -> String {
        // Let startup restoration establish durable IDs before deduplicating.
        for chat in chats { await chat.session.waitForPersistenceRestore() }
        if let existing = chats.first(where: {
            $0.session.historyIdentity == "\(machineID):\(historyID)"
        }) {
            guard !existing.session.isEnding else { throw HerdrHudChatEndError.busy }
            if !existing.session.isRunning, !existing.session.isLoadingHistory {
                try await existing.session.openHistory(id: historyID, machineID: machineID, model: model)
            }
            return existing.id
        }
        let id = UUID().uuidString
        let session = prototype.makeIndependentSession(id: id)
        try await session.openHistory(id: historyID, machineID: machineID, model: model)
        let historyIdentity = "\(machineID):\(historyID)"
        let localTitle = savedHistoryTitles.first(where: { $0.historyIdentity == historyIdentity })?.title
        chats.insert(Chat(id: id, title: localTitle ?? title, session: session), at: 0)
        own(session)
        adoptPendingHistoryTitles(for: session)
        persistIndex()
        return id
    }

    /// Reattach cached conversations to the authoritative server after relaunch.
    /// Never resubmit a prompt; a disconnected machine leaves the cache intact.
    func restore(model: HerdrAppModel) async {
        for chat in chats where pendingRestorationIDs.contains(chat.id) {
            await chat.session.waitForPersistenceRestore()
            guard !Task.isCancelled else { return }
            // Attach any pending title this session can already bind to its
            // root; the refresh below records the accepted-submission mapping
            // when saved history re-establishes the conversation.
            adoptPendingHistoryTitles(for: chat.session)
            guard let machineID = chat.session.selectedMachineID,
                  model.canControl(machineID: machineID) else { continue }
            await chat.session.refreshSavedHistory(model: model)
            if !Task.isCancelled, !chat.session.needsHistoryRefresh {
                pendingRestorationIDs.remove(chat.id)
            }
        }
    }

    private func persistIndex() {
        let saved = chats.map { SavedChat(id: $0.id, title: $0.session.exchanges.isEmpty ? $0.title : $0.displayTitle) }
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    private func saveHistoryTitle(_ title: String, for historyIdentity: String) {
        savedHistoryTitles.removeAll { $0.historyIdentity == historyIdentity }
        savedHistoryTitles.insert(
            SavedHistoryTitle(historyIdentity: historyIdentity, title: title, updatedAt: .now),
            at: 0
        )
        if savedHistoryTitles.count > Self.maximumSavedHistoryTitles {
            savedHistoryTitles.removeLast(savedHistoryTitles.count - Self.maximumSavedHistoryTitles)
        }
        if let data = try? JSONEncoder().encode(savedHistoryTitles) {
            defaults.set(data, forKey: Self.historyTitlesDefaultsKey)
        }
    }

    private static func renameContext(for session: HerdrHudSession) -> String {
        let exchanges = session.exchanges
        let selected = exchanges.count > 9
            ? Array(exchanges.prefix(1)) + Array(exchanges.suffix(8))
            : exchanges
        return selected.flatMap { exchange -> [String] in
            var messages: [String] = []
            let prompt = exchange.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prompt.isEmpty {
                messages.append("User: \(prompt.prefix(1500))")
            }
            if let response = exchange.response?.trimmingCharacters(in: .whitespacesAndNewlines),
               !response.isEmpty {
                messages.append("Assistant: \(response.prefix(1500))")
            }
            return messages
        }.joined(separator: "\n").prefix(16_000).description
    }

    static func title(for session: HerdrHudSession) -> String {
        let prompt = session.exchanges.first?.prompt ?? "HUD chat"
        let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? "HUD chat"
        return String(line.prefix(120))
    }

    #if DEBUG
    /// Applies a manual title edit the way the UI would, for tests that need
    /// to race a rename against a newer user choice.
    func setTitleForTesting(_ title: String, for id: String) {
        guard let index = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[index] = Chat(id: id, title: title, session: chats[index].session)
        persistIndex()
    }
    #endif
}
