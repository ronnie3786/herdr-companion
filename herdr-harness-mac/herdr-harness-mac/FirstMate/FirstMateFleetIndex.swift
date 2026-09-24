import Foundation
import Observation

struct FirstMateFleetSource {
    let machine: HerdrMachine
    let configuration: ServerConfiguration
    let client: any FirstMateClient
}

struct FirstMateFleetHost: Identifiable, Equatable, Sendable {
    let machineID: String
    var machineName: String
    var features: [FirstMateFeature]
    var isLoading: Bool
    var error: String?
    var unsupported: Bool
    var lastUpdated: Date?

    var id: String { machineID }
}

@MainActor @Observable
final class FirstMateFleetIndex {
    private struct FetchResult: Sendable {
        let machineID: String
        let features: [FirstMateFeature]?
        let error: String?
        let unsupported: Bool
    }

    var search = ""
    private(set) var hosts: [FirstMateFleetHost] = []
    /// Increments only when a host's published state actually changes, or the
    /// roster does. Derived views cache against it.
    private(set) var contentRevision = 0
    /// Last successful contact per host. Not observed: it changes every poll and
    /// is only published (as `lastUpdated`) when a host goes offline.
    @ObservationIgnored private var lastContact: [String: Date] = [:]
    @ObservationIgnored var pollingInterval: Duration = .seconds(10)
    @ObservationIgnored private var clients: [String: any FirstMateClient] = [:]
    /// The authenticated connection each cached host was last reconciled with,
    /// keyed by stable machine ID. `activate` uses it to distinguish an
    /// unchanged host from a removed or reconfigured one.
    @ObservationIgnored private var hostConnections: [String: ServerConfiguration] = [:]
    @ObservationIgnored private var lifecycle = 0
    @ObservationIgnored private var refreshGeneration = 0

