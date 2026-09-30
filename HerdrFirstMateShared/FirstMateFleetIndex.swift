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
    /// Whether the companion advertises `first-mate-lead-v1`: a lead First
    /// Mate conversation across this machine's features.
    var supportsLead: Bool = false
    /// Whether its lead reaches the other machines its companion holds a
    /// credential for (`first-mate-lead-peers-v1`).
    var supportsLeadPeers: Bool = false
    /// The lead's summary (newest message, unread, replying), or nil before it
    /// is first used or when the host has no lead. A failed poll keeps it.
    var lead: FirstMateLeadSummary? = nil
    /// Polls that failed in a row, capped so an outage publishes only its
    /// start. The lead moves to another machine only after more than one
    /// (``FirstMateLeadMachine/offlineAfterFailedPolls``).
    var failedPolls = 0

    var id: String { machineID }
}

@MainActor @Observable
final class FirstMateFleetIndex {
    private struct FetchResult: Sendable {
        let machineID: String
        let features: [FirstMateFeature]?
        let error: String?
        let unsupported: Bool
        /// The capability answer, or nil when no probe ran or it failed. A
        /// 404 or 501 from the fleet route also reads as unsupported.
        var probedFleetSupport: Bool? = nil
        /// Fleet entries, or nil when not requested or the request failed.
        var fleet: [FirstMateFleetEntry]? = nil
        /// The lead capability answer, alongside ``probedFleetSupport``.
        var probedLeadSupport: Bool? = nil
        var probedLeadPeersSupport: Bool? = nil
        /// The lead summary; nil when not requested or the request failed,
        /// `.some(nil)` when the host has no lead yet.
        var lead: FirstMateLeadSummary?? = nil
    }

    private struct CapabilityProbe {
        let supportsFleet: Bool
        var supportsLead = false
        var supportsLeadPeers = false
        let probedAt: Date
    }

    struct ArchiveTarget: Identifiable {
        let machineID: String
        let feature: FirstMateFeature
        fileprivate let lifecycle: Int
        var id: FirstMateFleetFeatureID { .init(machineID: machineID, featureID: feature.id) }
    }

    func archiveTarget(machineID: String, feature: FirstMateFeature) -> ArchiveTarget {
        .init(machineID: machineID, feature: feature, lifecycle: lifecycle)
    }

