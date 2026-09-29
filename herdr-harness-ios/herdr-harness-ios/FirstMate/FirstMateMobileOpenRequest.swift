import Foundation

/// Additive phone grammar. The mechanically shared Mac parser remains strict
/// and unchanged. This is navigation only, never a prompt or credential action.
struct FirstMateMobileOpenRequest: Equatable, Sendable {
    enum Destination: Equatable, Sendable { case feature(String), lead }
    enum Resolution: Equatable {
        case feature(FirstMateFeatureTarget)
        case lead(String?)
        case failure(String)
    }
    let destination: Destination
    let assignmentID: String?
    let origin: String?
    let inspector: FirstMateInspector?
    let graph: Bool

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "herdr", components.host == "first-mate",
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil, ["", "/lead"].contains(components.path) else { return nil }
        let items = components.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count,
              items.allSatisfy({ ["feature_id", "assignment_id", "server_url", "tab", "view"].contains($0.name) }) else { return nil }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        if components.path == "/lead" {
            guard values["feature_id"] == nil, values["assignment_id"] == nil else { return nil }
            destination = .lead
        } else {
            guard let id = values["feature_id"], Self.validID(id) else { return nil }
            destination = .feature(id)
        }
        if let assignment = values["assignment_id"], !Self.validID(assignment) { return nil }
        assignmentID = values["assignment_id"]
        if let server = values["server_url"] {
            guard let normalized = HerdrMachine.normalizedOrigin(server) else { return nil }
            origin = normalized
        } else { origin = nil }
        if let tab = values["tab"] {
            guard let value = FirstMateInspector.allCases.first(where: { $0.rawValue.lowercased() == tab }) else { return nil }
            inspector = value
        } else { inspector = nil }
        guard values["view"] == nil || values["view"] == "graph" else { return nil }
        graph = values["view"] == "graph"
        if destination == .lead, (assignmentID != nil || (inspector != nil && inspector != .overview) || graph) { return nil }
    }

    var requiresFleetOwnership: Bool {
        if case .feature = destination { return origin == nil }
        return false
    }

    func resolve(machines: [HerdrMachine], hosts: [FirstMateFleetHost], owner: FirstMateFeatureTarget?) -> Resolution {
        let explicit: String?
        if let origin {
            let matches = machines.filter { HerdrMachine.normalizedOrigin($0.urlString) == origin }
            guard matches.count == 1 else { return .failure("Choose one configured machine for this link.") }
            explicit = matches[0].id
        } else { explicit = nil }
        switch destination {
        case .lead: return .lead(explicit)
        case .feature(let featureID):
            if let explicit { return .feature(.init(machineID: explicit, featureID: featureID)) }
            if let owner {
                guard machines.contains(where: { $0.id == owner.machineID }) else { return .failure("The originating machine is no longer configured.") }
                return .feature(.init(machineID: owner.machineID, featureID: featureID))
            }
            let configured = Set(machines.map(\.id))
            // A first responder is not a unique owner. Missing, loading or
            // failed inventories cannot establish absence on the other hosts.
            guard !configured.isEmpty, configured.allSatisfy({ machineID in
                let evidence = hosts.filter { $0.machineID == machineID }
                return evidence.count == 1 && evidence[0].lastUpdated != nil
                    && !evidence[0].isLoading && evidence[0].error == nil && !evidence[0].unsupported
            }) else {
                return .failure("Feature ownership is still unknown. Open the feature from its machine, or use a link with a server URL.")
            }
            let owners = Set(hosts.filter { host in
                configured.contains(host.machineID) && (host.features.contains { $0.id == featureID }
                    || host.fleetEntries?[featureID] != nil || host.lead?.feature.id == featureID)
            }.map(\.machineID))
            guard owners.count == 1, let machineID = owners.first else {
                return .failure("Choose the owning machine, or open a link with its server URL.")
            }
            return .feature(.init(machineID: machineID, featureID: featureID))
        }
    }

    private static func validID(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:")
        return !value.isEmpty && value != "." && value != ".." && value.count <= 256
            && value.unicodeScalars.allSatisfy(allowed.contains)
    }
}

struct FirstMateMobileNavigation: Identifiable, Equatable {
    let id = UUID()
    let target: FirstMateFeatureTarget
    let assignmentID: String?
    let inspector: FirstMateInspector?
    let graph: Bool
}
