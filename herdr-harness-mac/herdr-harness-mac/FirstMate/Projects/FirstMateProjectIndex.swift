import Foundation
import Observation

@MainActor @Observable
final class FirstMateProjectIndex {
    private struct Result: Sendable {
        let machineID: String
        let capabilities: FirstMateCapabilities?
        let projects: FirstMateProjectList?
        let reachable: Bool
        let error: String?
        var invalidatesConnection = false
    }

    private(set) var hosts: [FirstMateProjectHost] = []
    private(set) var isDemo = false
    private(set) var revision = 0
    @ObservationIgnored var pollingInterval: Duration = .seconds(30)
    @ObservationIgnored private var sources: [String: FirstMateFleetSource] = [:]
    @ObservationIgnored private var epochs: [String: UUID] = [:]
    @ObservationIgnored private var writes: [String: Int] = [:]
    @ObservationIgnored private var lifecycle = 0
    @ObservationIgnored private var refreshID = 0
    @ObservationIgnored private var demoClient: FirstMateProjectsDemoClient?
    @ObservationIgnored private var validateConnection: (@MainActor (FirstMateProjectConnection) -> Bool)?

    var hasLoaded: Bool { hosts.isEmpty || hosts.contains(where: \.hasLoaded) }
    var isRefreshing: Bool { hosts.contains(where: \.isLoading) }
    var activeChoices: [FirstMateProjectChoice] { choices(includeArchived: false) }

    /// An alias may refer to the same authenticated companion. Prefer a live
    /// route for displaying duplicate records, while already selected routes
    /// remain pinned to their original saved machine ID.
    func choices(includeArchived: Bool) -> [FirstMateProjectChoice] {
        var result: [FirstMateProjectChoice] = []
        var locations: [String: Int] = [:]
        for host in hosts {
            for project in host.projects where includeArchived || !project.isArchived {
                let key = "\(host.serverID ?? host.machineID)|\(project.id)"
                let choice = FirstMateProjectChoice(host: host, project: project)
                if let index = locations[key] {
                    if !result[index].host.canManageProjects && host.canManageProjects { result[index] = choice }
                } else {
                    locations[key] = result.count
                    result.append(choice)
                }
            }
        }
        return result.sorted {
            if $0.project.isArchived != $1.project.isArchived { return !$0.project.isArchived }
            let order = $0.project.name.localizedStandardCompare($1.project.name)
            if order != .orderedSame { return order == .orderedAscending }
            if $0.host.machineName != $1.host.machineName { return $0.host.machineName < $1.host.machineName }
            return $0.project.id < $1.project.id
        }
    }

    func host(_ machineID: String?) -> FirstMateProjectHost? {
        hosts.first { $0.machineID == machineID }
    }

    func choice(_ selection: FirstMateProjectSelection?) -> FirstMateProjectChoice? {
        guard let selection, let host = host(selection.machineID),
              let project = host.projects.first(where: { $0.id == selection.projectID }) else { return nil }
        return .init(host: host, project: project)
    }

    func connection(for machineID: String?) -> FirstMateProjectConnection? {
        guard let machineID, let source = sources[machineID], let epoch = epochs[machineID] else { return nil }
        return .init(machineID: machineID, machineName: source.machine.name,
                     configuration: source.configuration, epoch: epoch,
                     serverID: host(machineID)?.serverID, client: source.client)
    }

    func isCurrent(_ connection: FirstMateProjectConnection) -> Bool {
        guard epochs[connection.machineID] == connection.epoch,
              sources[connection.machineID]?.configuration == connection.configuration,
              validateConnection?(connection) ?? true else { return false }
        if let serverID = connection.serverID, let current = host(connection.machineID)?.serverID {
            return current == serverID
        }
        return true
    }

    @discardableResult
    func activate(
        sources newSources: [FirstMateFleetSource], demo: Bool = false,
        validateConnection: (@MainActor (FirstMateProjectConnection) -> Bool)? = nil
    ) -> Int {
        lifecycle &+= 1
        refreshID &+= 1
        // The app's settings can change before SwiftUI restarts observation.
        // Consult their current value whenever a captured route is used.
        self.validateConnection = validateConnection
        let modeChanged = isDemo != demo
        isDemo = demo
        let effectiveSources: [FirstMateFleetSource]
        if demo {
            if demoClient == nil || modeChanged { demoClient = FirstMateProjectsDemoClient() }
            effectiveSources = demoClient.map { client in
                [.init(machine: .init(id: "demo", name: "Studio Mac", urlString: "https://companion.example.invalid"),
                       configuration: ServerConfiguration(urlString: "https://companion.example.invalid", token: "synthetic-demo")!,
                       client: client)]
            } ?? []
        } else {
            demoClient = nil
            effectiveSources = newSources
        }
        let previous = Dictionary(uniqueKeysWithValues: hosts.map { ($0.machineID, $0) })
        var nextSources: [String: FirstMateFleetSource] = [:]
        hosts = effectiveSources.compactMap { source in
            guard nextSources[source.machine.id] == nil else { return nil }
            nextSources[source.machine.id] = source
            if !modeChanged, sources[source.machine.id]?.configuration == source.configuration,
               var cached = previous[source.machine.id] {
                cached.machineName = source.machine.name
                cached.isLoading = false
                return cached
            }
            epochs[source.machine.id] = UUID()
            writes[source.machine.id] = 0
            return .init(machineID: source.machine.id, machineName: source.machine.name)
        }
        sources = nextSources
        epochs = epochs.filter { sources[$0.key] != nil }
        writes = writes.filter { sources[$0.key] != nil }
        revision &+= 1
        return lifecycle
    }

