import Foundation
import Observation

/// Personal iOS organization, not server tab metadata. Assignments use
/// machine-scoped tab IDs so all current and future panes in a tab inherit.
@MainActor
@Observable
final class ChatTabColorStore {
    private static let defaultsKey = "herdr.chatTabColors.v1"

    private let defaults: UserDefaults
    private var assignments: [String: String]
    private var labels: [String: String]

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
        let rawTabID = MachineScopedID.split(tabID)?.rawID ?? tabID
        guard !rawTabID.isEmpty, self.color(for: tabID) != color else { return }
        assignments[tabID] = color?.rawValue
        save()
    }

    @discardableResult
    func rename(_ color: ChatTabColor, to text: String) -> Bool {
        guard let label = Self.validLabel(text) else { return false }
        labels[color.rawValue] = label
        save()
        return true
    }

    func resetLabel(_ color: ChatTabColor) {
        guard labels.removeValue(forKey: color.rawValue) != nil else { return }
        save()
    }

    func activeColors(tabIDs: Set<String>) -> [ChatTabColor] {
        let active = Set(tabIDs.compactMap { color(for: $0) })
        return ChatTabColor.allCases.filter { active.contains($0) }
    }

    static func validLabel(_ text: String) -> String? {
        let label = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty,
              label.count <= 80,
              !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return label
    }

    private func save() {
        defaults.set(
            ["assignments": assignments, "labels": labels],
            forKey: Self.defaultsKey
        )
    }
}