    var filteredHosts: [FirstMateFleetHost] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return hosts }
        return hosts.compactMap { host in
            var filtered = host
            filtered.features = host.features.filter {
                $0.title.localizedCaseInsensitiveContains(query)
                    || $0.goal.localizedCaseInsensitiveContains(query)
                    || ($0.workItemID?.localizedCaseInsensitiveContains(query) ?? false)
                    || host.machineName.localizedCaseInsensitiveContains(query)
            }
            return filtered.features.isEmpty ? nil : filtered
        }
    }

    var hasLoadedAnyHost: Bool {
        hosts.contains { !$0.isLoading && ($0.lastUpdated != nil || $0.error != nil || $0.unsupported) }
    }

    /// The number of distinct First Mate features on any host that are waiting
    /// on a human decision.
    ///
    /// Counted from unfiltered hosts, so neither the fleet search nor the
    /// selected host changes it. A host that has not reported a successful list
    /// contributes nothing; a host whose refresh failed keeps its last
    /// successful contribution, because an outage must not imply resolution.
    var attentionCount: Int {
        FirstMateAttention.count(hosts: hosts)
    }

    /// Installs the observed roster and returns the lifecycle token that
    /// ``refresh(lifecycle:)`` and ``deactivate(lifecycle:)`` require.
    ///
    /// Hosts are reconciled by stable machine ID and authenticated connection
    /// identity (URL plus token), never by roster position, display name, or
    /// the process-wide connection generation. An unchanged host keeps its last
    /// successful feature list — so an offline host's outstanding attention
    /// survives an unrelated roster edit — while its display name follows the
    /// current roster. Removed hosts and hosts whose connection was
    /// reconfigured are cleared, and every activation invalidates older
    /// refreshes so a delayed result can never repopulate a stale connection.
    @discardableResult
    func activate(sources: [FirstMateFleetSource], connectionGeneration: Int) -> Int {
        lifecycle &+= 1
        refreshGeneration &+= 1
        let cachedHosts = Dictionary(uniqueKeysWithValues: hosts.map { ($0.machineID, $0) })
        let cachedConnections = hostConnections
        let previousHosts = hosts
        defer {
            if hosts != previousHosts { contentRevision &+= 1 }
            lastContact = lastContact.filter { id, _ in hosts.contains { $0.machineID == id && $0.lastUpdated != nil } }
        }
        hosts = sources.map { source in
            let machine = source.machine
            if let cached = cachedHosts[machine.id],
               cachedConnections[machine.id] == source.configuration {
                var retained = cached
                retained.machineName = machine.name
                // Any in-flight refresh belongs to an older lifecycle and will
                // be rejected, so it must not leave a spinner running.
                retained.isLoading = false
                return retained
            }
            return FirstMateFleetHost(
                machineID: machine.id,
                machineName: machine.name,
                features: [],
                isLoading: false,
                error: nil,
                unsupported: false,
                lastUpdated: nil
            )
        }
        hostConnections = Dictionary(uniqueKeysWithValues: sources.map { ($0.machine.id, $0.configuration) })
        clients = Dictionary(uniqueKeysWithValues: sources.map { ($0.machine.id, $0.client) })
        return lifecycle
    }

    func deactivate(lifecycle expectedLifecycle: Int? = nil) {
        if let expectedLifecycle, expectedLifecycle != lifecycle { return }
        lifecycle &+= 1
        refreshGeneration &+= 1
        clients = [:]
        for index in hosts.indices where hosts[index].isLoading { hosts[index].isLoading = false }
    }

    func refresh(lifecycle expectedLifecycle: Int) async {
        guard !Task.isCancelled, expectedLifecycle == lifecycle else { return }
        refreshGeneration &+= 1
        let token = refreshGeneration
        let requests = hosts.compactMap { host -> (String, any FirstMateClient)? in
            guard let client = clients[host.machineID] else { return nil }
            return (host.machineID, client)
        }
        // Only a host that has never answered shows as loading. Background polls
        // of a loaded host change nothing observable until its data changes, so
        // the Dashboard and sidebar are not invalidated every interval. A retry is
        // not a successful contact: last-seen/error evidence is kept until this
        // host actually returns a new list.
        for index in hosts.indices where hosts[index].lastUpdated == nil && hosts[index].error == nil {
            let loading = clients[hosts[index].machineID] != nil
            if hosts[index].isLoading != loading { hosts[index].isLoading = loading }
        }

        await withTaskGroup(of: FetchResult.self) { group in
            for (machineID, client) in requests {
                group.addTask {
                    do {
                        let response = try await client.fetchFirstMateFeatures()
                        guard response.ok else { throw APIError.invalidResponse }
                        return FetchResult(machineID: machineID, features: response.features, error: nil, unsupported: false)
                    } catch is CancellationError {
                        return FetchResult(machineID: machineID, features: nil, error: nil, unsupported: false)
                    } catch {
                        let unsupported: Bool
                        if case APIError.server(let status, _) = error {
                            unsupported = status == 404 || status == 501
                        } else {
                            unsupported = false
                        }
                        return FetchResult(
                            machineID: machineID,
                            features: nil,
                            error: unsupported ? "This companion needs First Mate support." : error.localizedDescription,
                            unsupported: unsupported
                        )
                    }
                }
            }
            for await result in group {
                guard !Task.isCancelled,
                      expectedLifecycle == lifecycle, token == refreshGeneration,
                      let index = hosts.firstIndex(where: { $0.machineID == result.machineID }),
                      clients[result.machineID] != nil
                else { continue }
                // Build the next value and assign once, only when it differs:
                // every write to `hosts` invalidates all of its observers.
                var host = hosts[index]
                host.isLoading = false
                if let features = result.features {
                    lastContact[result.machineID] = .now
                    host.features = features
                    if host.lastUpdated == nil || host.error != nil || host.unsupported { host.lastUpdated = .now }
                    host.error = nil
                    host.unsupported = false
                } else if result.error != nil {
                    // "Last seen" is the last successful contact before this failure.
                    if host.error == nil, let contact = lastContact[result.machineID] { host.lastUpdated = contact }
                    host.error = result.error
                    host.unsupported = result.unsupported
                }
                if host != hosts[index] {
                    hosts[index] = host
                    contentRevision &+= 1
                }
            }
        }
    }

    func refresh() async {
        let activeLifecycle = lifecycle
        await refresh(lifecycle: activeLifecycle)
    }

    /// Activates the roster, refreshes it immediately, and then refreshes on
    /// `pollingInterval` until this task is cancelled or a newer activation
    /// supersedes the roster.
    ///
    /// An empty roster resets any obsolete hosts and exits without polling.
    /// The deferred deactivation is lifecycle-scoped, so a superseded observer
    /// can never tear down a newer roster or apply a delayed result. Existing
    /// callers of `activate`/`refresh` keep working unchanged.
    func observe(sources: [FirstMateFleetSource], connectionGeneration: Int) async {
        guard !Task.isCancelled else { return }
        let expectedLifecycle = activate(sources: sources, connectionGeneration: connectionGeneration)
        defer { deactivate(lifecycle: expectedLifecycle) }
        guard !sources.isEmpty else { return }
        await refresh(lifecycle: expectedLifecycle)
        while isObserving(expectedLifecycle) {
            do {
                try await Task.sleep(for: pollingInterval)
            } catch {
                return
            }
            guard isObserving(expectedLifecycle) else { return }
            await refresh(lifecycle: expectedLifecycle)
        }
    }

    private func isObserving(_ expectedLifecycle: Int) -> Bool {
        !Task.isCancelled && expectedLifecycle == lifecycle
    }
}
