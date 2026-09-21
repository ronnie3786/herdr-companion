import CryptoKit
import Foundation
import Observation

/// Process-owned publication of this Mac's local tab colors.
///
/// The Mac store remains the only authority for its own assignments. This
/// controller copies the *effective* values of currently known machine-scoped
/// tabs to each authenticated companion so agents can read and group them. It
/// never reads server-side color metadata back into a local store, and it is
/// opt-in separately from Allow agent control.
@MainActor @Observable
final class ChatTabColorPublisher {
    typealias TransportFactory = @MainActor (ServerConfiguration) -> any ChatTabColorTransport

    enum DefaultsKey {
        static let sharing = "herdr.chatTabColors.share.v1"
    }

    struct HostState: Identifiable, Equatable, Sendable {
        enum Phase: Equatable, Sendable {
            case idle
            case waitingForConnection
            case publishing
            case shared
            case unsupported
            case pendingClear
            case ambiguous
            case failed
        }

        var id: String { machineID }
        let machineID: String
        var machineName: String
        var serverID: String?
        var phase: Phase
        var detail: String
    }

    private enum Mode: Equatable {
        case publish
        case withdraw
    }

    private struct ConfiguredHost: Sendable {
        let machineID: String
        let machineName: String
        let configuration: ServerConfiguration
        let transport: any ChatTabColorTransport
    }

    private struct HostProbe: Sendable {
        let host: ConfiguredHost
        let serverID: String?
        let supportsPublication: Bool
        let detail: String?
    }

    private struct ServerGroup {
        let serverID: String
        /// Aliases that answered a capabilities probe this cycle.
        var reachableHosts: [ConfiguredHost]
        /// Aliases authenticated for this server earlier in this process whose
        /// probe failed or was backed off this cycle. They still participate
        /// in conflict detection but never own the transport.
        var knownHosts: [ConfiguredHost]
    }

    /// A machine whose endpoint authenticated as this server in the current
    /// process. Retained across probe failures and backoffs so a known alias
    /// is never forgotten while its configuration is unchanged.
    private struct AuthenticatedServer {
        let configuration: ServerConfiguration
        let serverID: String
    }

    private struct Candidate {
        let host: ConfiguredHost
        let isReachable: Bool
        let hasTopology: Bool
        let isTopologyConfirmed: Bool
        let isLive: Bool
        let rows: [ChatTabColorPublicationTab]
    }

    private struct PublicationPlan: Sendable {
        let serverID: String
        let machineIDs: [String]
        let transport: any ChatTabColorTransport
        let recordKey: String
        let clearsSharing: Bool
        let request: ChatTabColorPublicationRequest
    }

    private enum PublicationOutcome: Sendable {
        case success(PublicationPlan, ChatTabColorPublicationResponse)
        case failure(PublicationPlan, String, String?)
    }

    private struct PendingClearGroup {
        let serverID: String
        let hosts: [ConfiguredHost]
    }

    private struct RetryState {
        var failures = 0
        var nextAttempt: ContinuousClock.Instant
    }

    private struct TransportCacheEntry {
        let configuration: ServerConfiguration
        let transport: any ChatTabColorTransport
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let ledgerStore: ChatTabColorPublicationLedgerStore
    @ObservationIgnored private let secretStore: ChatTabColorPublisherSecret
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let heartbeatInterval: TimeInterval
    @ObservationIgnored private let retryBase: Duration
    @ObservationIgnored private let retryMaximum: Duration
    @ObservationIgnored private let allowsPublicationInUnitTests: Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var runGeneration = 0
    @ObservationIgnored private var configuredMode: Mode?
    @ObservationIgnored private var configuredConnectionGeneration: Int?
    @ObservationIgnored private var connectionObservationToken = 0
    @ObservationIgnored private var connectionObservationIsArmed = false
    @ObservationIgnored private var observedConnectionModelID: ObjectIdentifier?
    @ObservationIgnored private var retryStates: [String: RetryState] = [:]
    @ObservationIgnored private var transports: [String: TransportCacheEntry] = [:]
    @ObservationIgnored private var authenticatedServers: [String: AuthenticatedServer] = [:]
    /// Weak so the model that owns this publisher is not retained by it; the
    /// background task already stops when the model goes away.
    @ObservationIgnored private weak var model: HerdrAppModel?
    @ObservationIgnored private var ledger: ChatTabColorPublicationLedger

    /// Test seam matching `HerdrAppModel.clientFactory`: deterministic tests
    /// replace it before starting publication.
    @ObservationIgnored var transportFactory: TransportFactory

    private(set) var hostStates: [HostState] = []
    private(set) var statusText = "Tab color sharing is off"
    private(set) var lastError: String?
    let clientID: String