    /// Route to the captured owner even when the main conversation changes.
    /// Reject old list responses so polling cannot resurrect a just-archived row.
    func archive(_ target: ArchiveTarget, reason: FirstMateArchiveReason?) async -> String? {
        guard target.lifecycle == lifecycle, let client = clients[target.machineID] else {
            return "The connection changed. Reopen Archive on this feature."
        }
        do {
            let capabilities = try await client.fetchFirstMateCapabilities()
            guard target.lifecycle == lifecycle else { return "The connection changed. Reopen Archive on this feature." }
            guard capabilities.ok, capabilities.supportsArchive else {
                return "Update this companion server to archive First Mate features."
            }
            let result = try await client.setFirstMateArchived(featureID: target.feature.id, archived: true,
                                                               reason: reason, requestID: UUID().uuidString)
            guard target.lifecycle == lifecycle else { return "The connection changed. Refresh the feature list to check its archive status." }
            guard result.ok, result.feature.id == target.feature.id, result.feature.isArchived else {
                throw APIError.invalidResponse
            }
            refreshGeneration &+= 1
            for index in hosts.indices { hosts[index].isLoading = false }
            if let index = hosts.firstIndex(where: { $0.machineID == target.machineID }) {
                hosts[index].features.removeAll { $0.id == target.feature.id }
                hosts[index].fleetEntries?[target.feature.id] = nil
                contentRevision &+= 1
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Merge only presentation fields from a successful HUD write. In
    /// particular a stale response must not roll back newer read/status data.
    func applyPresentation(_ entry: FirstMateFleetEntry, machineID: String) {
        guard let index = hosts.firstIndex(where: { $0.machineID == machineID }),
              var current = hosts[index].fleetEntries?[entry.featureID] else { return }
        current.title = entry.title
        current.label = entry.label
        current.labelSource = entry.labelSource
        current.emoji = entry.emoji
        current.emojiSource = entry.emojiSource
        guard current != hosts[index].fleetEntries?[entry.featureID] else { return }
        hosts[index].fleetEntries?[entry.featureID] = current
        contentRevision &+= 1
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
    /// Where ``FirstMateFleetHost/failedPolls`` stops counting.
    static let failedPollsCap = 3
    /// Each observer's wait for its next poll, by lifecycle. A new activation
    /// or a deactivation cancels them, so a superseded observer returns at
    /// once instead of waking periodically to check.
    @ObservationIgnored private var observerSleeps: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored var clock: @MainActor () -> Date = { Date() }

    private struct FailedRead {
        let messageID: String
        let retryAt: Date
        let delay: TimeInterval
    }

    /// Read markers the companion refused or never received, by chat. The
    /// same marker is not posted again before `retryAt`, so a failing
    /// companion is not asked in a loop by the read hooks, which fire again
    /// whenever a rollback makes the chat unread. A newer marker (a new
    /// First Mate message) is posted at once.
    @ObservationIgnored private var failedReads: [FirstMateFleetFeatureID: FailedRead] = [:]
    static let readRetryInitialDelay: TimeInterval = 8
    static let readRetryMaximumDelay: TimeInterval = 180
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
        // New clients deserve a fresh attempt at any refused read.
        failedReads = [:]
        wakeObservers()
        return lifecycle
    }

    func deactivate(lifecycle expectedLifecycle: Int? = nil) {
        if let expectedLifecycle, expectedLifecycle != lifecycle { return }
        lifecycle &+= 1
        refreshGeneration &+= 1
        clients = [:]
        for index in hosts.indices where hosts[index].isLoading { hosts[index].isLoading = false }
        wakeObservers()
    }

    /// Ends every observer's wait; each then sees whether it is still current.
    private func wakeObservers() {
        let sleeps = observerSleeps
        observerSleeps = [:]
        for sleep in sleeps.values { sleep.cancel() }
    }

    func refresh(lifecycle expectedLifecycle: Int) async {
        guard !Task.isCancelled, expectedLifecycle == lifecycle else { return }
        refreshGeneration &+= 1
        let token = refreshGeneration
        let now = clock()
        let requests = hosts.compactMap { host -> (String, any FirstMateClient, CapabilityProbe?)? in
            guard let client = clients[host.machineID] else { return nil }
            // nil asks the host again; a fully supported answer lasts the
            // lifecycle, and a host without the fleet or the lead is asked
            // again after the reprobe interval (a companion upgraded mid-run).
            let known = capabilityProbes[host.machineID].flatMap { probe -> CapabilityProbe? in
                (probe.supportsFleet && probe.supportsLead && probe.supportsLeadPeers)
                    || now.timeIntervalSince(probe.probedAt) < capabilityReprobeInterval
                    ? probe : nil
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
            for (machineID, client, known) in requests {
                group.addTask {
                    // The probe runs alongside the list, so an unreachable
                    // host costs one timeout per round, not two.
                    async let probe = FirstMateFleetIndex.probeCapabilities(client, needed: known == nil)
                    do {
                        let response = try await client.fetchFirstMateFeatures()
                        guard response.ok else { throw APIError.invalidResponse }
                        let probed = await probe
                        try Task.checkCancellation()
                        var result = FetchResult(machineID: machineID, features: response.features, error: nil, unsupported: false)
                        result.probedFleetSupport = probed?.fleet
                        result.probedLeadSupport = probed?.lead
                        result.probedLeadPeersSupport = probed?.leadPeers
                        if probed?.lead ?? known?.supportsLead ?? false {
                            // The lead's small summary: its newest message and
                            // whether it is unread, for the HUD and the window.
                            if let lead = try? await client.fetchFirstMateLead(), lead.ok {
                                result.lead = .some(lead.lead)
                            }
                        }
                        if probed?.fleet ?? known?.supportsFleet ?? false {
                            do {
                                let fleet = try await client.fetchFirstMateFleet()
                                if fleet.ok { result.fleet = fleet.features }
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch APIError.server(let status, _) where status == 404 || status == 501 {
                                // The companion lost the capability (for example a
                                // rollback): fall back to the feature list at once.
                                result.probedFleetSupport = false
                            } catch {
                                // A failed summary keeps the last one, like a failed list.
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
                    host.failedPolls = 0
                    if let probed = result.probedFleetSupport {
                        let lead = result.probedLeadSupport ?? false
                        let peers = result.probedLeadPeersSupport ?? false
                        capabilityProbes[result.machineID] = CapabilityProbe(supportsFleet: probed, supportsLead: lead,
                                                                             supportsLeadPeers: peers, probedAt: now)
                        host.supportsLeadPeers = peers
                        host.supportsFleet = probed
                        host.supportsLead = lead
                    }
                    if !host.supportsLead {
                        host.lead = nil
                    } else if let lead = result.lead, !Self.samePublishedLead(host.lead, lead) {
                        host.lead = lead
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
                    host.failedPolls = min(host.failedPolls + 1, Self.failedPollsCap)
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
            return FirstMatePollPresentation.sameFeature(a, b)
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

    /// Whether the host advertises `first-mate-fleet-v1`,
    /// `first-mate-lead-v1`, and `first-mate-lead-peers-v1`: nil when not `needed`, or when the probe failed
    /// (unknown: the host keeps its last answer and is asked again next time).
    /// A companion without the capability route predates the fleet.
    nonisolated private static func probeCapabilities(_ client: any FirstMateClient, needed: Bool) async -> (fleet: Bool, lead: Bool, leadPeers: Bool)? {
        guard needed else { return nil }
        do {
            let capabilities = try await client.fetchFirstMateCapabilities()
            return (capabilities.ok && capabilities.supportsFleet, capabilities.ok && capabilities.supportsLead,
                    capabilities.ok && capabilities.supportsLeadPeers)
        } catch APIError.server(let status, _) where status == 404 || status == 501 {
            return (false, false, false)
        } catch {
            return nil
        }
    }

    /// The lead's row moves with every Pi telemetry write; only what the HUD
    /// and the window show publishes.
    static func samePublishedLead(_ lhs: FirstMateLeadSummary?, _ rhs: FirstMateLeadSummary?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return lhs.feature.id == rhs.feature.id && lhs.unread == rhs.unread
            && lhs.workingOnReply == rhs.workingOnReply && lhs.latestMessage == rhs.latestMessage
            && lhs.peers == rhs.peers
    }

    /// Records that the lead was read on this Mac once the companion confirms
    /// it, so the HUD's lead dot clears before the next poll.
    func noteLeadRead(machineID: String) {
        guard let index = hosts.firstIndex(where: { $0.machineID == machineID }),
              var lead = hosts[index].lead, lead.unread else { return }
        lead.unread = false
        hosts[index].lead = lead
        contentRevision &+= 1
    }

    /// Posts the lead's read marker and clears its dot once the companion
    /// confirms. A failure leaves it unread for the next poll to settle.
    func markLeadRead(machineID: String, throughMessageID: String) async {
        guard let lead = hosts.first(where: { $0.machineID == machineID })?.lead, lead.unread,
              let client = readClients[machineID] else { return }
        let expectedLifecycle = lifecycle
        guard let response = try? await client.markFirstMateRead(featureID: lead.feature.id, throughMessageID: throughMessageID),
              expectedLifecycle == lifecycle,
              let index = hosts.firstIndex(where: { $0.machineID == machineID }),
              var current = hosts[index].lead, current.feature.id == lead.feature.id,
              current.unread != response.unread else { return }
        current.unread = response.unread
        hosts[index].lead = current
        contentRevision &+= 1
    }

    /// Replaces a host's lead summary after this Mac opened or messaged it.
    func noteLead(_ lead: FirstMateLeadSummary, machineID: String) {
        guard let index = hosts.firstIndex(where: { $0.machineID == machineID }),
              hosts[index].supportsLead, !Self.samePublishedLead(hosts[index].lead, lead) else { return }
        hosts[index].lead = lead
        contentRevision &+= 1
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
    ///
    /// A marker that failed is not posted again until its backoff expires
    /// (8 s, doubling to 3 min), and the chat stays unread meanwhile, so the
    /// dot stays honest and the read hooks do not retry in a loop.
    func markRead(machineID: String, featureID: String, throughMessageID: String) async {
        let id = FirstMateFleetFeatureID(machineID: machineID, featureID: featureID)
        let host = hosts.first { $0.machineID == machineID }
        let entry = host?.fleetEntries?[featureID]
        if readState.overrides[id] == throughMessageID { return }
        if let entry, !entry.unread, entry.readThroughMessageID == throughMessageID { return }
        if let failed = failedReads[id], failed.messageID == throughMessageID, clock() < failed.retryAt { return }
        readState.markRead(id, messageID: throughMessageID)
        guard let host, host.supportsFleet else { return }
        guard let client = readClients[machineID] else {
            // A fleet host without a client cannot confirm the read, and a dot
            // hidden only here would disagree with every other device.
            readState.rollBack(id, messageID: throughMessageID)
            recordFailedRead(id, messageID: throughMessageID)
            return
        }
        let expectedLifecycle = lifecycle
        do {
            let response = try await client.markFirstMateRead(featureID: featureID, throughMessageID: throughMessageID)
            if failedReads[id]?.messageID == throughMessageID { failedReads[id] = nil }
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
            recordFailedRead(id, messageID: throughMessageID)
        }
    }

    /// Starts or doubles the marker's backoff. A different marker starts over.
    private func recordFailedRead(_ id: FirstMateFleetFeatureID, messageID: String) {
        let previous = failedReads[id].flatMap { $0.messageID == messageID ? $0.delay : nil }
        let delay = previous.map { min($0 * 2, Self.readRetryMaximumDelay) } ?? Self.readRetryInitialDelay
        failedReads[id] = FailedRead(messageID: messageID, retryAt: clock().addingTimeInterval(delay), delay: delay)
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
        while isObserving(expectedLifecycle) {
            await sleepUntilNextPoll(expectedLifecycle)
            guard isObserving(expectedLifecycle) else { return }
            await refresh(lifecycle: expectedLifecycle)
        }
    }

    /// One sleep per poll. A newer activation or a deactivation cancels it
    /// (``wakeObservers()``), so a superseded observer returns promptly to a
    /// caller waiting to observe again, and cancelling the observing task
    /// cancels it too.
    private func sleepUntilNextPoll(_ expectedLifecycle: Int) async {
        let interval = pollingInterval
        let sleep = Task { _ = try? await Task.sleep(for: interval) }
        observerSleeps[expectedLifecycle] = sleep
        await withTaskCancellationHandler {
            await sleep.value
        } onCancel: {
            sleep.cancel()
        }
        if observerSleeps[expectedLifecycle] == sleep { observerSleeps[expectedLifecycle] = nil }
    }

    private func isObserving(_ expectedLifecycle: Int) -> Bool {
        !Task.isCancelled && expectedLifecycle == lifecycle
    }
}
