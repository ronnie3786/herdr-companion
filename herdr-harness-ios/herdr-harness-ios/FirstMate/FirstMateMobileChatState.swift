import Foundation
import Observation

/// Mobile-owned read/lead state wraps the mechanically shared index. Mac read
/// behavior is unchanged; every phone operation is fenced to its saved owner.
@MainActor @Observable
final class FirstMateMobileChatState {
    enum Selection: Equatable { case lead, feature(FirstMateFeatureTarget) }
    let index = FirstMateFleetIndex()
    private(set) var selection: Selection?
    private(set) var readState = FirstMateReadState()
    private var leadReadObservations: [FirstMateFleetFeatureID: LeadReadObservation] = [:]
    private(set) var pinnedMachineID: String?
    private(set) var route: FirstMateMobileNavigation?
    private(set) var routingError: String?
    var path: [FirstMateChatRoute] {
        if let route {
            return [.chat(route.target)] + (route.inspector == nil ? [] : [.info(route.target, assignmentID: route.assignmentID)])
        }
        switch selection {
        case .lead: return [.lead]
        case .feature(let target): return [.chat(target)]
        case nil: return []
        }
    }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var sources: [String: FirstMateMobileFleetSource] = [:]
    @ObservationIgnored private var tokens: [String: UUID] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var navigationToken = UUID()
    @ObservationIgnored private var openingLeads: [String: UUID] = [:]
    @ObservationIgnored private var failedReads: [FirstMateFleetFeatureID: FailedRead] = [:]
    @ObservationIgnored private var conversationCache: (hosts: [FirstMateFleetHost], read: FirstMateReadState, rows: [FirstMateConversation])?
    @ObservationIgnored private var rowPresentations: [FirstMateFleetFeatureID: FirstMateConversation] = [:]
    @ObservationIgnored var clock: () -> Date = Date.init
    static let pinnedKey = "herdr.ios.firstMate.lead.pinned"

    private struct LeadReadObservation {
        let messageID: String
        let summaryMessageID: String?
        let coveredAssistantIDs: Set<String>
    }

    private struct FailedRead {
        let messageID: String
        let retryAt: Date
        let delay: TimeInterval
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        pinnedMachineID = defaults.string(forKey: Self.pinnedKey)
    }

    func configure(sources incoming: [FirstMateMobileFleetSource], generation: Int, fleet: FirstMateMobileFleetStore) {
        let unique = incoming.reduce(into: [FirstMateMobileFleetSource]()) { values, source in
            if !values.contains(where: { $0.machine.id == source.machine.id }) { values.append(source) }
        }
        var nextTokens: [String: UUID] = [:]
        for source in unique {
            let id = source.machine.id
            let unchanged = self.generation == generation && sources[id]?.configuration == source.configuration
                && sources[id]?.isDemo == source.isDemo
            nextTokens[id] = unchanged ? tokens[id] ?? UUID() : UUID()
        }
        let retained = Set(nextTokens.keys.filter { nextTokens[$0] == tokens[$0] })
        if !sources.isEmpty, self.generation != generation || retained.count != sources.count
            || Set(nextTokens.keys) != Set(sources.keys) {
            beginNavigation()
        }
        rowPresentations = rowPresentations.filter { retained.contains($0.key.machineID) }
        readState.overrides = readState.overrides.filter { retained.contains($0.key.machineID) }
        leadReadObservations = leadReadObservations.filter { retained.contains($0.key.machineID) }
        failedReads = failedReads.filter { retained.contains($0.key.machineID) }
        openingLeads = openingLeads.filter { retained.contains($0.key) }
        tokens = nextTokens
        sources = Dictionary(uniqueKeysWithValues: unique.map { ($0.machine.id, $0) })
        self.generation = generation
        index.activate(sources: unique.compactMap { source in
            guard !source.isDemo, let configuration = source.configuration, let client = source.client else { return nil }
            return FirstMateFleetSource(machine: source.machine, configuration: configuration, client: client)
        }, connectionGeneration: generation)
        if let target = route?.target, !retained.contains(target.machineID) { route = nil }
        if case .feature(let target) = selection, !retained.contains(target.machineID) { select(nil) }
        for source in unique {
            let id = source.machine.id
            fleet.store(forMachineID: id)?.leadContextProvider = { [weak self, weak fleet] in
                guard let self, let fleet else { return nil }
                return FirstMateLeadMachine.context(hosts: self.hosts(fleet: fleet),
                    machines: fleet.availableMachineIDs.compactMap { self.sources[$0]?.machine }, excluding: id)
            }
        }
    }