    var isSharingEnabled: Bool { defaults.bool(forKey: DefaultsKey.sharing) }
    var isPublishing: Bool { runTask != nil }

    /// Persisted per-server records, exposed for deterministic tests and for
    /// diagnostics that must never invent server state.
    var publicationRecords: [String: ChatTabColorPublicationRecord] { ledger.records }

    init(
        defaults: UserDefaults = .standard,
        secretStorage: any AgentControlSecretStorage = KeychainAgentControlSecretStorage(),
        pollInterval: Duration = .seconds(1),
        heartbeatInterval: TimeInterval = ChatTabColorContract.heartbeatSeconds,
        retryBase: Duration = .seconds(1),
        retryMaximum: Duration = .seconds(15),
        allowsPublicationInUnitTests: Bool = false,
        now: @escaping () -> Date = Date.init,
        transportFactory: TransportFactory? = nil
    ) {
        self.defaults = defaults
        ledgerStore = ChatTabColorPublicationLedgerStore(defaults: defaults)
        ledger = ledgerStore.load()
        secretStore = ChatTabColorPublisherSecret(storage: secretStorage)
        let identities = AgentControlIdentityStore(defaults: defaults, storage: secretStorage)
        clientID = identities.clientID()
        self.pollInterval = pollInterval
        self.heartbeatInterval = heartbeatInterval
        self.retryBase = retryBase
        self.retryMaximum = retryMaximum
        self.allowsPublicationInUnitTests = allowsPublicationInUnitTests
        self.now = now
        self.transportFactory = transportFactory ?? { LiveChatTabColorTransport(configuration: $0) }
    }

    deinit {
        runTask?.cancel()
    }

    /// Binds the publisher to the app model. Called by the process-owned
    /// connection driver so a closed window cannot stop sharing.
    func configure(model: HerdrAppModel) {
        self.model = model
        ensureConnectionObservation()
        synchronize()
    }

    func setSharingEnabled(_ enabled: Bool) {
        guard enabled != isSharingEnabled else { return }
        defaults.set(enabled, forKey: DefaultsKey.sharing)
        if enabled { ensureConnectionObservation() }
        synchronize(forceRestart: true)
    }

    func synchronize(forceRestart: Bool = false) {
        guard let model else { return }
        let mode: Mode?
        if isSharingEnabled {
            mode = .publish
        } else if hasPendingClears(model: model) {
            mode = .withdraw
        } else {
            mode = nil
        }
        guard let mode else {
            stop(status: "Tab color sharing is off", stopObserving: true)
            return
        }
        guard !model.isDemoMode else {
            stop(status: "Tab color sharing is unavailable in demo mode", stopObserving: false)
            return
        }
        guard !Self.isUnitTestProcess || allowsPublicationInUnitTests else {
            stop(status: "Tab color sharing networking is disabled in tests", stopObserving: false)
            return
        }
        guard !(Self.isUnitTestProcess && secretStore.usesLiveKeychain) else {
            stop(status: "Tab color sharing credentials are disabled in tests", stopObserving: false)
            return
        }
        ensureConnectionObservation()
        guard forceRestart
            || runTask == nil
            || configuredMode != mode
            || configuredConnectionGeneration != model.connectionGeneration
        else { return }
        restart(mode: mode, generation: model.connectionGeneration)
    }

    /// Observation stays armed while sharing or clearing is possible so a
    /// connection edit restarts publication even with no window open.
    private func ensureConnectionObservation() {
        guard let model else {
            stopConnectionObservation()
            return
        }
        let modelID = ObjectIdentifier(model)
        if observedConnectionModelID != modelID {
            stopConnectionObservation()
            observedConnectionModelID = modelID
        }
        guard !connectionObservationIsArmed else { return }
        connectionObservationToken &+= 1
        let token = connectionObservationToken
        connectionObservationIsArmed = true
        withObservationTracking {
            _ = model.connectionGeneration
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.connectionObservationToken == token else { return }
                self.connectionObservationIsArmed = false
                self.synchronize()
            }
        }
    }

    private func stopConnectionObservation() {
        connectionObservationToken &+= 1
        connectionObservationIsArmed = false
        observedConnectionModelID = nil
    }

    private func stop(status: String, stopObserving: Bool) {
        if stopObserving { stopConnectionObservation() }
        runTask?.cancel()
        runTask = nil
        runGeneration &+= 1
        configuredMode = nil
        configuredConnectionGeneration = nil
        retryStates = [:]
        hostStates = []
        lastError = nil
        statusText = status
    }

