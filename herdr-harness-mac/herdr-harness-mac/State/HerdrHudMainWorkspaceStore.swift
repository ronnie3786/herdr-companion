import Foundation
import Observation

/// The workspace a user explicitly designated as their main workspace for new
/// HUD chats. Identity is the paired companion (machine ID plus normalized
/// endpoint) and the raw workspace ID. Display labels, workspace numbers, and
/// roster order never participate.
struct HerdrHudMainWorkspaceDestination: Codable, Equatable, Hashable, Sendable {
    let machineID: String
    let endpoint: String
    let workspaceID: String

    init(machineID: String, endpoint: String, workspaceID: String) {
        self.machineID = machineID
        self.endpoint = HerdrNotesSource.normalizedEndpoint(endpoint)
        self.workspaceID = workspaceID
    }

    init?(machine: HerdrMachine, workspace: HerdrWorkspace) {
        let machineID = machine.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspaceID = workspace.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !machineID.isEmpty, !workspaceID.isEmpty else { return nil }
        guard workspace.machineID.isEmpty || workspace.machineID == machine.id else { return nil }
        self.init(machineID: machineID, endpoint: machine.urlString, workspaceID: workspaceID)
    }

    private enum CodingKeys: String, CodingKey {
        case machineID
        case endpoint
        case workspaceID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        machineID = try container.decode(String.self, forKey: .machineID)
        endpoint = HerdrNotesSource.normalizedEndpoint(try container.decode(String.self, forKey: .endpoint))
        workspaceID = try container.decode(String.self, forKey: .workspaceID)
    }
}

/// Persists the explicitly chosen main workspace privately on this Mac. A
/// destination is only usable while the same paired companion (machine ID and
/// normalized endpoint) still exposes the exact raw workspace ID.
@MainActor
@Observable
final class HerdrHudMainWorkspaceStore {
    static let defaultsKey = "herdr.hud.mainWorkspace.v1"

    @ObservationIgnored private let userDefaults: UserDefaults
    private(set) var destinations: [String: HerdrHudMainWorkspaceDestination]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        destinations = Self.load(from: userDefaults)
    }

    /// The saved choice for this exact paired companion, or nil when the
    /// machine's endpoint was replaced. A renamed machine keeps its endpoint
    /// and therefore keeps its destination.
    func destination(for machine: HerdrMachine) -> HerdrHudMainWorkspaceDestination? {
        guard let stored = destinations[machine.id],
              stored.machineID == machine.id,
              stored.endpoint == HerdrNotesSource.normalizedEndpoint(machine.urlString),
              !stored.workspaceID.isEmpty
        else { return nil }
        return stored
    }

    /// The exact workspace for the saved destination, or nil when that
    /// workspace is absent from the machine's current topology. Matching is by
    /// raw workspace ID only; duplicate or renamed labels never reassign it.
    func workspace(for machine: HerdrMachine, in workspaces: [HerdrWorkspace]) -> HerdrWorkspace? {
        guard let destination = destination(for: machine) else { return nil }
        return workspaces.first {
            $0.workspaceID == destination.workspaceID
                && ($0.machineID.isEmpty || $0.machineID == machine.id)
        }
    }

    /// Records an explicit choice. Returns nil when the workspace cannot belong
    /// to the paired machine, in which case nothing is stored.
    @discardableResult
    func remember(
        workspace: HerdrWorkspace,
        for machine: HerdrMachine
    ) -> HerdrHudMainWorkspaceDestination? {
        guard let destination = HerdrHudMainWorkspaceDestination(machine: machine, workspace: workspace) else {
            return nil
        }
        destinations[machine.id] = destination
        persist()
        return destination
    }

    func forget(for machine: HerdrMachine) {
        guard destinations.removeValue(forKey: machine.id) != nil else { return }
        persist()
    }

    func forgetAll() {
        guard !destinations.isEmpty else { return }
        destinations = [:]
        userDefaults.removeObject(forKey: Self.defaultsKey)
    }

    private func persist() {
        guard !destinations.isEmpty else {
            userDefaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(destinations) else { return }
        userDefaults.set(data, forKey: Self.defaultsKey)
    }

    private static func load(from userDefaults: UserDefaults) -> [String: HerdrHudMainWorkspaceDestination] {
        guard let data = userDefaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(
                  [String: HerdrHudMainWorkspaceDestination].self,
                  from: data
              )
        else { return [:] }

        var result: [String: HerdrHudMainWorkspaceDestination] = [:]
        for (key, destination) in decoded {
            guard key == destination.machineID,
                  !destination.machineID.isEmpty,
                  destination.machineID.utf8.count <= 256,
                  !destination.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !destination.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  destination.workspaceID.utf8.count <= 512,
                  !destination.workspaceID.unicodeScalars.contains(where: { $0.value == 0 })
            else { continue }
            result[key] = destination
        }
        return result
    }
}