    func retire() {
        beginNavigation()
        leadReadObservations = [:]
        rowPresentations = [:]
        index.activate(sources: [], connectionGeneration: generation + 1)
        sources = [:]; tokens = [:]; failedReads = [:]; openingLeads = [:]
        readState = FirstMateReadState(); selection = nil; route = nil
    }

    /// Established synchronously by the app boundary, before bootstrap awaits.
    /// Manual selection uses the same identity; applying a route retains its
    /// own identity instead of accidentally superseding itself.
    @discardableResult
    func beginNavigation() -> UUID {
        navigationToken = UUID()
        routingError = nil
        return navigationToken
    }

    func isCurrentNavigation(_ intent: UUID) -> Bool { navigationToken == intent }

    func select(_ selection: Selection?, navigationIntent: UUID? = nil) {
        if let navigationIntent {
            guard isCurrentNavigation(navigationIntent) else { return }
        } else { beginNavigation() }
        route = nil
        self.selection = selection
    }
    func pin(_ machineID: String?) {
        pinnedMachineID = machineID
        if let machineID { defaults.set(machineID, forKey: Self.pinnedKey) }
        else { defaults.removeObject(forKey: Self.pinnedKey) }
    }

    func hosts(fleet: FirstMateMobileFleetStore) -> [FirstMateFleetHost] {
        fleet.hosts.map { mobile in
            if mobile.isDemo, let store = fleet.store(forMachineID: mobile.machineID) {
                var host = FirstMateChatDemoProjection.host(
                    fleet: FirstMateMobileDemo.chatFleet(forMachineID: mobile.machineID), snapshots: store.snapshots,
                    lastUpdated: mobile.lastUpdated ?? Date(timeIntervalSince1970: 1_900_000_000),
                    machineID: mobile.machineID, machineName: mobile.machineName
                )
                // Keep legacy demo rows during the Phase 1 list transition.
                host.features = store.features
                host.supportsLead = store.leadSupported
                if let lead = store.leadSnapshot {
                    let newest = lead.messages.last(where: \.isConversation)
                    host.lead = .init(feature: lead.feature, unread: newest?.role == "assistant", workingOnReply: false,
                                      latestMessage: newest.map { .init(id: $0.id, role: $0.role, text: $0.text, createdAt: $0.createdAt) })
                }
                return host
            }
            if var host = index.hosts.first(where: { $0.machineID == mobile.machineID }) {
                host.machineName = mobile.machineName
                return host
            }
            return FirstMateFleetHost(machineID: mobile.machineID, machineName: mobile.machineName,
                features: mobile.features.filter { !$0.isArchived }, isLoading: mobile.isLoading,
                error: mobile.error, unsupported: mobile.unsupported, lastUpdated: mobile.lastUpdated)
        }
    }

    func knownPresentation(for target: FirstMateFeatureTarget) -> FirstMateConversation? {
        rowPresentations[.init(machineID: target.machineID, featureID: target.featureID)]
    }