    private func restart(mode: Mode, generation: Int) {
        runTask?.cancel()
        runGeneration &+= 1
        let runGeneration = self.runGeneration
        configuredMode = mode
        configuredConnectionGeneration = generation
        retryStates = [:]
        lastError = nil
        statusText = mode == .publish ? "Sharing tab colors…" : "Clearing shared tab colors…"
        if mode == .publish { refreshHostPlaceholders() }
        runTask = Task { [weak self] in
            guard let self else { return }
            switch mode {
            case .publish:
                await self.runPublish(generation: generation, runGeneration: runGeneration)
            case .withdraw:
                await self.runWithdraw(generation: generation, runGeneration: runGeneration)
            }
        }
    }

    private func isCurrent(generation: Int, runGeneration: Int) -> Bool {
        guard !Task.isCancelled, runGeneration == self.runGeneration else { return false }
        guard let model, model.connectionGeneration == generation else { return false }
        switch configuredMode {
        case .publish: return isSharingEnabled
        case .withdraw: return !isSharingEnabled
        case nil: return false
        }
    }

    private func configuredHosts(model: HerdrAppModel?) -> [ConfiguredHost] {
        guard let model, !model.isDemoMode else {
            transports = [:]
            return []
        }
        var nextTransports: [String: TransportCacheEntry] = [:]
        defer { transports = nextTransports }
        return model.machines.compactMap { machine in
            guard let configuration = model.firstMateConfiguration(machineID: machine.id),
                  !configuration.token.isEmpty
            else { return nil }
            let transport: any ChatTabColorTransport
            if let cached = transports[machine.id], cached.configuration == configuration {
                transport = cached.transport
            } else {
                transport = transportFactory(configuration)
            }
            nextTransports[machine.id] = TransportCacheEntry(
                configuration: configuration,
                transport: transport
            )
            return ConfiguredHost(
                machineID: machine.id,
                machineName: machine.name,
                configuration: configuration,
                transport: transport
            )
        }
    }

    private func hasPendingClears(model: HerdrAppModel) -> Bool {
        let configured = Set(model.machines.map(\.id))
        return ledger.serverIDsByMachine.contains { machineID, serverID in
            guard configured.contains(machineID),
                  let record = ledger.records[recordKey(serverID: serverID)]
            else { return false }
            return record.pendingClear || record.enabled
        }
    }

    private func recordKey(serverID: String) -> String {
        "\(clientID)|\(serverID)"
    }

    // MARK: - Ordinary publication

    private func runPublish(generation: Int, runGeneration: Int) async {
        while isCurrent(generation: generation, runGeneration: runGeneration) {
            let hosts = configuredHosts(model: model)
            if hosts.isEmpty {
                hostStates = []
                statusText = "No authenticated companion is configured"
                if !(await sleepCurrent(pollInterval, generation: generation, runGeneration: runGeneration)) {
                    return
                }
                continue
            }
            await publishCycle(hosts: hosts, generation: generation, runGeneration: runGeneration)
            if !(await sleepCurrent(pollInterval, generation: generation, runGeneration: runGeneration)) {
                return
            }
        }
    }

    @discardableResult
    private func sleepCurrent(_ duration: Duration, generation: Int, runGeneration: Int) async -> Bool {
        do {
            try await Task.sleep(for: duration)
        } catch {
            return false
        }
        return isCurrent(generation: generation, runGeneration: runGeneration)
    }

