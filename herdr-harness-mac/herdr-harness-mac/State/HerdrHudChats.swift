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

    private static let defaultsKey = "herdr.hud.standaloneChats.v1"
    private let defaults: UserDefaults
    private let prototype: HerdrHudSession
    private(set) var chats: [Chat]
    private(set) var composer: HerdrHudSession
    private var composerID: String
    private(set) var selectedID: String?
    private var pendingRestorationIDs: Set<String>

    var selectedChat: Chat? { chats.first { $0.id == selectedID } }
    var displayedSession: HerdrHudSession { selectedChat?.session ?? composer }
    var visibleChats: [Chat] { chats.filter { !$0.session.exchanges.isEmpty || $0.session.isLoadingHistory } }

    init(legacySession: HerdrHudSession, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        prototype = legacySession
        let saved = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([SavedChat].self, from: $0) }
            ?? [SavedChat(id: "legacy", title: "")]
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

    /// Called synchronously after submission validation, before the first await.
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
        // Let startup restoration establish durable IDs before deduplicating.
        for chat in chats { await chat.session.waitForPersistenceRestore() }
        if let existing = chats.first(where: {
            $0.session.historyIdentity == "\(machineID):\(summary.id)"
        }) {
            guard !existing.session.isEnding else { throw HerdrHudChatEndError.busy }
            if !existing.session.isRunning, !existing.session.isLoadingHistory {
                try await existing.session.openHistory(summary, machineID: machineID, model: model)
            }
            return existing.id
        }
        let id = UUID().uuidString
        let session = prototype.makeIndependentSession(id: id)
        try await session.openHistory(summary, machineID: machineID, model: model)
        chats.insert(Chat(id: id, title: summary.title, session: session), at: 0)
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

    static func title(for session: HerdrHudSession) -> String {
        let prompt = session.exchanges.first?.prompt ?? "HUD chat"
        let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? "HUD chat"
        return String(line.prefix(120))
    }
}