    func observe(
        sources: [FirstMateFleetSource], demo: Bool,
        validateConnection: (@MainActor (FirstMateProjectConnection) -> Bool)? = nil
    ) async {
        let token = activate(sources: sources, demo: demo, validateConnection: validateConnection)
        await refresh(lifecycle: token)
        while !Task.isCancelled, token == lifecycle {
            do { try await Task.sleep(for: pollingInterval) } catch { return }
            await refresh(lifecycle: token)
        }
    }

    func refresh() async { await refresh(lifecycle: lifecycle) }

    private func refresh(lifecycle token: Int) async {
        guard !Task.isCancelled, token == lifecycle else { return }
        refreshID &+= 1
        let request = refreshID
        let versions = writes
        let requests = hosts.compactMap { host -> (String, any FirstMateClient)? in
            guard let source = sources[host.machineID] else { return nil }
            return (host.machineID, source.client)
        }
        for i in hosts.indices { hosts[i].isLoading = true }
        await withTaskGroup(of: Result.self) { group in
            for (machineID, client) in requests {
                group.addTask {
                    var capabilities: FirstMateCapabilities?
                    do {
                        let value = try await client.fetchFirstMateCapabilities()
                        guard value.ok else { throw APIError.invalidResponse }
                        capabilities = value
                        let projects: FirstMateProjectList?
                        if value.supportsProjects {
                            let response = try await client.fetchFirstMateProjects(scope: .all)
                            guard response.ok else { throw APIError.invalidResponse }
                            guard !response.serverID.isEmpty,
                                  value.serverID == nil || value.serverID == response.serverID else {
                                return .init(
                                    machineID: machineID, capabilities: nil, projects: nil, reachable: false,
                                    error: "The companion identity changed while loading projects. Refresh this machine before continuing.",
                                    invalidatesConnection: true
                                )
                            }
                            projects = response
                        } else { projects = nil }
                        return .init(machineID: machineID, capabilities: value, projects: projects, reachable: true, error: nil)
                    } catch is CancellationError {
                        return .init(machineID: machineID, capabilities: nil, projects: nil, reachable: false, error: nil)
                    } catch {
                        if case APIError.server(let status, _) = error, [404, 501].contains(status), capabilities == nil {
                            // Legacy companions can still accept the manual create contract.
                            return .init(machineID: machineID, capabilities: .init(ok: true, capabilities: []), projects: nil, reachable: true, error: nil)
                        }
                        return .init(machineID: machineID, capabilities: capabilities, projects: nil,
                                     reachable: capabilities != nil, error: error.localizedDescription)
                    }
                }
            }
            for await result in group {
                guard !Task.isCancelled, token == lifecycle, request == refreshID,
                      let i = hosts.firstIndex(where: { $0.machineID == result.machineID }) else { continue }
                hosts[i].isLoading = false
                if result.invalidatesConnection {
                    // Neither response establishes the route's owner. Keep
                    // cached rows readable, but fence all previously captured
                    // connections until a fresh consistent read succeeds.
                    epochs[result.machineID] = UUID()
                    hosts[i].isReachable = false
                    hosts[i].hasLoaded = true
                    hosts[i].error = result.error
                    revision &+= 1
                    continue
                }
                guard writes[result.machineID] == versions[result.machineID] else { continue }
                let oldServer = hosts[i].serverID
                let server = result.projects?.serverID ?? result.capabilities?.serverID
                if let oldServer, let server, oldServer != server {
                    epochs[result.machineID] = UUID()
                    hosts[i].projects = []
                }
                if let server { hosts[i].serverID = server }
                if let capabilities = result.capabilities {
                    hosts[i].supportsProjects = capabilities.supportsProjects
                    hosts[i].supportsDirectoryBrowser = capabilities.supportsDirectoryBrowser
                    if !capabilities.supportsProjects { hosts[i].projects = [] }
                }
                if let projects = result.projects {
                    hosts[i].projects = projects.projects
                    hosts[i].lastUpdated = .now
                }
                hosts[i].isReachable = result.reachable
                hosts[i].hasLoaded = true
                hosts[i].error = result.error
                revision &+= 1
            }
        }
        if request == refreshID, token == lifecycle {
            for i in hosts.indices { hosts[i].isLoading = false }
        }
    }

    /// A successful write cannot be erased by an older list request.
    func receive(_ project: FirstMateProject, from connection: FirstMateProjectConnection) {
        guard isCurrent(connection), let owner = host(connection.machineID) else { return }
        for i in hosts.indices where hosts[i].machineID == owner.machineID || (owner.serverID != nil && hosts[i].serverID == owner.serverID) {
            if let position = hosts[i].projects.firstIndex(where: { $0.id == project.id }) {
                if hosts[i].projects[position].revision <= project.revision { hosts[i].projects[position] = project }
            } else { hosts[i].projects.append(project) }
            writes[hosts[i].machineID, default: 0] &+= 1
        }
        revision &+= 1
    }
}