    private func publishCycle(hosts: [ConfiguredHost], generation: Int, runGeneration: Int) async {
        let clockNow = ContinuousClock.now
        let attempted = hosts.filter { host in
            guard let retry = retryStates["probe|\(host.machineID)"] else { return true }
            return retry.nextAttempt <= clockNow
        }
        guard !attempted.isEmpty else { return }

        let probes = await withTaskGroup(of: HostProbe.self) { group -> [HostProbe] in
            for host in attempted {
                group.addTask {
                    do {
                        let capability = try await host.transport.capabilities()
                        guard capability.ok, capability.version == 1,
                              Self.isSafeServerID(capability.serverId) else {
                            return HostProbe(
                                host: host,
                                serverID: nil,
                                supportsPublication: false,
                                detail: "The companion returned an unsupported capabilities response."
                            )
                        }
                        guard capability.capabilities.contains(ChatTabColorContract.capability) else {
                            return HostProbe(
                                host: host,
                                serverID: capability.serverId,
                                supportsPublication: false,
                                detail: "Update this companion to share tab colors."
                            )
                        }
                        return HostProbe(
                            host: host,
                            serverID: capability.serverId,
                            supportsPublication: true,
                            detail: nil
                        )
                    } catch {
                        return HostProbe(
                            host: host,
                            serverID: nil,
                            supportsPublication: false,
                            detail: error.localizedDescription
                        )
                    }
                }
            }
            var fetched: [HostProbe] = []
            for await probe in group { fetched.append(probe) }
            return fetched
        }
        guard isCurrent(generation: generation, runGeneration: runGeneration) else { return }

        // Keep only associations whose machine and endpoint are still the ones
        // that authenticated. Everything else is re-established by a probe or
        // deliberately forgotten after a configuration change.
        let configuredByMachine = Dictionary(
            uniqueKeysWithValues: hosts.map { ($0.machineID, $0) }
        )
        authenticatedServers = authenticatedServers.filter { entry in
            guard let host = configuredByMachine[entry.key] else { return false }
            return host.configuration == entry.value.configuration
        }

        var groups: [String: ServerGroup] = [:]
        for probe in probes {
            let probeKey = "probe|\(probe.host.machineID)"
            if let serverID = probe.serverID {
                retryStates[probeKey] = nil
                authenticatedServers[probe.host.machineID] = AuthenticatedServer(
                    configuration: probe.host.configuration,
                    serverID: serverID
                )
                ledger.serverIDsByMachine[probe.host.machineID] = serverID
                if probe.supportsPublication {
                    groups[serverID, default: ServerGroup(
                        serverID: serverID,
                        reachableHosts: [],
                        knownHosts: []
                    )]
                    .reachableHosts.append(probe.host)
                    setHostState(
                        probe.host,
                        serverID: serverID,
                        phase: .publishing,
                        detail: "Publishing…"
                    )
                } else {
                    setHostState(
                        probe.host,
                        serverID: serverID,
                        phase: .unsupported,
                        detail: probe.detail ?? "The companion does not support tab color sharing."
                    )
                }
            } else {
                noteFailure(key: probeKey)
                setHostState(
                    probe.host,
                    serverID: nil,
                    phase: .failed,
                    detail: probe.detail ?? "The companion is unavailable."
                )
                if lastError == nil { lastError = probe.detail }
            }
        }
        ledgerStore.save(ledger)
        guard isCurrent(generation: generation, runGeneration: runGeneration) else { return }

        // A previously authenticated alias that stopped answering still belongs
        // to its server: include it so conflicting local assignments cannot be
        // overwritten just because only one alias is reachable right now.
        for host in hosts {
            guard let entry = authenticatedServers[host.machineID],
                  entry.configuration == host.configuration,
                  var group = groups[entry.serverID],
                  !group.reachableHosts.contains(where: { $0.machineID == host.machineID }),
                  !group.knownHosts.contains(where: { $0.machineID == host.machineID })
            else { continue }
            group.knownHosts.append(host)
            groups[entry.serverID] = group
        }

        var plans: [PublicationPlan] = []
        for (_, group) in groups.sorted(by: { $0.key < $1.key }) {
            // Honor the publication retry deadline recorded after a failure so
            // an unreachable or rejecting companion is not retried every poll.
            if let retry = retryStates["server|\(group.serverID)"], retry.nextAttempt > clockNow {
                continue
            }
            if let plan = makePlan(group: group) { plans.append(plan) }
        }
        guard !plans.isEmpty else {
            updateAggregateStatus()
            return
        }
        // Revisions are persisted before the request leaves the process so a
        // crash or relaunch can never resend an older value under a newer one.
        ledgerStore.save(ledger)

        let clientID = self.clientID
        let outcomes = await withTaskGroup(of: PublicationOutcome.self) { group -> [PublicationOutcome] in
            for plan in plans {
                group.addTask {
                    do {
                        let response = try await plan.transport.publish(
                            clientId: clientID,
                            request: plan.request
                        )
                        return .success(plan, response)
                    } catch {
                        return .failure(plan, error.localizedDescription, (error as? AgentControlCommandError)?.code)
                    }
                }
            }
            var fetched: [PublicationOutcome] = []
            for await outcome in group { fetched.append(outcome) }
            return fetched
        }
        guard isCurrent(generation: generation, runGeneration: runGeneration) else { return }

        var sawFailure = false
        for outcome in outcomes {
            if case .failure = outcome { sawFailure = true }
            apply(outcome)
        }
        ledgerStore.save(ledger)
        if !sawFailure { lastError = nil }
        updateAggregateStatus()
    }

