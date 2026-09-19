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

    enum SmartRenameError: LocalizedError, Equatable {
        case unavailable
        case busy
        case changed
        case invalidTitle

        var errorDescription: String? {
            switch self {
            case .unavailable: "This HUD chat does not have enough conversation to name yet."
            case .busy: "Smart Rename is already running for this HUD chat."
            case .changed: "The HUD chat changed while Smart Rename was running. Try again."
            case .invalidTitle: "Smart Rename did not return a valid short title."
            }
        }
    }

    private static let defaultsKey = "herdr.hud.standaloneChats.v1"
    private static let historyTitlesDefaultsKey = "herdr.hud.historyTitles.v1"
    private static let maximumSavedHistoryTitles = 200
    private let defaults: UserDefaults
    private let prototype: HerdrHudSession
    private(set) var chats: [Chat]
    private(set) var composer: HerdrHudSession
    private var composerID: String
    private(set) var selectedID: String?
    private var pendingRestorationIDs: Set<String>
    private var savedHistoryTitles: [SavedHistoryTitle]
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
    }

    /// Called after the submission owns preflight and creates its local row.
    /// Keeping the submitted instance alive here lets its task outlive the card.
    func submissionStarted(_ session: HerdrHudSession) {
        if session === composer {
            chats.insert(Chat(id: composerID, title: Self.title(for: session), session: session), at: 0)
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

    func select(_ id: String?) {
        displayedSession.isCollapsed = true
        selectedID = chats.contains(where: { $0.id == id }) ? id : nil
    }

    func smartRename(
        _ id: String,
        model: HerdrAppModel,
        runner: any HerdrNoteAIRunner = HerdrLiveNoteAIRunner()
    ) async throws {
        guard smartRenamingChatIDs.insert(id).inserted else { throw SmartRenameError.busy }
        defer { smartRenamingChatIDs.remove(id) }
        guard let chat = chats.first(where: { $0.id == id }),
              !chat.session.isEnding, !chat.session.hasEnded,
              !chat.session.isLoadingHistory, !chat.session.needsHistoryRefresh,
              let machineID = chat.session.selectedMachineID,
              model.canControl(machineID: machineID)
        else { throw SmartRenameError.unavailable }

        let context = Self.renameContext(for: chat.session)
        guard !context.isEmpty else { throw SmartRenameError.unavailable }
        let expectedSession = chat.session
        let expectedHistoryIdentity = chat.session.historyIdentity
        let expectedRevision = chat.session.exchangesRevision
        let expectedTitle = chat.title
        let settings = AgentModelSettings.load(from: defaults)
        let charter = await model.supportsPromptOverrides(machineID: machineID)
            ? "You name conversations. Use only supplied text. Never call tools. Return only the requested JSON object."
            : nil
        let response = try await runner.run(
            prompt: SmartPaneTitle.prompt(context: context),
            machineID: machineID,
            mode: .ask,
            model: settings.quickChatModel.isEmpty ? nil : settings.quickChatModel,
            thinkingLevel: "low",
            systemPrompt: charter,
            deadline: .seconds(60),
            appModel: model,
            onProgress: { _ in }
        )
        try Task.checkCancellation()
        guard let index = chats.firstIndex(where: { $0.id == id }),
              chats[index].session === expectedSession,
              chats[index].session.historyIdentity == expectedHistoryIdentity,
              chats[index].session.exchangesRevision == expectedRevision,
              chats[index].title == expectedTitle,
              chats[index].session.selectedMachineID == machineID,
              !chats[index].session.isEnding, !chats[index].session.hasEnded,
              !chats[index].session.isLoadingHistory, !chats[index].session.needsHistoryRefresh
        else { throw SmartRenameError.changed }
        guard let title = SmartPaneTitle.parse(response) else { throw SmartRenameError.invalidTitle }

        chats[index] = Chat(id: id, title: title, session: expectedSession)
        if let historyIdentity = expectedSession.historyIdentity {
            saveHistoryTitle(title, for: historyIdentity)
        }
        persistIndex()
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
        persistIndex()
        return id
    }

    /// Reattach cached conversations to the authoritative server after relaunch.
    /// Never resubmit a prompt; a disconnected machine leaves the cache intact.
    func restore(model: HerdrAppModel) async {
        for chat in chats where pendingRestorationIDs.contains(chat.id) {
            await chat.session.waitForPersistenceRestore()
            guard !Task.isCancelled else { return }
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
            var messages = ["User: \(exchange.prompt.prefix(1500))"]
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
}