    func conversations(fleet: FirstMateMobileFleetStore) -> [FirstMateConversation] {
        let hosts = hosts(fleet: fleet)
        let rows: [FirstMateConversation]
        if let cache = conversationCache, cache.hosts == hosts, cache.read == readState {
            rows = cache.rows
        } else {
            let leadIDs = Set(hosts.compactMap { host in
                host.lead.map { FirstMateFleetFeatureID(machineID: host.machineID, featureID: $0.feature.id) }
            })
            rows = FirstMateConversationList.build(hosts: hosts, readState: readState).filter { !leadIDs.contains($0.id) }
            conversationCache = (hosts, readState, rows)
            for row in rows { rowPresentations[row.id] = row }
        }
        // Cache only fleet-derived rows. Reading existing stores outside that
        // cache observes local outgoing/snapshot changes immediately, without
        // creating a store per rendered row or retaining a stale pending flag.
        return rows.compactMap { row in
            let store = fleet.store(forMachineID: row.machineID)
            let feature = hosts.first(where: { $0.machineID == row.machineID })?.features.first { $0.id == row.featureID }
            if let cached = store?.snapshots[row.featureID]?.feature, cached.isArchived,
               cached.revision >= (feature?.revision ?? 0) { return nil }
            let pending = FirstMateReplyProgress.isLocalReplyPending(
                outgoing: store?.outgoingMessages(for: row.featureID) ?? [], snapshot: store?.snapshots[row.featureID],
                hostFeatureUpdatedAt: feature?.updatedAt, fleetLatestFirstMateMessageID: row.latestFirstMateMessageID
            )
            return FirstMateReplyProgress.presenting(row, workingOnReply: row.isWorkingOnReply || pending)
        }
    }

    func leadChoice(fleet: FirstMateMobileFleetStore) -> FirstMateLeadMachine.Choice {
        let hosts = hosts(fleet: fleet)
        return FirstMateLeadMachine.choose(capable: FirstMateLeadMachine.capable(hosts: hosts),
            offline: FirstMateLeadMachine.offline(hosts: hosts), pinned: pinnedMachineID, local: nil,
            withConversation: Set(hosts.filter { $0.lead != nil }.map(\.machineID)),
            activeCounts: FirstMateLeadMachine.activeCounts(hosts: hosts))
    }

    func leadIsUnread(machineID: String, fleet: FirstMateMobileFleetStore) -> Bool {
        guard let lead = hosts(fleet: fleet).first(where: { $0.machineID == machineID })?.lead, lead.unread else { return false }
        let id = FirstMateFleetFeatureID(machineID: machineID, featureID: lead.feature.id)
        guard let observation = leadReadObservations[id], readState.overrides[id] == observation.messageID else { return true }
        let messages = fleet.store(forMachineID: machineID)?.snapshots[lead.feature.id]?.messages.filter(\.isConversation) ?? []
        if let assistant = messages.last(where: { $0.role == "assistant" && !FirstMateOutgoingMessage.isLocalID($0.id) }),
           !observation.coveredAssistantIDs.contains(assistant.id) { return true }
        if let latest = lead.latestMessage {
            if latest.role == "assistant" { return !observation.coveredAssistantIDs.contains(latest.id) }
            // A user row is not the assistant read marker. If the summary has
            // advanced to an unseen user row, however, do not assume there
            // was no intervening assistant reply until the snapshot catches up.
            if latest.id != observation.summaryMessageID, !messages.contains(where: { $0.id == latest.id }) { return true }
        }
        return false
    }

    /// Once a successful summary confirms read state, the local observation
    /// must not mask a later unread transition whose latest row is still user U.
    func reconcileLeadReadConfirmations(fleet: FirstMateMobileFleetStore) {
        for host in hosts(fleet: fleet) {
            guard let lead = host.lead, !lead.unread else { continue }
            let id = FirstMateFleetFeatureID(machineID: host.machineID, featureID: lead.feature.id)
            if leadReadObservations[id] != nil { leadReadObservations[id] = nil }
        }
    }

    private func observeLeadRead(_ target: FirstMateFeatureTarget, through messageID: String,
                                 lead: FirstMateLeadSummary, fleet: FirstMateMobileFleetStore) -> LeadReadObservation {
        let messages = fleet.store(for: target)?.snapshots[target.featureID]?.messages.filter(\.isConversation) ?? []
        var covered: Set<String> = [messageID]
        if let through = messages.firstIndex(where: { $0.id == messageID }) {
            covered.formUnion(messages[...through].filter { $0.role == "assistant" && !FirstMateOutgoingMessage.isLocalID($0.id) }.map(\.id))
        }
        return .init(messageID: messageID, summaryMessageID: lead.latestMessage?.id, coveredAssistantIDs: covered)
    }