    private func makePlan(group: ServerGroup) -> PublicationPlan? {
        guard let model else { return nil }
        let reachableIDs = Set(group.reachableHosts.map(\.machineID))
        let candidates = (group.reachableHosts + group.knownHosts).map { host -> Candidate in
            let workspaces = model.workspaces.filter { $0.machineID == host.machineID }
            return Candidate(
                host: host,
                isReachable: reachableIDs.contains(host.machineID),
                hasTopology: !workspaces.isEmpty,
                isTopologyConfirmed: model.topologyIsConfirmed(
                    machineID: host.machineID,
                    configuration: host.configuration
                ),
                isLive: model.canControl(machineID: host.machineID),
                rows: rows(for: host.machineID, workspaces: workspaces, store: model.chatTabColors)
            )
        }
        // Cached workspaces may belong to the endpoint this machine used
        // before a settings edit. A successful refresh for the current
        // configuration is required before any tab ID or label is exported.
        guard !candidates.isEmpty,
              candidates.allSatisfy(\.isTopologyConfirmed) else {
            for candidate in candidates {
                setHostState(
                    candidate.host,
                    serverID: group.serverID,
                    phase: .waitingForConnection,
                    detail: "Waiting for a fresh topology read."
                )
            }
            return nil
        }
        // The transport must come from an alias that answered this cycle, but
        // conflict detection covers every alias already authenticated for the
        // server, including ones that are offline or backed off right now.
        guard let chosen = candidates.first(where: { $0.isReachable && $0.isLive }) else {
            for candidate in candidates {
                setHostState(
                    candidate.host,
                    serverID: group.serverID,
                    phase: .waitingForConnection,
                    detail: "Waiting for a live connection."
                )
            }
            return nil
        }
        // Duplicate aliases can point at one companion server. When their
        // locally scoped assignments disagree, never pick one by order: report
        // the conflict and leave the server's last known values untouched.
        let conflict = candidates.contains { $0.hasTopology && $0.rows != chosen.rows }
        if conflict {
            for candidate in candidates {
                setHostState(
                    candidate.host,
                    serverID: group.serverID,
                    phase: .ambiguous,
                    detail: "Duplicate aliases for this companion disagree; publication is paused."
                )
            }
            lastError = "Two configured machines point at one companion with different tab colors. Sharing for that companion is paused."
            return nil
        }

        let key = recordKey(serverID: group.serverID)
        var record = ledger.records[key] ?? ChatTabColorPublicationRecord()
        let fingerprint = Self.fingerprint(chosen.rows)
        let confirmedAt = record.lastPublishedAt ?? .distantPast
        if record.enabled, record.fingerprint == fingerprint,
           now().timeIntervalSince(confirmedAt) < heartbeatInterval {
            for candidate in candidates {
                setHostState(
                    candidate.host,
                    serverID: group.serverID,
                    phase: .shared,
                    detail: "Shared revision \(record.revision)."
                )
            }
            return nil
        }

        let token: String
        do {
            token = try secretStore.token(serverID: group.serverID, clientID: clientID)
        } catch {
            for candidate in candidates {
                setHostState(
                    candidate.host,
                    serverID: group.serverID,
                    phase: .failed,
                    detail: error.localizedDescription
                )
            }
            lastError = error.localizedDescription
            return nil
        }

        let isHeartbeat = record.enabled && record.fingerprint == fingerprint
        if !isHeartbeat {
            record.revision += 1
            record.fingerprint = nil
            record.enabled = true
            record.pendingClear = false
            ledger.records[key] = record
        }
        for candidate in candidates {
            setHostState(
                candidate.host,
                serverID: group.serverID,
                phase: .publishing,
                detail: "Publishing…"
            )
        }
        return PublicationPlan(
            serverID: group.serverID,
            machineIDs: candidates.map(\.host.machineID),
            transport: chosen.host.transport,
            recordKey: key,
            clearsSharing: false,
            request: ChatTabColorPublicationRequest(
                serverId: group.serverID,
                publisherToken: token,
                platform: ChatTabColorContract.platform,
                clientName: ChatTabColorContract.clientName,
                enabled: true,
                revision: record.revision,
                tabs: chosen.rows
            )
        )
    }

