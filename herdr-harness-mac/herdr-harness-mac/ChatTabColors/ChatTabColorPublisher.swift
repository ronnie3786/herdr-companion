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
        var hosts: [ConfiguredHost]
    }

    private struct Candidate {
        let host: ConfiguredHost
        let hasTopology: Bool
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

    private struct PendingClear {
        let host: ConfiguredHost
        let serverID: String
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

        var groups: [String: ServerGroup] = [:]
        for probe in probes {
            let probeKey = "probe|\(probe.host.machineID)"
            if let serverID = probe.serverID, probe.supportsPublication {
                retryStates[probeKey] = nil
                ledger.serverIDsByMachine[probe.host.machineID] = serverID
                groups[serverID, default: ServerGroup(serverID: serverID, hosts: [])]
                    .hosts.append(probe.host)
                setHostState(
                    probe.host,
                    serverID: serverID,
                    phase: .publishing,
                    detail: "Publishing…"
                )
            } else if let serverID = probe.serverID {
                retryStates[probeKey] = nil
                setHostState(
                    probe.host,
                    serverID: serverID,
                    phase: .unsupported,
                    detail: probe.detail ?? "The companion does not support tab color sharing."
                )
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

        var plans: [PublicationPlan] = []
        for (_, group) in groups.sorted(by: { $0.key < $1.key }) {
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
        let candidates = group.hosts.map { host -> Candidate in
            let workspaces = model.workspaces.filter { $0.machineID == host.machineID }
            return Candidate(
                host: host,
                hasTopology: !workspaces.isEmpty,
                isLive: model.canControl(machineID: host.machineID),
                rows: rows(for: host.machineID, workspaces: workspaces, store: model.chatTabColors)
            )
        }
        guard let chosen = candidates.first(where: { $0.isLive }) else {
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
        let conflict = candidates.contains { $0.isLive && $0.rows != chosen.rows }
            || candidates.contains { $0.hasTopology && $0.rows != chosen.rows }
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
            transport: group.hosts[0].transport,
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
            let pending = pendingClearHosts(model: model)
            if pending.isEmpty {
                finishWithdrawal(runGeneration: runGeneration)
                return
            }
            let clockNow = ContinuousClock.now
            for item in pending {
                guard isCurrent(generation: generation, runGeneration: runGeneration) else { return }
                let probeKey = "probe|\(item.host.machineID)"
                if let retry = retryStates[probeKey], retry.nextAttempt > clockNow { continue }
                do {
                    let capability = try await item.host.transport.capabilities()
                    guard isCurrent(generation: generation, runGeneration: runGeneration) else { return }
                    guard capability.ok, capability.version == 1,
                          capability.capabilities.contains(ChatTabColorContract.capability) else {
                        noteFailure(key: probeKey)
                        setHostState(
                            item.host,
                            serverID: item.serverID,
                            phase: .unsupported,
                            detail: "Update this companion to clear shared tab colors."
                        )
                        continue
                    }
                    guard capability.serverId == item.serverID else {
                        noteFailure(key: probeKey)
                        setHostState(
                            item.host,
                            serverID: item.serverID,
                            phase: .pendingClear,
                            detail: "The companion identity changed; the pending clear was retained."
                        )
                        lastError = ChatTabColorPublisherError.companionIdentityChanged.localizedDescription
                        continue
                    }
                    retryStates[probeKey] = nil
                    let token = try secretStore.token(
                        serverID: item.serverID,
                        clientID: clientID
                    )
                    let key = recordKey(serverID: item.serverID)
                    var record = ledger.records[key] ?? ChatTabColorPublicationRecord()
                    record.revision += 1
                    record.enabled = false
                    record.pendingClear = true
                    record.fingerprint = nil
                    ledger.records[key] = record
                    ledgerStore.save(ledger)

                    let request = ChatTabColorPublicationRequest(
                        serverId: item.serverID,
                        publisherToken: token,
                        platform: ChatTabColorContract.platform,
                        clientName: ChatTabColorContract.clientName,
                        enabled: false,
                        revision: record.revision,
                        tabs: []
                    )
                    let response = try await item.host.transport.publish(
                        clientId: clientID,
                        request: request
                    )
                    guard isCurrent(generation: generation, runGeneration: runGeneration) else { return }
                    guard response.ok,
                          response.serverId == item.serverID,
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
                    setHostState(
                        item.host,
                        serverID: item.serverID,
                        phase: .idle,
                        detail: "Shared colors were cleared for this companion."
                    )
                } catch is CancellationError {
                    return
                } catch {
                    noteFailure(key: probeKey)
                    // Persist the intent explicitly so a relaunch while the
                    // companion is offline still retries the clear rather than
                    // inferring it from an old enabled record. A stale or
                    // conflicting revision is recovered with a strictly higher
                    // revision; server metadata is never lowered.
                    let key = recordKey(serverID: item.serverID)
                    var pendingRecord = ledger.records[key] ?? ChatTabColorPublicationRecord()
                    if Self.isRevisionRecoveryCode((error as? AgentControlCommandError)?.code) {
                        pendingRecord.revision = max(pendingRecord.revision + 1, Int(now().timeIntervalSince1970))
                    }
                    pendingRecord.pendingClear = true
                    ledger.records[key] = pendingRecord
                    ledgerStore.save(ledger)
                    setHostState(
                        item.host,
                        serverID: item.serverID,
                        phase: .pendingClear,
                        detail: "Clearing is pending until this companion is reachable."
                    )
                    lastError = error.localizedDescription
                }
            }
            updateAggregateStatus()
            if !(await sleepCurrent(pollInterval, generation: generation, runGeneration: runGeneration)) {
                return
            }
        }
    }

    private func pendingClearHosts(model: HerdrAppModel) -> [PendingClear] {
        var seenServers = Set<String>()
        return configuredHosts(model: model).compactMap { host in
            guard let serverID = ledger.serverIDsByMachine[host.machineID],
                  let record = ledger.records[recordKey(serverID: serverID)],
                  record.pendingClear || record.enabled,
                  seenServers.insert(serverID).inserted
            else { return nil }
            return PendingClear(host: host, serverID: serverID)
        }
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