    private func rollBackRead(_ id: FirstMateFleetFeatureID, messageID: String) {
        readState.rollBack(id, messageID: messageID)
        if leadReadObservations[id]?.messageID == messageID { leadReadObservations[id] = nil }
    }

    /// Optimistic feature and lead markers share phone-owned rollback/backoff.
    /// New replies do not match an old override; stale failures cannot erase a
    /// replacement connection's read or apply backoff to it.
    func markRead(_ target: FirstMateFeatureTarget, through messageID: String, fleet: FirstMateMobileFleetStore) async {
        guard !FirstMateOutgoingMessage.isLocalID(messageID), !messageID.isEmpty,
              let token = tokens[target.machineID], let source = sources[target.machineID],
              let host = hosts(fleet: fleet).first(where: { $0.machineID == target.machineID }), host.supportsFleet else { return }
        let isLead = host.lead?.feature.id == target.featureID
        guard isLead || host.fleetEntries?[target.featureID] != nil else { return }
        let id = FirstMateFleetFeatureID(machineID: target.machineID, featureID: target.featureID)
        guard readState.overrides[id] != messageID else { return }
        if let failed = failedReads[id], failed.messageID == messageID, clock() < failed.retryAt { return }
        if isLead, let lead = host.lead {
            leadReadObservations[id] = observeLeadRead(target, through: messageID, lead: lead, fleet: fleet)
        }
        readState.markRead(id, messageID: messageID)
        if source.isDemo { return }
        do {
            guard let client = source.client else { throw APIError.invalidResponse }
            let response = try await client.markFirstMateRead(featureID: target.featureID, throughMessageID: messageID)
            guard tokens[target.machineID] == token else { return }
            guard response.featureID == target.featureID,
                  let acknowledged = response.readThroughMessageID, !FirstMateOutgoingMessage.isLocalID(acknowledged) else {
                throw APIError.invalidResponse
            }
            if response.unread { rollBackRead(id, messageID: messageID) }
            if failedReads[id]?.messageID == messageID { failedReads[id] = nil }
            // Do not overwrite the index summary: a newer reply may have
            // arrived while this marker was in flight.
        } catch {
            guard tokens[target.machineID] == token, readState.overrides[id] == messageID else { return }
            rollBackRead(id, messageID: messageID)
            let previous = failedReads[id].flatMap { $0.messageID == messageID ? $0.delay : nil }
            let delay = previous.map { min($0 * 2, 180) } ?? 8
            failedReads[id] = .init(messageID: messageID, retryAt: clock().addingTimeInterval(delay), delay: delay)
        }
    }

    /// Ensures an empty lead only on its captured owner. Never resends or
    /// migrates a prompt on failover, and never selects a delayed result over a
    /// newly selected feature or a replaced store.
    func openLead(on machineID: String? = nil, intent suppliedIntent: UUID? = nil, fleet: FirstMateMobileFleetStore,
                  canControl: (String) -> Bool = { _ in false }) async -> FirstMateFeatureTarget? {
        let intent = suppliedIntent ?? beginNavigation()
        guard !Task.isCancelled, isCurrentNavigation(intent) else { return nil }
        selection = .lead
        route = nil
        guard let machineID = machineID ?? leadChoice(fleet: fleet).current,
              let source = sources[machineID], let token = tokens[machineID],
              hosts(fleet: fleet).contains(where: { $0.machineID == machineID && $0.supportsLead }),
              let store = fleet.store(forMachineID: machineID) else { return nil }
        if let snapshot = store.leadSnapshot {
            let target = FirstMateFeatureTarget(machineID: machineID, featureID: snapshot.feature.id)
            return fleet.open(target, navigationIntent: intent) ? target : nil
        }
        guard canControl(machineID), openingLeads[machineID] == nil, let client = source.client else { return nil }
        let operation = UUID(), context = store.operationContext
        openingLeads[machineID] = operation
        defer { if openingLeads[machineID] == operation { openingLeads[machineID] = nil } }
        do {
            let response = try await client.ensureFirstMateLead(requestID: operation.uuidString)
            guard !Task.isCancelled, canControl(machineID), navigationToken == intent,
                  tokens[machineID] == token, selection == .lead,
                  fleet.store(forMachineID: machineID) === store, store.operationContext == context,
                  response.ok, let lead = response.lead, lead.feature.isLead else { return nil }
            let snapshot = try await client.fetchFirstMateFeature(lead.feature.id, journalEventsOnly: store.journalEventSnapshotsSupported)
            guard !Task.isCancelled, canControl(machineID), navigationToken == intent,
                  tokens[machineID] == token, selection == .lead,
                  fleet.store(forMachineID: machineID) === store, store.operationContext == context,
                  snapshot.ok, snapshot.feature.id == lead.feature.id, snapshot.feature.isLead else { return nil }
            store.receive(snapshot)
            index.noteLead(lead, machineID: machineID)
            let target = FirstMateFeatureTarget(machineID: machineID, featureID: lead.feature.id)
            return fleet.open(target, navigationIntent: intent) ? target : nil
        } catch { return nil }
    }

