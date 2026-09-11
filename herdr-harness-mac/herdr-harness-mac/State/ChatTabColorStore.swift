import Foundation
import Observation

/// Personal organization, not server tab metadata. Keys are machine-scoped tab
/// IDs, so every pane (including future splits) inherits its tab's assignment.
@MainActor @Observable
final class ChatTabColorStore {
    private static let defaultsKey = "herdr.chatTabColors.v1"
    private let defaults: UserDefaults
    private var assignments: [String: String]
    private var labels: [String: String]
    private var revisions: [ChatTabColor: UUID] = [:]
    private(set) var smartRenaming: Set<ChatTabColor> = []

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let saved = defaults.dictionary(forKey: Self.defaultsKey)
        assignments = saved?["assignments"] as? [String: String] ?? [:]
        labels = saved?["labels"] as? [String: String] ?? [:]
    }

    func color(for tabID: String) -> ChatTabColor? {
        assignments[tabID].flatMap(ChatTabColor.init(rawValue:))
    }

    func tabIDs(for color: ChatTabColor) -> Set<String> {
        Set(assignments.compactMap { $0.value == color.rawValue ? $0.key : nil })
    }

    func label(for color: ChatTabColor) -> String {
        labels[color.rawValue].flatMap(Self.validLabel) ?? color.defaultLabel
    }

    func assign(_ color: ChatTabColor?, to tabID: String) {
        guard !(MachineScopedID.split(tabID)?.rawID ?? tabID).isEmpty,
              self.color(for: tabID) != color else { return }
        if let previous = self.color(for: tabID) { revisions[previous] = UUID() }
        assignments[tabID] = color?.rawValue
        if let color { revisions[color] = UUID() }
        save()
    }

    @discardableResult
    func rename(_ color: ChatTabColor, to text: String) -> Bool {
        guard let label = Self.validLabel(text) else { return false }
        labels[color.rawValue] = label
        // Also invalidate an in-flight AI rename when the text was unchanged.
        revisions[color] = UUID()
        save()
        return true
    }

    func resetLabel(_ color: ChatTabColor) {
        labels[color.rawValue] = nil
        revisions[color] = UUID()
        save()
    }

    func revision(for color: ChatTabColor) -> UUID? { revisions[color] }

    func beginSmartRename(_ color: ChatTabColor) -> Bool {
        smartRenaming.insert(color).inserted
    }

    func endSmartRename(_ color: ChatTabColor) { smartRenaming.remove(color) }

    /// Preserve assignments during disconnects. Only currently known tabs are
    /// shown in the legend, without deleting metadata for temporarily absent tabs.
    func activeColors(tabIDs: Set<String>) -> [ChatTabColor] {
        let active = Set(tabIDs.compactMap { color(for: $0) })
        return ChatTabColor.allCases.filter { active.contains($0) }
    }

    static func validLabel(_ text: String) -> String? {
        let label = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 80,
              !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return label
    }

    private func save() {
        defaults.set(["assignments": assignments, "labels": labels], forKey: Self.defaultsKey)
    }
}
