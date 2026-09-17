import Foundation
import Observation

@MainActor
@Observable
final class ResponseBriefPreferences {
    private enum Key {
        static let enabledChats = "herdr.responseBrief.enabledChats.v1"
        static let model = "herdr.responseBrief.model.v1"
        static let thinking = "herdr.responseBrief.thinking.v1"
    }

    static let maximumEnabledChats = 20

    @ObservationIgnored private let defaults: UserDefaults
    private(set) var enabledChats: [ResponseBriefChatIdentity]
    private(set) var model: String?
    private(set) var thinkingLevel: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Key.enabledChats),
           let chats = try? JSONDecoder().decode([ResponseBriefChatIdentity].self, from: data) {
            enabledChats = Array(chats.suffix(Self.maximumEnabledChats))
        } else {
            enabledChats = []
        }
        model = defaults.string(forKey: Key.model)
        thinkingLevel = defaults.string(forKey: Key.thinking)
    }

    func isEnabled(_ chat: ResponseBriefChatIdentity) -> Bool {
        enabledChats.contains { $0.machineID == chat.machineID && $0.sessionID == chat.sessionID }
    }

    func enable(_ chat: ResponseBriefChatIdentity) -> Bool {
        if isEnabled(chat) { return true }
        guard enabledChats.count < Self.maximumEnabledChats else { return false }
        enabledChats.append(chat)
        persistChats()
        return true
    }

    func disable(_ chat: ResponseBriefChatIdentity) {
        enabledChats.removeAll { $0.machineID == chat.machineID && $0.sessionID == chat.sessionID }
        persistChats()
    }

    func replaceModel(_ model: String?) {
        self.model = model
        defaults.set(model, forKey: Key.model)
    }

    func replaceThinkingLevel(_ level: String?) {
        thinkingLevel = level
        defaults.set(level, forKey: Key.thinking)
    }

    private func persistChats() {
        defaults.set(try? JSONEncoder().encode(enabledChats), forKey: Key.enabledChats)
    }
}