    private func apply(_ outcome: PublicationOutcome) {
        switch outcome {
        case let .success(plan, response):
            do {
                try Self.validate(plan: plan, response: response, clientID: clientID)
            } catch {
                noteFailure(key: "server|\(plan.serverID)")
                setHosts(
                    machineIDs: plan.machineIDs,
                    serverID: plan.serverID,
                    phase: .failed,
                    detail: error.localizedDescription
                )
                lastError = error.localizedDescription
                return
            }
            retryStates["server|\(plan.serverID)"] = nil
            var record = ledger.records[plan.recordKey] ?? ChatTabColorPublicationRecord()
            record.revision = plan.request.revision
            record.enabled = plan.request.enabled
            record.fingerprint = plan.clearsSharing ? nil : Self.fingerprint(plan.request.tabs)
            record.pendingClear = false
            record.lastPublishedAt = now()
            ledger.records[plan.recordKey] = record
            setHosts(
                machineIDs: plan.machineIDs,
                serverID: plan.serverID,
                phase: .shared,
                detail: plan.clearsSharing
                    ? "Shared colors were cleared for this companion."
                    : "Shared revision \(record.revision)."
            )
        case let .failure(plan, message, errorCode):
            if Self.isRevisionRecoveryCode(errorCode) {
                // The server holds newer or divergent state for this
                // installation. Burn a strictly higher revision so the next
                // attempt replaces it; never lower or erase server metadata.
                var record = ledger.records[plan.recordKey] ?? ChatTabColorPublicationRecord()
                record.revision = max(record.revision + 1, Int(now().timeIntervalSince1970))
                record.fingerprint = nil
                ledger.records[plan.recordKey] = record
            }
            noteFailure(key: "server|\(plan.serverID)")
            setHosts(
                machineIDs: plan.machineIDs,
                serverID: plan.serverID,
                phase: .failed,
                detail: message
            )
            lastError = message
        }
    }

    private static func validate(
        plan: PublicationPlan,
        response: ChatTabColorPublicationResponse,
        clientID: String
    ) throws {
        guard response.ok,
              response.serverId == plan.serverID,
              response.publication.clientId == clientID,
              response.publication.revision == plan.request.revision,
              response.publication.enabled == plan.request.enabled
        else {
            throw ChatTabColorPublisherError.mismatchedResponse
        }
    }

    nonisolated static func isRevisionRecoveryCode(_ code: String?) -> Bool {
        code == "publication_conflict" || code == "stale_publication_revision"
    }

    // MARK: - Withdrawal

    private func runWithdraw(generation: Int, runGeneration: Int) async {
        while isCurrent(generation: generation, runGeneration: runGeneration) {
            guard let model else { return }
            let groups = pendingClearGroups(model: model)
            if groups.isEmpty {
                finishWithdrawal(runGeneration: runGeneration)
                return
            }
            let clockNow = ContinuousClock.now
            for group in groups {
                guard isCurrent(generation: generation, runGeneration: runGeneration) else { return }
                var lastFailure: String?
                var cleared = false
                for host in group.hosts {
                    guard isCurrent(generation: generation, runGeneration: runGeneration) else { return }
                    let probeKey = "probe|\(host.machineID)"
                    if let retry = retryStates[probeKey], retry.nextAttempt > clockNow { continue }
                    do {
                        let capability = try await host.transport.capabilities()
                        guard isCurrent(generation: generation, runGeneration: runGeneration) else { return }
                        guard capability.ok, capability.version == 1,
                              capability.capabilities.contains(ChatTabColorContract.capability) else {
                            noteFailure(key: probeKey)
                            lastFailure = "Update this companion to clear shared tab colors."
                            setHostState(
                                host,
                                serverID: group.serverID,
                                phase: .unsupported,
                                detail: "Update this companion to clear shared tab colors."
                            )
                            continue
                        }
                        guard capability.serverId == group.serverID else {
                            noteFailure(key: probeKey)
                            lastFailure = ChatTabColorPublisherError.companionIdentityChanged.localizedDescription
                            setHostState(
                                host,
                                serverID: group.serverID,
                                phase: .pendingClear,
                                detail: "The companion identity changed; the pending clear was retained."
                            )
                            continue
                        }
                        retryStates[probeKey] = nil
                        let token = try secretStore.token(
                            serverID: group.serverID,
                            clientID: clientID
                        )
                        let key = recordKey(serverID: group.serverID)
                        var record = ledger.records[key] ?? ChatTabColorPublicationRecord()
                        record.revision += 1
                        record.enabled = false
                        record.pendingClear = true
                        record.fingerprint = nil
                        ledger.records[key] = record
                        ledgerStore.save(ledger)

                        let request = ChatTabColorPublicationRequest(
                            serverId: group.serverID,
                            publisherToken: token,
                            platform: ChatTabColorContract.platform,
                            clientName: ChatTabColorContract.clientName,
                            enabled: false,
                            revision: record.revision,
                            tabs: []
                        )
                        let response = try await host.transport.publish(
                            clientId: clientID,
                            request: request
                        )
                        guard isCurrent(generation: generation, runGeneration: runGeneration) else { return }
                        guard response.ok,
                              response.serverId == group.serverID,
                              response.publication.clientId == clientID,
                              response.publication.revision == request.revision,
                              !response.publication.enabled else {
                            throw ChatTabColorPublisherError.mismatchedResponse
                        }
                        record.enabled = false
                        record.pendingClear = false
                        record.lastPublishedAt = now()
                        ledger.records[key] = record
                        ledgerStore.save(ledger)
                        for alias in group.hosts {
                            setHostState(
                                alias,
                                serverID: group.serverID,
                                phase: .idle,
                                detail: "Shared colors were cleared for this companion."
                            )
                        }
                        cleared = true
                        break
                    } catch is CancellationError {
                        return
                    } catch {
                        noteFailure(key: probeKey)
                        // Persist the intent explicitly so a relaunch while the
                        // companion is offline still retries the clear rather than
                        // inferring it from an old enabled record. A stale or
                        // conflicting revision is recovered with a strictly higher
                        // revision; server metadata is never lowered.
                        let key = recordKey(serverID: group.serverID)
                        var pendingRecord = ledger.records[key] ?? ChatTabColorPublicationRecord()
                        if Self.isRevisionRecoveryCode((error as? AgentControlCommandError)?.code) {
                            pendingRecord.revision = max(pendingRecord.revision + 1, Int(now().timeIntervalSince1970))
                        }
                        pendingRecord.pendingClear = true
                        ledger.records[key] = pendingRecord
                        ledgerStore.save(ledger)
                        lastFailure = error.localizedDescription
                        setHostState(
                            host,
                            serverID: group.serverID,
                            phase: .pendingClear,
                            detail: "Clearing is pending until this companion is reachable."
                        )
                    }
                }
                if !cleared, let lastFailure {
                    lastError = lastFailure
                }
            }
            updateAggregateStatus()
            if !(await sleepCurrent(pollInterval, generation: generation, runGeneration: runGeneration)) {
                return
            }
        }
    }

