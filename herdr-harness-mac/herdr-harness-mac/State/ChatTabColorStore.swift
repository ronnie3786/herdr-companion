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

    /// Resolves color assignments to the concrete tabs currently visible in the
    /// sidebar. The result deliberately retains every target, including tabs on
    /// disconnected machines, so the menu can show the destination and disable
    /// only the targets that cannot be controlled.
    func destinations(
        for color: ChatTabColor,
        in workspaces: [HerdrWorkspace],
        machines: [HerdrMachine]
    ) -> [ChatTabColorDestination] {
        let machineNames = Dictionary(uniqueKeysWithValues: machines.map { ($0.id, $0.name) })
        let machineOrder = Dictionary(
            uniqueKeysWithValues: machines.enumerated().map { ($0.element.id, $0.offset) }
        )
        var seenTabIDs = Set<String>()

        let destinations = workspaces.flatMap { workspace in
            workspace.tabs.compactMap { tab -> ChatTabColorDestination? in
                let machineID = workspace.machineID.isEmpty ? tab.machineID : workspace.machineID
                let scopedTabID: String
                if !tab.machineID.isEmpty {
                    scopedTabID = tab.id
                } else if !machineID.isEmpty {
                    scopedTabID = MachineScopedID.compose(machineID: machineID, rawID: tab.tabID)
                } else {
                    scopedTabID = tab.id
                }
                guard self.color(for: scopedTabID) == color,
                      seenTabIDs.insert(scopedTabID).inserted
                else { return nil }

                let scopedWorkspaceID: String
                if !workspace.machineID.isEmpty {
                    scopedWorkspaceID = workspace.id
                } else if !machineID.isEmpty {
                    scopedWorkspaceID = MachineScopedID.compose(
                        machineID: machineID,
                        rawID: workspace.workspaceID
                    )
                } else {
                    scopedWorkspaceID = workspace.id
                }
                let hasOpenPane = workspace.panes.contains {
                    $0.scopedTabID == scopedTabID
                        || ($0.tabID == tab.tabID && $0.machineID == machineID)
                }

                let machineName = machineNames[machineID].flatMap { $0.isEmpty ? nil : $0 }
                    ?? (machineID.isEmpty ? "Unknown machine" : machineID)
                return ChatTabColorDestination(
                    machineID: machineID,
                    machineName: machineName,
                    scopedWorkspaceID: scopedWorkspaceID,
                    rawWorkspaceID: workspace.workspaceID,
                    workspaceLabel: workspace.label.isEmpty ? workspace.workspaceID : workspace.label,
                    scopedTabID: scopedTabID,
                    rawTabID: tab.tabID,
                    tabLabel: tab.label.isEmpty ? tab.tabID : tab.label,
                    workspaceNumber: workspace.number,
                    tabNumber: tab.number,
                    hasOpenPane: hasOpenPane
                )
            }
        }

        return destinations.sorted { lhs, rhs in
            let lhsMachineOrder = machineOrder[lhs.machineID] ?? Int.max
            let rhsMachineOrder = machineOrder[rhs.machineID] ?? Int.max
            if lhsMachineOrder != rhsMachineOrder { return lhsMachineOrder < rhsMachineOrder }
            if lhs.machineName != rhs.machineName {
                let comparison = lhs.machineName.localizedStandardCompare(rhs.machineName)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            }
            let workspaceComparison = lhs.workspaceLabel.localizedStandardCompare(rhs.workspaceLabel)
            if workspaceComparison != .orderedSame {
                return workspaceComparison == .orderedAscending
            }
            if lhs.workspaceNumber != rhs.workspaceNumber {
                return lhs.workspaceNumber < rhs.workspaceNumber
            }
            if lhs.tabNumber != rhs.tabNumber { return lhs.tabNumber < rhs.tabNumber }
            let tabComparison = lhs.tabLabel.localizedStandardCompare(rhs.tabLabel)
            if tabComparison != .orderedSame { return tabComparison == .orderedAscending }
            return lhs.id < rhs.id
        }
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