    func navigate(_ request: FirstMateMobileOpenRequest, owner: FirstMateFeatureTarget? = nil, intent suppliedIntent: UUID? = nil,
                  fleet: FirstMateMobileFleetStore, canControl: (String) -> Bool = { _ in false }) async -> Bool {
        let intent = suppliedIntent ?? beginNavigation()
        guard !Task.isCancelled, isCurrentNavigation(intent) else { return false }
        routingError = nil
        let resolution = request.resolve(machines: fleet.availableMachineIDs.compactMap { sources[$0]?.machine },
                                         hosts: hosts(fleet: fleet), owner: owner)
        switch resolution {
        case .failure(let reason): routingError = reason; return false
        case .lead(let machineID):
            let owner = machineID ?? leadChoice(fleet: fleet).current
            let token = owner.flatMap { tokens[$0] }
            let target = await openLead(on: machineID, intent: intent, fleet: fleet, canControl: canControl)
            guard !Task.isCancelled, isCurrentNavigation(intent), owner.flatMap({ tokens[$0] }) == token else { return false }
            guard let target else {
                // Older companions keep the lead selection ready for the
                // briefing screen added by the conversation UI phases.
                return selection == .lead
            }
            route = .init(target: target, assignmentID: nil, inspector: request.inspector, graph: request.graph)
            return true
        case .feature(let target):
            guard let store = fleet.store(for: target), let token = tokens[target.machineID] else { return false }
            let context = store.operationContext
            if sources[target.machineID]?.isDemo != true,
               request.assignmentID != nil || store.snapshots[target.featureID] == nil {
                guard let client = sources[target.machineID]?.client else { return false }
                do {
                    let snapshot = try await client.fetchFirstMateFeature(target.featureID, journalEventsOnly: store.journalEventSnapshotsSupported)
                    guard !Task.isCancelled, navigationToken == intent,
                          tokens[target.machineID] == token, fleet.store(for: target) === store,
                          store.operationContext == context, snapshot.ok, snapshot.feature.id == target.featureID else { return false }
                    if let assignment = request.assignmentID,
                       !snapshot.assignments.contains(where: { $0.id == assignment && $0.featureID == target.featureID }) {
                        routingError = "This agent does not belong to the feature."; return false
                    }
                    store.receive(snapshot)
                } catch {
                    guard !Task.isCancelled, isCurrentNavigation(intent), tokens[target.machineID] == token,
                          fleet.store(for: target) === store, store.operationContext == context else { return false }
                    routingError = "The feature could not be opened on its owning machine."
                    return false
                }
            }
            guard let snapshot = store.snapshots[target.featureID] else { return false }
            if let assignment = request.assignmentID,
               !snapshot.assignments.contains(where: { $0.id == assignment && $0.featureID == target.featureID }) {
                routingError = "This agent does not belong to the feature."; return false
            }
            guard fleet.open(target, navigationIntent: intent) else { return false }
            route = .init(target: target, assignmentID: request.assignmentID,
                          inspector: request.assignmentID == nil ? request.inspector : .agents, graph: request.graph)
            return true
        }
    }
}