    private func pendingClearGroups(model: HerdrAppModel) -> [PendingClearGroup] {
        var order: [String] = []
        var grouped: [String: [ConfiguredHost]] = [:]
        for host in configuredHosts(model: model) {
            guard let serverID = ledger.serverIDsByMachine[host.machineID],
                  let record = ledger.records[recordKey(serverID: serverID)],
                  record.pendingClear || record.enabled
            else { continue }
            if grouped[serverID] == nil { order.append(serverID) }
            grouped[serverID, default: []].append(host)
        }
        return order.map { PendingClearGroup(serverID: $0, hosts: grouped[$0] ?? []) }
    }

    private func finishWithdrawal(runGeneration: Int) {
        guard runGeneration == self.runGeneration else { return }
        runTask = nil
        configuredMode = nil
        configuredConnectionGeneration = nil
        retryStates = [:]
        hostStates = []
        lastError = nil
        statusText = "Tab color sharing is off"
    }

    // MARK: - Status

    private func refreshHostPlaceholders() {
        guard let model else {
            hostStates = []
            return
        }
        var existing: [String: HostState] = [:]
        for state in hostStates { existing[state.machineID] = state }
        hostStates = model.machines.map { machine in
            if var state = existing[machine.id] {
                state.machineName = machine.name
                return state
            }
            let serverID = ledger.serverIDsByMachine[machine.id]
            var record: ChatTabColorPublicationRecord?
            if let serverID {
                record = ledger.records[recordKey(serverID: serverID)]
            }
            let detail: String
            let phase: HostState.Phase
            if let record, record.pendingClear {
                phase = .pendingClear
                detail = "Clearing is pending until this companion is reachable."
            } else {
                phase = .idle
                detail = "Not shared yet"
            }
            return HostState(
                machineID: machine.id,
                machineName: machine.name,
                serverID: serverID,
                phase: phase,
                detail: detail
            )
        }
    }

    private func setHostState(
        _ host: ConfiguredHost,
        serverID: String?,
        phase: HostState.Phase,
        detail: String
    ) {
        setHostState(
            machineID: host.machineID,
            machineName: host.machineName,
            serverID: serverID,
            phase: phase,
            detail: detail
        )
    }

    private func setHostState(
        machineID: String,
        machineName: String,
        serverID: String?,
        phase: HostState.Phase,
        detail: String
    ) {
        if let index = hostStates.firstIndex(where: { $0.machineID == machineID }) {
            hostStates[index].machineName = machineName
            if let serverID { hostStates[index].serverID = serverID }
            hostStates[index].phase = phase
            hostStates[index].detail = detail
        } else {
            hostStates.append(
                HostState(
                    machineID: machineID,
                    machineName: machineName,
                    serverID: serverID,
                    phase: phase,
                    detail: detail
                )
            )
        }
    }

    private func setHosts(
        machineIDs: [String],
        serverID: String,
        phase: HostState.Phase,
        detail: String
    ) {
        for machineID in machineIDs {
            let name = model?.machines.first { $0.id == machineID }?.name ?? machineID
            setHostState(
                machineID: machineID,
                machineName: name,
                serverID: serverID,
                phase: phase,
                detail: detail
            )
        }
    }

