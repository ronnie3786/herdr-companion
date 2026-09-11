import Foundation

/// Snapshot-only validation: no network request or side effect while rendering.
/// Raw IDs belong to the response's machine; explicit links can name another.
struct PaneResponseLinkCatalog: Equatable, Sendable {
    private let targets: [String: PaneResponseTarget]
    private let origins: [String: Set<String>]
    private let sourceMachineID: String?

    init(panes: [HerdrPane], machines: [HerdrMachine], sourceMachineID: String?) {
        self.sourceMachineID = sourceMachineID.flatMap { $0.isEmpty ? nil : $0 }
        targets = Dictionary(panes.filter { !$0.machineID.isEmpty }.map { pane in
            let target = PaneResponseTarget(machineID: pane.machineID, paneID: pane.paneID, terminalID: pane.terminalID)
            return (target.scopedID, target)
        }, uniquingKeysWith: { first, _ in first })
        var origins: [String: Set<String>] = [:]
        for machine in machines {
            if let url = URL(string: machine.urlString), let origin = Self.origin(url) {
                origins[origin, default: []].insert(machine.id)
            }
        }
        self.origins = origins
    }

    func target(for reference: String) -> PaneResponseTarget? {
        if let url = URL(string: reference), ["herdr", "http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return target(for: url)
        }
        return resolve(reference.removingPercentEncoding ?? reference, machineID: sourceMachineID)
    }

    func isPaneURL(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "herdr" { return url.host?.lowercased() == "pane" }
        let parts = url.pathComponents.filter { $0 != "/" }
        return Self.origin(url).flatMap { origins[$0] } != nil && parts.starts(with: ["open", "pane"])
    }

    func target(for url: URL) -> PaneResponseTarget? {
        guard isPaneURL(url), url.user == nil, url.password == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        let isCustom = url.scheme?.lowercased() == "herdr"
        guard isCustom ? parts.count <= 1 : (2...3).contains(parts.count) else { return nil }
        let query = components.queryItems ?? []
        let paneQueries = query.filter { ["pane", "paneId", "pane_id"].contains($0.name) }
        let machineQueries = query.filter { ["machine", "machineId", "machine_id"].contains($0.name) }
        let terminalQueries = query.filter { $0.name == "terminal_id" }
        guard paneQueries.count <= 1, machineQueries.count <= 1, terminalQueries.count <= 1 else { return nil }
        let pathID = isCustom ? parts.first : (parts.count == 3 ? parts[2] : nil)
        let queryID = paneQueries.first?.value
        if let pathID, let queryID, pathID != queryID { return nil }
        guard let reference = pathID ?? queryID else { return nil }
        let explicitMachine = machineQueries.first?.value
        var selectedMachine = explicitMachine ?? sourceMachineID
        var allowedMachines: Set<String>?
        if !isCustom {
            guard let origin = Self.origin(url), let matches = origins[origin] else { return nil }
            allowedMachines = matches
            if let explicitMachine {
                guard matches.contains(explicitMachine) else { return nil }
            } else if matches.count == 1 {
                selectedMachine = matches.first
            } else if let scoped = MachineScopedID.split(reference), matches.contains(scoped.machineID) {
                selectedMachine = scoped.machineID
            } else {
                return nil // Two saved machines share this origin: do not guess.
            }
        }
        guard let target = resolve(reference, machineID: selectedMachine, explicitMachine: explicitMachine) else { return nil }
        if let allowedMachines, !allowedMachines.contains(target.machineID) { return nil }
        if let terminal = terminalQueries.first?.value, target.terminalID != terminal { return nil }
        return target
    }

    private func resolve(_ reference: String, machineID: String?, explicitMachine: String? = nil) -> PaneResponseTarget? {
        if let scoped = MachineScopedID.split(reference) {
            guard Self.isRawPaneID(scoped.rawID), explicitMachine == nil || explicitMachine == scoped.machineID else { return nil }
            return targets[reference]
        }
        guard Self.isRawPaneID(reference) else { return nil }
        if let machineID { return targets[MachineScopedID.compose(machineID: machineID, rawID: reference)] }
        let matches = targets.values.filter { $0.paneID == reference }
        return matches.count == 1 ? matches.first : nil
    }

    private static func isRawPaneID(_ value: String) -> Bool {
        value.range(of: #"^w[A-Za-z0-9]+:p[A-Za-z0-9]+$"#, options: .regularExpression) != nil
    }

    private static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), url.user == nil, url.password == nil else { return nil }
        return "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
    }
}
