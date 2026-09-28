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
    /// Whether the companion advertises `first-mate-fleet-v1`. Probed once per
    /// index lifecycle; an unsupported host is probed again at most every
    /// ``FirstMateFleetIndex/capabilityReprobeInterval``.
    var supportsFleet: Bool = false
    /// The fleet summary by feature ID, or nil when the host lacks the fleet
    /// capability or has not answered yet. A failed refresh keeps the last one.
    var fleetEntries: [String: FirstMateFleetEntry]? = nil

    var id: String { machineID }
}

@MainActor @Observable
final class FirstMateFleetIndex {
    private struct FetchResult: Sendable {
        let machineID: String
        let features: [FirstMateFeature]?
        let error: String?
        let unsupported: Bool
        /// The capability probe's answer, or nil when no probe ran or it failed.
        var probedFleetSupport: Bool? = nil
        /// Fleet entries, or nil when not requested or the request failed.
        var fleet: [FirstMateFleetEntry]? = nil
    }

    private struct CapabilityProbe {
        let supportsFleet: Bool
        let probedAt: Date
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
    /// The roster's clients, kept after ``deactivate(lifecycle:)`` so a chat
    /// read while nothing observes the index still reaches its companion. The
    /// next activation replaces them along with the hosts they belong to.
    @ObservationIgnored private var readClients: [String: any FirstMateClient] = [:]
    /// The lifecycle an ``observe(sources:connectionGeneration:)`` call is
    /// polling, or nil once it stops.
    @ObservationIgnored private var observedLifecycle: Int?
    /// The authenticated connection each cached host was last reconciled with,
    /// keyed by stable machine ID. `activate` uses it to distinguish an
    /// unchanged host from a removed or reconfigured one.
    @ObservationIgnored private var hostConnections: [String: ServerConfiguration] = [:]
    @ObservationIgnored private var lifecycle = 0
    @ObservationIgnored private var refreshGeneration = 0
    /// Capability answers for this lifecycle, by machine ID. A failed probe
    /// records nothing, so the next refresh asks again.
    @ObservationIgnored private var capabilityProbes: [String: CapabilityProbe] = [:]
    @ObservationIgnored var capabilityReprobeInterval: TimeInterval = 5 * 60
    /// How soon a sleeping observer notices it was superseded.
    static let supersessionCheckInterval: Duration = .milliseconds(500)
    @ObservationIgnored var clock: @MainActor () -> Date = { Date() }
    /// Chats read on this Mac that the companion has not confirmed yet.
    private(set) var readState = FirstMateReadState()
    @ObservationIgnored private var badgeCache: (revision: Int, readState: FirstMateReadState, count: Int)?

    /// Whether an ``observe(sources:connectionGeneration:)`` call is polling
    /// the current roster. The chat window starts its own observer only when
    /// none is, so it never supersedes the main window's.
    var hasObserver: Bool { observedLifecycle == lifecycle }

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