    private func updateAggregateStatus() {
        if configuredMode == .withdraw || !isSharingEnabled {
            let pending = hostStates.count { $0.phase == .pendingClear }
            statusText = pending > 0
                ? "Waiting to clear \(pending) companion\(pending == 1 ? "" : "s")"
                : "Tab color sharing is off"
            return
        }
        let shared = hostStates.count { $0.phase == .shared }
        statusText = shared > 0
            ? "Sharing with \(shared) companion\(shared == 1 ? "" : "s")"
            : "Sharing tab colors…"
    }

    private func noteFailure(key: String) {
        var state = retryStates[key]
            ?? RetryState(failures: 0, nextAttempt: ContinuousClock.now)
        state.failures += 1
        var delay = retryBase
        for _ in 1..<min(state.failures, 8) {
            delay = min(delay * 2, retryMaximum)
        }
        state.nextAttempt = ContinuousClock.now.advanced(by: delay)
        retryStates[key] = state
    }

    // MARK: - Row export

    /// Every currently known tab of one machine, including explicitly
    /// unassigned tabs, resolved through the existing local store readers.
    func rows(
        for machineID: String,
        workspaces: [HerdrWorkspace],
        store: ChatTabColorStore
    ) -> [ChatTabColorPublicationTab] {
        var rows: [ChatTabColorPublicationTab] = []
        var seen = Set<String>()
        for workspace in workspaces {
            var identities: [(workspaceID: String, tabID: String, scopedTabID: String)] = []
            for tab in workspace.tabs {
                identities.append((
                    workspace.workspaceID,
                    tab.tabID,
                    Self.scopedTabID(
                        rawTabID: tab.tabID,
                        tabMachineID: tab.machineID,
                        workspaceMachineID: workspace.machineID,
                        fallbackMachineID: machineID
                    )
                ))
            }
            for pane in workspace.panes {
                identities.append((
                    workspace.workspaceID,
                    pane.tabID,
                    Self.scopedTabID(
                        rawTabID: pane.tabID,
                        tabMachineID: pane.machineID,
                        workspaceMachineID: workspace.machineID,
                        fallbackMachineID: machineID
                    )
                ))
            }
            for identity in identities {
                let key = "\(identity.workspaceID)|\(identity.tabID)"
                guard seen.insert(key).inserted else { continue }
                let color = store.color(for: identity.scopedTabID)
                rows.append(
                    ChatTabColorPublicationTab(
                        workspaceId: identity.workspaceID,
                        tabId: identity.tabID,
                        color: color?.rawValue,
                        label: color.map { store.label(for: $0) }
                    )
                )
            }
        }
        return rows.sorted { lhs, rhs in
            if lhs.workspaceId != rhs.workspaceId { return lhs.workspaceId < rhs.workspaceId }
            return lhs.tabId < rhs.tabId
        }
    }

    nonisolated static func scopedTabID(
        rawTabID: String,
        tabMachineID: String,
        workspaceMachineID: String,
        fallbackMachineID: String
    ) -> String {
        if !tabMachineID.isEmpty {
            return MachineScopedID.compose(machineID: tabMachineID, rawID: rawTabID)
        }
        let machineID = workspaceMachineID.isEmpty ? fallbackMachineID : workspaceMachineID
        guard !machineID.isEmpty else { return rawTabID }
        return MachineScopedID.compose(machineID: machineID, rawID: rawTabID)
    }

    nonisolated static func fingerprint(_ rows: [ChatTabColorPublicationTab]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(rows) else { return "unencodable" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func isSafeServerID(_ value: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_:"))
        return value.hasPrefix("srv_") && value.count <= 128
            && value.unicodeScalars.allSatisfy(allowed.contains)
    }

    #if DEBUG
    var hasRunTaskForTesting: Bool { runTask != nil }
    var configuredModeForTesting: String {
        switch configuredMode {
        case .publish: "publish"
        case .withdraw: "withdraw"
        case nil: "none"
        }
    }
    func stopForTesting() { stop(status: "Stopped by test", stopObserving: true) }
    #endif

    private static var isUnitTestProcess: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}

enum ChatTabColorPublisherError: LocalizedError, Sendable {
    case mismatchedResponse
    case companionIdentityChanged

    var errorDescription: String? {
        switch self {
        case .mismatchedResponse:
            "The companion returned a mismatched tab color response."
        case .companionIdentityChanged:
            "The companion's authenticated identity changed; the pending clear was retained."
        }
    }
}