    /// Conversations showing an unread dot: they need you and have an unread
    /// First Mate message. Hosts without the fleet capability count exactly
    /// what ``attentionCount`` counts.
    ///
    /// Cached against ``contentRevision`` and the read state: building the
    /// conversation list renders every preview, and the Dock badge, sidebar,
    /// and chat window all read this on each update.
    var badgeCount: Int {
        let revision = contentRevision
        let readState = readState
        if let cache = badgeCache, cache.revision == revision, cache.readState == readState { return cache.count }
        let count = FirstMateBadge.count(hosts: hosts, readState: readState)
        badgeCache = (revision, readState, count)
        return count
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
        readClients = clients
        capabilityProbes = [:]
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
        let now = clock()
        let requests = hosts.compactMap { host -> (String, any FirstMateClient, Bool?)? in
            guard let client = clients[host.machineID] else { return nil }
            // nil asks the host again; a supported answer lasts the lifecycle.
            let known = capabilityProbes[host.machineID].flatMap { probe -> Bool? in
                probe.supportsFleet || now.timeIntervalSince(probe.probedAt) < capabilityReprobeInterval
                    ? probe.supportsFleet : nil
            }
            return (host.machineID, client, known)
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
            for (machineID, client, knownFleetSupport) in requests {
                group.addTask {
                    do {
                        var probed: Bool?
                        if knownFleetSupport == nil {
                            do {
                                let capabilities = try await client.fetchFirstMateCapabilities()
                                probed = capabilities.ok && capabilities.supportsFleet
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch APIError.server(let status, _) where status == 404 || status == 501 {
                                // A companion without the capability route predates the fleet.
                                probed = false
                            } catch {
                                // Unknown: keep the host's last answer and ask again next time.
                            }
                        }
                        let response = try await client.fetchFirstMateFeatures()
                        guard response.ok else { throw APIError.invalidResponse }
                        var result = FetchResult(machineID: machineID, features: response.features, error: nil, unsupported: false)
                        result.probedFleetSupport = probed
                        if probed ?? knownFleetSupport ?? false {
                            // A failed summary keeps the last one, like a failed list.
                            if let fleet = try? await client.fetchFirstMateFleet(), fleet.ok {
                                result.fleet = fleet.features
                            }
                        }
                        return result
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
                    if !Self.samePublishedFeatures(host.features, features) { host.features = features }
                    if host.lastUpdated == nil || host.error != nil || host.unsupported { host.lastUpdated = .now }
                    host.error = nil
                    host.unsupported = false
                    if let probed = result.probedFleetSupport {
                        capabilityProbes[result.machineID] = CapabilityProbe(supportsFleet: probed, probedAt: now)
                        host.supportsFleet = probed
                    }
                    if !host.supportsFleet {
                        host.fleetEntries = nil
                    } else if let fleet = result.fleet {
                        let entries = Dictionary(fleet.map { ($0.featureID, $0) }, uniquingKeysWith: { first, _ in first })
                        if !Self.samePublishedFleetEntries(host.fleetEntries, entries) { host.fleetEntries = entries }
                    }
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

    /// Pi telemetry refreshes each feature's usage, context estimate, and
    /// `updated_at` on nearly every poll while agents work. Nothing the fleet
    /// shows depends on them (ordering uses `activity_at` when the companion
    /// reports it), so they alone never count as a change.
    static func samePublishedFeatures(_ lhs: [FirstMateFeature], _ rhs: [FirstMateFeature]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            guard left != right else { return true }
            var a = left, b = right
            a.usage = nil; b.usage = nil
            a.coordinatorContext = nil; b.coordinatorContext = nil
            if a.dashboardSummary?.activityAt != nil, b.dashboardSummary?.activityAt != nil { a.updatedAt = b.updatedAt }
            return a == b
        }
    }

    /// Only `updated_at` moves with Pi telemetry; every other fleet field is
    /// on screen, so any other change publishes.
    static func samePublishedFleetEntries(_ lhs: [String: FirstMateFleetEntry]?, _ rhs: [String: FirstMateFleetEntry]?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        guard lhs.count == rhs.count else { return false }
        return lhs.allSatisfy { id, left in
            guard var right = rhs[id] else { return false }
            right.updatedAt = left.updatedAt
            return left == right
        }
    }

    func refresh() async {
        let activeLifecycle = lifecycle
        await refresh(lifecycle: activeLifecycle)
    }

    /// Marks a chat read through `throughMessageID`.
    ///
    /// The dot and badge clear at once. The marker is then posted to the host
    /// and rolled back if that fails. A host outside the roster (demo) or
    /// without the fleet capability keeps the read on this Mac only, and a chat
    /// already read through that message posts nothing. A roster host still
    /// posts after the index stops observing, because its client is retained.
    func markRead(machineID: String, featureID: String, throughMessageID: String) async {
        let id = FirstMateFleetFeatureID(machineID: machineID, featureID: featureID)
        let host = hosts.first { $0.machineID == machineID }
        let entry = host?.fleetEntries?[featureID]
        if readState.overrides[id] == throughMessageID { return }
        if let entry, !entry.unread, entry.readThroughMessageID == throughMessageID { return }
        readState.markRead(id, messageID: throughMessageID)
        guard let host, host.supportsFleet else { return }
        guard let client = readClients[machineID] else {
            // A fleet host without a client cannot confirm the read, and a dot
            // hidden only here would disagree with every other device.
            readState.rollBack(id, messageID: throughMessageID)
            return
        }
        let expectedLifecycle = lifecycle
        do {
            let response = try await client.markFirstMateRead(featureID: featureID, throughMessageID: throughMessageID)
            // The companion's answer replaces a possibly stale summary, so a
            // newer message the summary had not reported yet clears too.
            guard expectedLifecycle == lifecycle,
                  let index = hosts.firstIndex(where: { $0.machineID == machineID }),
                  var entries = hosts[index].fleetEntries, var current = entries[featureID] else { return }
            current.unread = response.unread
            current.readThroughMessageID = response.readThroughMessageID
            guard current != entries[featureID] else { return }
            entries[featureID] = current
            hosts[index].fleetEntries = entries
            contentRevision &+= 1
        } catch {
            readState.rollBack(id, messageID: throughMessageID)
        }
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
        defer {
            if observedLifecycle == expectedLifecycle { observedLifecycle = nil }
            deactivate(lifecycle: expectedLifecycle)
        }
        guard !sources.isEmpty else { return }
        observedLifecycle = expectedLifecycle
        await refresh(lifecycle: expectedLifecycle)
        let clock = ContinuousClock()
        while isObserving(expectedLifecycle) {
            // Sleep in short steps, so a superseded observer returns promptly
            // to a caller waiting to observe again when this roster stops.
            let deadline = clock.now.advanced(by: pollingInterval)
            while clock.now < deadline {
                do {
                    try await Task.sleep(for: min(Self.supersessionCheckInterval, clock.now.duration(to: deadline)))
                } catch {
                    return
                }
                guard isObserving(expectedLifecycle) else { return }
            }
            await refresh(lifecycle: expectedLifecycle)
        }
    }

    private func isObserving(_ expectedLifecycle: Int) -> Bool {
        !Task.isCancelled && expectedLifecycle == lifecycle
    }
}
