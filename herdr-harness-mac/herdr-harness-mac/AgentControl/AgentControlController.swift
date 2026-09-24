import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AgentControlController {
    typealias TransportFactory = @MainActor (ServerConfiguration) -> any AgentControlTransport
    typealias FirstMateClientFactory = @MainActor (ServerConfiguration) -> any FirstMateClient
    typealias PresentationWaiter = @MainActor @Sendable (
        AgentControlPresentationExpectation,
        HerdrAppModel,
        HerdrShellState
    ) async -> Bool

    private struct Host {
        let machineID: String
        let serverID: String
        let receiverToken: String
        let configuration: ServerConfiguration
        let connectionGeneration: Int
        let transport: any AgentControlTransport
    }

    private struct ExecutionContext {
        let receiverGeneration: Int
        let connectionGeneration: Int
        let expectedRevision: Int?
        let serverID: String?
        let hostMachineID: String?
    }

    private struct QueuedCommand {
        let command: AgentControlCommand
        let host: Host
        let context: ExecutionContext
    }

    private enum AcknowledgementOutcome {
        case accepted
        case retry
        case reregister
    }

    private enum DefaultsKey {
        static let enabled = "herdr.agentControl.enabled.v1"
    }

    private let defaults: UserDefaults
    private let identityStore: AgentControlIdentityStore
    private let transportFactory: TransportFactory
    private let firstMateClientFactory: FirstMateClientFactory
    private let presentationWaiter: PresentationWaiter
    private let pollInterval: Duration
    private let allowsReceiverInUnitTests: Bool
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var executionTask: Task<Void, Never>?
    private var receiverGeneration = 0
    private var configuredConnectionGeneration: Int?
    private var connectionObservationToken = 0
    private var observedConnectionModelID: ObjectIdentifier?
    private var connectionObservationIsArmed = false
    private var model: HerdrAppModel?
    private var shell: HerdrShellState?
    private var hudController: HerdrHudController?
    private var openMainWindow: (() -> Void)?
    private var openSettingsWindow: (() -> Void)?
    private var registeredHosts: [String: Host] = [:]
    private var serverToMachines: [String: Set<String>] = [:]
    private var serverConnectionGenerations: [String: Int] = [:]
    private var executionCaches: [String: AgentControlExecutionCache] = [:]
    private var pendingAcknowledgements: [String: AgentControlCachedReceipt] = [:]
    private var busyServerIDs: Set<String> = []
    private var commandQueue: [QueuedCommand] = []
    private var lastStateFingerprint: AgentControlUIState?
    private(set) var stateRevision = 0
    private(set) var statusText = "Agent control is off"
    private(set) var lastError: String?
    private(set) var activeServerCount = 0
    let instanceID: String
    let clientID: String

    var isEnabled: Bool {
        defaults.bool(forKey: DefaultsKey.enabled)
    }

    init(
        defaults: UserDefaults = .standard,
        secretStorage: any AgentControlSecretStorage = KeychainAgentControlSecretStorage(),
        pollInterval: Duration = .seconds(2),
        allowsReceiverInUnitTests: Bool = false,
        transportFactory: @escaping TransportFactory = { LiveAgentControlTransport(configuration: $0) },
        firstMateClientFactory: @escaping FirstMateClientFactory = { HerdrAPIClient(configuration: $0) },
        presentationWaiter: @escaping PresentationWaiter = AgentControlController.waitForPresentation
    ) {
        let identities = AgentControlIdentityStore(defaults: defaults, storage: secretStorage)
        self.defaults = defaults
        identityStore = identities
        self.pollInterval = pollInterval
        self.allowsReceiverInUnitTests = allowsReceiverInUnitTests
        self.transportFactory = transportFactory
        self.firstMateClientFactory = firstMateClientFactory
        self.presentationWaiter = presentationWaiter
        instanceID = UUID().uuidString.lowercased()
        clientID = identities.clientID()
    }

    deinit {
        pollTask?.cancel()
        executionTask?.cancel()
    }

    func configure(
        model: HerdrAppModel,
        shell: HerdrShellState,
        hudController: HerdrHudController,
        openMainWindow: @escaping () -> Void,
        openSettingsWindow: @escaping () -> Void
    ) {
        self.model = model
        self.shell = shell
        self.hudController = hudController
        self.openMainWindow = openMainWindow
        self.openSettingsWindow = openSettingsWindow
        ensureConnectionObservation()
        synchronize()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        defaults.set(enabled, forKey: DefaultsKey.enabled)
        if enabled { ensureConnectionObservation() }
        synchronize(forceRestart: true)
    }

    func synchronize(forceRestart: Bool = false) {
        guard let model else { return }
        guard isEnabled else {
            stop(status: "Agent control is off")
            return
        }
        ensureConnectionObservation()
        guard !model.isDemoMode else {
            stop(status: "Agent control is unavailable in demo mode", stopObserving: false)
            return
        }
        guard !Self.isUnitTestProcess || allowsReceiverInUnitTests else {
            stop(status: "Agent control networking is disabled in tests", stopObserving: false)
            return
        }
        guard forceRestart || configuredConnectionGeneration != model.connectionGeneration || pollTask == nil else { return }
        configuredConnectionGeneration = model.connectionGeneration
        restart()
    }

    /// The receiver belongs to the app process, not a window. Observation stays
    /// armed while control is enabled so Settings edits restart hosts even when
    /// the main scene is closed. Observation callbacks are one-shot; the token
    /// makes callbacks from a previous configure/disable operation inert.
    private func ensureConnectionObservation() {
        guard isEnabled, let model else {
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

    func noteWindow(_ window: AgentControlWindow) {
        guard let shell else { return }
        shell.agentControlWindow = window
        stateDidChange()
    }

    func stateDidChange() {
        stateRevision &+= 1
        lastStateFingerprint = nil
    }

    func currentState() -> AgentControlUIState {
        state()
    }

    func actions() -> [AgentControlActionDescriptor] {
        let globalReason = isEnabled ? nil : "Turn on Allow agent control in Settings."
        var values = AgentControlRegistry.actions(enabled: isEnabled, disabledReason: globalReason)
        guard isEnabled, let shell else { return values }
        let modal = effectiveModal(shell: shell)
        for index in values.indices {
            let id = values[index].id
            let disabledReason: String?
            if modal != nil, Self.modalBlockedActions.contains(id) {
                disabledReason = "Close the current dialog before navigating."
            } else if id == "ui.back", !shell.canGoBack {
                disabledReason = "There is no previous navigation destination."
            } else if id == "ui.forward", !shell.canGoForward {
                disabledReason = "There is no forward navigation destination."
            } else if ["ui.hud", "ui.notes"].contains(id), hudController?.chats == nil {
                disabledReason = "The HUD is not configured."
            } else if let model,
                      id.hasPrefix("pr-review."), id != "pr-review.open", id != "pr-review.state",
                      (shell.resolvedScope(for: model) != .prReview || shell.prReview.selectedReviewID == nil) {
                disabledReason = "Open a PR review first."
            } else {
                disabledReason = nil
            }
            if let disabledReason {
                values[index].enabled = false
                values[index].disabledReason = disabledReason
            }
        }
        return values
    }

    func executeForTesting(
        _ command: AgentControlCommand,
        serverMapping: [String: String]
    ) async throws -> AgentControlExecutionResult {
        serverToMachines = serverMapping.mapValues { [$0] }
        if let model {
            serverConnectionGenerations = serverMapping.mapValues { _ in model.connectionGeneration }
        }
        var localCommand = command
        localCommand.clientId = clientID
        localCommand.instanceId = instanceID
        let context = try executionContext(for: localCommand)
        return try await execute(localCommand, context: context)
    }

    private func restart() {
        guard let model else { return }
        pollTask?.cancel()
        executionTask?.cancel()
        executionTask = nil
        receiverGeneration &+= 1
        let generation = receiverGeneration
        let connectionGeneration = model.connectionGeneration
        configuredConnectionGeneration = connectionGeneration
        registeredHosts = [:]
        serverToMachines = [:]
        serverConnectionGenerations = [:]
        // Completed outcomes survive an in-process connection restart. The
        // same instance can retry their frozen acknowledgements after the host
        // is registered again without rerunning the UI action.
        busyServerIDs = Set(pendingAcknowledgements.keys)
        commandQueue = []
        activeServerCount = 0
        lastError = nil
        statusText = "Connecting agent control…"
        pollTask = Task { [weak self] in
            await self?.run(
                receiverGeneration: generation,
                connectionGeneration: connectionGeneration
            )
        }
    }

    private func stop(status: String, stopObserving: Bool = true) {
        if stopObserving { stopConnectionObservation() }
        pollTask?.cancel()
        executionTask?.cancel()
        pollTask = nil
        executionTask = nil
        receiverGeneration &+= 1
        registeredHosts = [:]
        serverToMachines = [:]
        serverConnectionGenerations = [:]
        pendingAcknowledgements = [:]
        busyServerIDs = []
        commandQueue = []
        activeServerCount = 0
        statusText = status
    }

    /// One bounded connection loop per configured host prevents an unavailable
    /// companion from delaying heartbeats for healthy companions. UI execution
    /// remains serialized separately by drainCommandQueue().
    private func run(receiverGeneration: Int, connectionGeneration: Int) async {
        guard let model,
              receiverIsCurrent(receiverGeneration, connectionGeneration: connectionGeneration) else { return }
        let configured = model.machines.prefix(8).compactMap { machine -> (String, ServerConfiguration)? in
            guard let configuration = model.firstMateConfiguration(machineID: machine.id),
                  !configuration.token.isEmpty else { return nil }
            return (machine.id, configuration)
        }
        if model.machines.count > 8 {
            lastError = "Agent control supports the first 8 configured companions."
        }
        guard !configured.isEmpty else {
            statusText = "No authenticated companion is configured"
            return
        }
        await withTaskGroup(of: Void.self) { group in
            for (machineID, configuration) in configured {
                group.addTask { [weak self] in
                    await self?.runHost(
                        machineID: machineID,
                        configuration: configuration,
                        receiverGeneration: receiverGeneration,
                        connectionGeneration: connectionGeneration
                    )
                }
            }
            await group.waitForAll()
        }
    }

    private func runHost(
        machineID: String,
        configuration: ServerConfiguration,
        receiverGeneration: Int,
        connectionGeneration: Int
    ) async {
        var retryDelay = Duration.seconds(1)
        while receiverIsCurrent(receiverGeneration, connectionGeneration: connectionGeneration) {
            let transport = transportFactory(configuration)
            do {
                let capability = try await transport.capabilities()
                try ensureReceiverCurrent(receiverGeneration, connectionGeneration: connectionGeneration)
                guard capability.ok, capability.version == 1,
                      capability.capabilities.contains("agent-control-v1"),
                      Self.isSafeServerID(capability.serverId) else {
                    throw AgentControlCommandError.unavailable("The companion does not support agent control v1.")
                }
                let token = try identityStore.receiverToken(serverID: capability.serverId, clientID: clientID)
                let host = Host(
                    machineID: machineID,
                    serverID: capability.serverId,
                    receiverToken: token,
                    configuration: configuration,
                    connectionGeneration: connectionGeneration,
                    transport: transport
                )
                serverToMachines[capability.serverId, default: []].insert(machineID)
                serverConnectionGenerations[capability.serverId] = connectionGeneration

                // Duplicate configured aliases are expected. Exactly one loop
                // owns polling for a stable serverId; aliases still participate
                // in exact target resolution.
                if let owner = registeredHosts[capability.serverId], owner.machineID != machineID {
                    try await sleepWhileCurrent(
                        for: .seconds(5),
                        receiverGeneration: receiverGeneration,
                        connectionGeneration: connectionGeneration
                    )
                    continue
                }
                registeredHosts[capability.serverId] = host
                let registration = try await transport.register(registrationRequest(for: host))
                try ensureReceiverCurrent(receiverGeneration, connectionGeneration: connectionGeneration)
                guard registration.ok, registration.serverId == capability.serverId else {
                    throw AgentControlCommandError.failed("The companion returned a mismatched server identity.")
                }
                noteHostConnected(host)
                retryDelay = .seconds(1)

                while hostIsCurrent(host, receiverGeneration: receiverGeneration) {
                    if let pending = pendingAcknowledgements[host.serverID] {
                        switch await acknowledge(pending, host: host, receiverGeneration: receiverGeneration) {
                        case .accepted:
                            pendingAcknowledgements[host.serverID] = nil
                            busyServerIDs.remove(host.serverID)
                        case .retry:
                            break
                        case .reregister:
                            pendingAcknowledgements[host.serverID] = nil
                            busyServerIDs.remove(host.serverID)
                            throw AgentControlCommandError.stale("The result endpoint rejected the receiver binding; registering again.")
                        }
                    } else if busyServerIDs.contains(host.serverID) {
                        // Registration is also a heartbeat and cannot claim a
                        // second command while this host is queued/executing.
                        let heartbeat = try await transport.register(registrationRequest(for: host))
                        try ensureReceiverCurrent(receiverGeneration, connectionGeneration: connectionGeneration)
                        guard heartbeat.ok, heartbeat.serverId == host.serverID else { throw APIError.invalidResponse }
                    } else {
                        let response = try await host.transport.poll(
                            clientId: clientID,
                            request: AgentControlPollRequest(
                                receiverToken: host.receiverToken,
                                instanceId: instanceID,
                                state: state(),
                                actions: actions()
                            )
                        )
                        try ensureReceiverCurrent(receiverGeneration, connectionGeneration: connectionGeneration)
                        guard response.ok else { throw APIError.invalidResponse }
                        if let command = response.command {
                            try receive(command, from: host, receiverGeneration: receiverGeneration)
                        }
                    }
                    try await sleepWhileCurrent(
                        for: pollInterval,
                        receiverGeneration: receiverGeneration,
                        connectionGeneration: connectionGeneration
                    )
                }
            } catch is CancellationError {
                releaseHost(
                    machineID: machineID,
                    receiverGeneration: receiverGeneration,
                    connectionGeneration: connectionGeneration
                )
                return
            } catch {
                guard receiverIsCurrent(receiverGeneration, connectionGeneration: connectionGeneration) else { return }
                lastError = error.localizedDescription
                releaseHost(
                    machineID: machineID,
                    receiverGeneration: receiverGeneration,
                    connectionGeneration: connectionGeneration
                )
                do {
                    try await sleepWhileCurrent(
                        for: retryDelay,
                        receiverGeneration: receiverGeneration,
                        connectionGeneration: connectionGeneration
                    )
                } catch {
                    return
                }
                retryDelay = min(retryDelay * 2, .seconds(15))
            }
        }
    }

    private func receive(
        _ command: AgentControlCommand,
        from host: Host,
        receiverGeneration: Int
    ) throws {
        try ensureReceiverCurrent(receiverGeneration, connectionGeneration: host.connectionGeneration)
        guard hostIsCurrent(host, receiverGeneration: receiverGeneration),
              command.clientId == clientID,
              command.instanceId == instanceID,
              command.status == "running" else {
            throw AgentControlCommandError.stale("The companion delivered a command for a different receiver state.")
        }
        guard !Self.commandIsExpired(command) else {
            let receipt = AgentControlCachedReceipt(
                command: command,
                status: "failed",
                result: nil,
                error: .stale("The command expired before native execution."),
                state: state()
            )
            pendingAcknowledgements[host.serverID] = receipt
            busyServerIDs.insert(host.serverID)
            return
        }
        guard !busyServerIDs.contains(host.serverID) else {
            throw AgentControlCommandError.conflict("The companion delivered more than one running command for this receiver.")
        }
        let context: ExecutionContext
        do {
            context = try executionContext(for: command, receiverGeneration: receiverGeneration, host: host)
        } catch let error as AgentControlCommandError {
            // Poll already claimed this command as running. A stale expected
            // revision is a normal command rejection, not a transport failure:
            // freeze and acknowledge it now rather than abandoning it until the
            // server's running-command deadline expires.
            pendingAcknowledgements[host.serverID] = AgentControlCachedReceipt(
                command: command,
                status: "failed",
                result: nil,
                error: error,
                state: state()
            )
            busyServerIDs.insert(host.serverID)
            return
        }
        busyServerIDs.insert(host.serverID)
        commandQueue.append(QueuedCommand(command: command, host: host, context: context))
        startCommandDrainIfNeeded(receiverGeneration: receiverGeneration)
    }

    private func startCommandDrainIfNeeded(receiverGeneration: Int) {
        guard executionTask == nil else { return }
        executionTask = Task { [weak self] in
            await self?.drainCommandQueue(receiverGeneration: receiverGeneration)
        }
    }

    private func drainCommandQueue(receiverGeneration: Int) async {
        defer {
            if receiverGeneration == self.receiverGeneration { executionTask = nil }
        }
        while receiverIsCurrent(receiverGeneration), !commandQueue.isEmpty {
            let queued = commandQueue.removeFirst()
            guard hostIsCurrent(queued.host, receiverGeneration: receiverGeneration) else {
                // A claimed old-generation command is intentionally abandoned
                // for the server to classify outcome_unknown. It must never be
                // replayed against the replacement connection.
                synchronize()
                return
            }
            let receipt: AgentControlCachedReceipt
            var cache = executionCaches[queued.host.serverID] ?? AgentControlExecutionCache()
            switch cache.lookup(queued.command) {
            case let .hit(cached):
                receipt = cached
            case .conflict:
                receipt = AgentControlCachedReceipt(
                    command: queued.command,
                    status: "failed",
                    result: nil,
                    error: .conflict("The request ID was reused with a different command."),
                    state: state()
                )
            case .miss:
                if Self.commandIsExpired(queued.command) {
                    receipt = AgentControlCachedReceipt(
                        command: queued.command,
                        status: "failed",
                        result: nil,
                        error: .stale("The command expired while waiting for native execution."),
                        state: state()
                    )
                } else {
                    do {
                        let value = try await execute(queued.command, context: queued.context)
                        guard hostIsCurrent(queued.host, receiverGeneration: receiverGeneration) else { return }
                        receipt = AgentControlCachedReceipt(
                            command: queued.command,
                            status: "completed",
                            result: value.values,
                            error: nil,
                            state: state()
                        )
                    } catch let error as AgentControlCommandError {
                        guard hostIsCurrent(queued.host, receiverGeneration: receiverGeneration) else { return }
                        receipt = AgentControlCachedReceipt(
                            command: queued.command,
                            status: "failed",
                            result: nil,
                            error: error,
                            state: state()
                        )
                    } catch {
                        guard hostIsCurrent(queued.host, receiverGeneration: receiverGeneration) else { return }
                        receipt = AgentControlCachedReceipt(
                            command: queued.command,
                            status: "failed",
                            result: nil,
                            error: .failed(error.localizedDescription),
                            state: state()
                        )
                    }
                }
                cache.store(receipt)
                executionCaches[queued.host.serverID] = cache
            }
            guard hostIsCurrent(queued.host, receiverGeneration: receiverGeneration) else { return }
            pendingAcknowledgements[queued.host.serverID] = receipt
        }
    }

    private func registrationRequest(for host: Host) -> AgentControlRegistrationRequest {
        AgentControlRegistrationRequest(
            clientId: clientID,
            name: "Herdr Companion",
            receiverToken: host.receiverToken,
            instanceId: instanceID,
            state: state(),
            actions: actions()
        )
    }

    private func acknowledge(
        _ execution: AgentControlCachedReceipt,
        host: Host,
        receiverGeneration: Int
    ) async -> AcknowledgementOutcome {
        do {
            let response = try await host.transport.acknowledge(
                clientId: clientID,
                requestId: execution.command.requestId,
                request: AgentControlResultRequest(
                    receiverToken: host.receiverToken,
                    instanceId: instanceID,
                    status: execution.status,
                    result: execution.result,
                    error: execution.error,
                    state: execution.state
                )
            )
            try ensureReceiverCurrent(receiverGeneration, connectionGeneration: host.connectionGeneration)
            guard response.ok,
                  response.command.requestId == execution.command.requestId,
                  response.command.clientId == clientID,
                  response.command.instanceId == instanceID,
                  response.command.status == execution.status else {
                throw AgentControlCommandError.conflict("The companion returned a mismatched acknowledgement.")
            }
            return .accepted
        } catch is CancellationError {
            return .retry
        } catch {
            lastError = "Could not acknowledge \(execution.command.requestId): \(error.localizedDescription)"
            return Self.isPermanentAcknowledgementError(error) ? .reregister : .retry
        }
    }

    private func execute(
        _ command: AgentControlCommand,
        context: ExecutionContext
    ) async throws -> AgentControlExecutionResult {
        try validateExecutionContext(context)
        guard isEnabled else { throw AgentControlCommandError.disabled("Agent control is turned off.") }
        guard command.clientId == clientID, command.instanceId == instanceID, command.status == "running" else {
            throw AgentControlCommandError.stale("The command belongs to a different receiver instance.")
        }
        guard !Self.commandIsExpired(command) else {
            throw AgentControlCommandError.stale("The command expired before execution.")
        }
        try validateTarget(command.target)
        try AgentControlRegistry.validate(action: command.action, parameters: command.parameters)
        guard let model, let shell else { throw AgentControlCommandError.unavailable("The app shell is not configured.") }
        if effectiveModal(shell: shell) != nil, Self.modalBlockedActions.contains(command.action) {
            throw AgentControlCommandError.conflict("Navigation is blocked by an open dialog; the dialog and its draft were preserved.")
        }

        switch command.action {
        case "ui.open":
            guard let target = command.target else { throw AgentControlCommandError.invalid("ui.open requires an exact target.") }
            try await refreshForTarget(target, model: model, context: context)
            if target.kind == "hud-chat" {
                guard command.parameters.isEmpty else { throw AgentControlCommandError.invalid("HUD chat targets do not accept view parameters.") }
                return try await openHUDChat(target, model: model, context: context)
            }
            if target.kind == "first-mate" {
                guard command.parameters["view"] == nil else { throw AgentControlCommandError.invalid("First Mate targets use inspector, not view.") }
                return try await openFirstMate(target, shell: shell, model: model, command: command, context: context)
            }
            guard command.parameters["inspector"] == nil else { throw AgentControlCommandError.invalid("Only First Mate targets accept inspector.") }
            let resolved = try resolve(target, model: model)
            let view = command.parameters["view"]?.stringValue
            let panePresentation = try await open(
                resolved,
                view: view,
                shell: shell,
                model: model,
                context: context
            )
            if let panePresentation {
                guard await presentationWaiter(panePresentation, model, shell) else {
                    throw AgentControlCommandError.unavailable("The requested pane mode was not presented before the bounded deadline.")
                }
                try validateConnectionContext(context)
            }
            stateDidChange()
            var result: [String: PiJSONValue] = [
                "presentation": .string("main"),
                "segment": .string(state().segment),
            ]
            if target.kind == "tab", let tabID = target.tabId {
                result["mode"] = .string("tab-overview")
                result["tabId"] = .string(tabID)
            } else if target.kind == "workspace" {
                result["mode"] = .string("workspace-overview")
            } else if let view {
                result["mode"] = .string(view)
            }
            return .completed(result)

        case "ui.segment":
            let segment = try requiredString("segment", command.parameters)
            let panePresentation = try await openSegment(segment, shell: shell, model: model, context: context)
            if let panePresentation {
                guard await presentationWaiter(panePresentation, model, shell) else {
                    throw AgentControlCommandError.unavailable("The requested pane mode was not presented before the bounded deadline.")
                }
                try validateConnectionContext(context)
            }
            stateDidChange()
            guard state().segment == segment else {
                throw AgentControlCommandError.conflict("The app did not remain on the requested segment.")
            }
            return .completed(["segment": .string(segment)])

        case "pr-review.open":
            let reviewID = try requiredString("review_id", command.parameters)
            guard let configuration = model.prReviewConfiguration() else { throw AgentControlCommandError.unavailable("Configure a development-role PR review host first.") }
            // Verify against an isolated client before changing the process-owned store.
            _ = try await HerdrAPIClient(configuration: configuration).prReview(id: reviewID)
            let tab = command.parameters["tab"]?.stringValue.flatMap(PRReviewTab.init(rawValue:)) ?? .files
            shell.showPRReview(machineID: model.prReviewMachine?.id, reviewID: reviewID, tab: tab, model: model)
            await shell.prReview.refreshSelected()
            stateDidChange()
            return .completed(["presentation": .string("pr-review"), "review_id": .string(reviewID), "segment": .string("pr-review")])

        case "pr-review.select-file":
            try requirePRReviewOpen(shell: shell, model: model); let path = try requiredString("path", command.parameters); shell.prReview.selectedPath = path; stateDidChange(); return .completed(["path": .string(path)])
        case "pr-review.scroll-to-line":
            try requirePRReviewOpen(shell: shell, model: model)
            let path = try requiredString("path", command.parameters)
            guard case let .number(line)? = command.parameters["line"] else {
                throw AgentControlCommandError.invalid("Missing line.")
            }
            guard shell.prReview.snapshot?.files.contains(where: { $0.path == path }) == true else {
                throw AgentControlCommandError.invalid("The requested file is not in this review.")
            }
            let side = command.parameters["side"]?.stringValue.flatMap(PRReviewSide.init(rawValue:)) ?? .after
            shell.prReview.scroll(to: path, line: Int(line), side: side)
            stateDidChange()
            let visible = await Self.waitForVisibleLine(path: path, line: Int(line), side: side, store: shell.prReview)
            return .completed(["path": .string(path), "line": .number(line), "side": .string(side.rawValue), "visible": .bool(visible)])
        case "pr-review.highlight-lines":
            try requirePRReviewOpen(shell: shell, model: model)
            let path = try requiredString("path", command.parameters)
            guard case let .number(start)? = command.parameters["start"], case let .number(end)? = command.parameters["end"] else {
                throw AgentControlCommandError.invalid("Missing line range.")
            }
            let side = command.parameters["side"]?.stringValue.flatMap(PRReviewSide.init(rawValue:)) ?? .after
            shell.prReview.highlightLines(path: path, start: Int(start), end: Int(end), side: side)
            stateDidChange()
            return .completed(["path": .string(path), "start": .number(start), "end": .number(end), "side": .string(side.rawValue)])
        case "pr-review.clear-highlight":
            try requirePRReviewOpen(shell: shell, model: model); shell.prReview.highlight = nil; stateDidChange(); return .completed()
        case "pr-review.set-filter":
            try requirePRReviewOpen(shell: shell, model: model); let impact = try requiredString("impact", command.parameters); guard let filter = PRReviewImpactFilter(rawValue: impact) else { throw AgentControlCommandError.invalid("Invalid impact.") }; shell.prReview.impactFilter = filter; stateDidChange(); return .completed(["impact": .string(impact)])
        case "pr-review.set-view-mode":
            try requirePRReviewOpen(shell: shell, model: model); let mode = try requiredString("mode", command.parameters); guard let value = PRReviewViewMode(rawValue: mode) else { throw AgentControlCommandError.invalid("Invalid mode.") }; shell.prReview.viewMode = value; stateDidChange(); return .completed(["mode": .string(mode)])
        case "pr-review.set-tab":
            try requirePRReviewOpen(shell: shell, model: model); let tab = try requiredString("tab", command.parameters); guard let value = PRReviewTab(rawValue: tab) else { throw AgentControlCommandError.invalid("Invalid tab.") }; shell.prReview.tab = value; stateDidChange(); return .completed(["tab": .string(tab)])
        case "pr-review.set-viewed":
            try requirePRReviewOpen(shell: shell, model: model); let path = try requiredString("path", command.parameters); guard case let .bool(viewed)? = command.parameters["viewed"] else { throw AgentControlCommandError.invalid("Missing viewed.") }; await shell.prReview.setViewed(paths: [path], viewed: viewed); stateDidChange(); return .completed(["path": .string(path), "viewed": .bool(viewed)])
        case "pr-review.state":
            return .completed(prReviewState(shell.prReview))

        case "ui.back":
            return try await navigateHistory(back: true, shell: shell, model: model, context: context)
        case "ui.forward":
            return try await navigateHistory(back: false, shell: shell, model: model, context: context)
        case "ui.refresh":
            let machineIDs = Set(serverToMachines.values.flatMap { $0 })
            guard !machineIDs.isEmpty else { throw AgentControlCommandError.unavailable("No registered companion is available to refresh.") }
            var refreshed = 0
            for machineID in machineIDs.sorted() {
                guard let host = registeredHost(for: machineID),
                      modelConnectionMatches(host: host, machineID: machineID, model: model) else { continue }
                try await model.refreshForAgentControl(machineID: machineID)
                try validateExecutionContext(context)
                refreshed += 1
            }
            guard refreshed > 0 else {
                throw AgentControlCommandError.unavailable("The app model has not connected to the current companion configuration yet.")
            }
            stateDidChange()
            return .completed(["refreshed": .bool(true), "liveMachineCount": .number(Double(refreshed))])
        case "ui.reveal":
            guard let target = command.target else { throw AgentControlCommandError.invalid("ui.reveal requires a pane target.") }
            try await refreshForTarget(target, model: model, context: context)
            guard case let .pane(pane) = try resolve(target, model: model) else {
                throw AgentControlCommandError.invalid("ui.reveal requires a pane target.")
            }
            guard model.revealPaneInSidebar(id: pane.id) else { throw AgentControlCommandError.notFound("The pane is no longer available.") }
            showMainWindow(); stateDidChange(); return .completed()
        case "ui.settings":
            openSettingsWindow?(); NSApp.activate(); shell.agentControlWindow = .settings; stateDidChange()
            return .completed(["presentation": .string("settings")])
        case "ui.hud":
            guard let hudController, hudController.chats != nil else { throw AgentControlCommandError.unavailable("The HUD is not configured.") }
            hudController.summon(); shell.agentControlWindow = .hud; stateDidChange()
            return .completed(["presentation": .string("hud")])
        case "ui.notes":
            guard let hudController, hudController.chats != nil else { throw AgentControlCommandError.unavailable("The HUD is not configured.") }
            hudController.setNotesVisible(true); hudController.summon(); shell.agentControlWindow = .hud; stateDidChange()
            return .completed(["presentation": .string("hud-notes")])
        case "ui.sidebar":
            applySidebar(command.parameters, model: model); showMainWindow(); stateDidChange(); return .completed()
        case "chat.summarize":
            let pane = try await targetedPane(command.target, model: model, context: context)
            guard let request = PiSessionSummaryRequest(pane: pane) else {
                throw AgentControlCommandError.unavailable("This pane has no live Pi session to summarize.")
            }
            shell.piSessionSummaryRequest = request
            showMainWindow(); stateDidChange()
            return .completed(["presentation": .string("summary"), "operationState": .string("started")])
        case "chat.smart-rename":
            let pane = try await targetedPane(command.target, model: model, context: context)
            guard !model.smartRenamingPaneIDs.contains(pane.id) else {
                throw AgentControlCommandError.conflict("Smart Rename is already running for this pane.")
            }
            let outcome: HerdrAppModel.SmartRenamePaneOutcome
            do {
                outcome = try await model.smartRenameForAgentControl(pane) {
                    try self.validateExecutionContext(context)
                }
            } catch let error as AgentControlCommandError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Routing and context failures carry actionable messages while
                // the receiver contract requires an AgentControlCommandError.
                throw AgentControlCommandError.failed(error.localizedDescription)
            }
            switch outcome {
            case let .refreshed(title, notice):
                var result: [String: PiJSONValue] = [
                    "operationState": .string("finished"),
                    "title": .string(title),
                ]
                if let notice, !notice.isEmpty {
                    result["notice"] = .string(notice)
                }
                return .completed(result)
            case let .renamedNeedsRefresh(title, message, notice):
                var text = "The pane was renamed to “\(title)”, but updated workspace state could not be refreshed: \(message)"
                if let notice, !notice.isEmpty { text += " \(notice)" }
                throw AgentControlCommandError.failed(text)
            }
        case "chat.mark-unread":
            let pane = try await targetedPane(command.target, model: model, context: context)
            model.markPaneUnread(pane)
            stateDidChange()
            return .completed(["unread": .bool(true)])
        case "chat.set-model":
            let pane = try await targetedPane(command.target, model: model, context: context)
            guard pane.supportsPiSemanticChat else {
                throw AgentControlCommandError.unavailable("This pane has no live semantic Pi session.")
            }
            let provider = try requiredString("provider", command.parameters)
            let modelID = try requiredString("modelId", command.parameters)
            try await model.setPiModel(provider: provider, modelID: modelID, for: pane)
            try validateExecutionContext(context)
            return .completed(["provider": .string(provider), "modelId": .string(modelID)])
        case "chat.tab-color":
            // Permanently read-only. The registry rejects this before any
            // side effect and this arm is defense in depth for a legacy or
            // queued command, so it must never refresh or assign.
            throw AgentControlCommandError.disabled(
                AgentControlRegistry.permanentlyDisabledActions["chat.tab-color"]
                    ?? "Tab colors are read-only through agent control."
            )
        default:
            throw AgentControlCommandError.invalid("Unsupported action: \(command.action)")
        }
    }

    private enum ResolvedTarget {
        case pane(HerdrPane)
        case workspace(HerdrWorkspace)
        case tab(HerdrWorkspace, HerdrTab)
    }

    private func machineIDs(for target: AgentControlTarget) throws -> Set<String> {
        guard let serverID = target.serverId,
              let model,
              serverConnectionGenerations[serverID] == model.connectionGeneration,
              let aliases = serverToMachines[serverID],
              !aliases.isEmpty else {
            throw AgentControlCommandError.stale("The target does not identify a registered companion server.")
        }
        // machineId is a CLI configuration alias. Stable authenticated serverId
        // is authoritative; never compare that alias to the native UUID. If
        // duplicate native aliases point at one server, use the single loop
        // that owns the authenticated registration.
        if let owner = registeredHosts[serverID] { return [owner.machineID] }
        return aliases
    }

    private func preferredMachineID(for target: AgentControlTarget) throws -> String {
        guard let machineID = try machineIDs(for: target).sorted().first else {
            throw AgentControlCommandError.stale("The target companion is unavailable.")
        }
        return machineID
    }

    private func resolve(_ target: AgentControlTarget?, model: HerdrAppModel) throws -> ResolvedTarget {
        guard let target else { throw AgentControlCommandError.stale("The target is missing.") }
        let machineIDs = try machineIDs(for: target)
        let controllable = machineIDs.filter { model.isDemoMode || model.canControl(machineID: $0) }
        guard !controllable.isEmpty else {
            throw AgentControlCommandError.unavailable("The target companion did not complete a fresh authenticated refresh.")
        }
        switch target.kind {
        case "pane":
            guard let rawID = target.paneId else { throw AgentControlCommandError.invalid("The pane target is incomplete.") }
            let matches = model.workspaces.lazy.flatMap(\.panes).filter { controllable.contains($0.machineID) && $0.paneID == rawID }
            guard matches.count == 1, let pane = matches.first else {
                throw matches.isEmpty
                    ? AgentControlCommandError.notFound("The exact pane is no longer available.")
                    : AgentControlCommandError.stale("The pane target is ambiguous across configured aliases.")
            }
            guard target.workspaceId == pane.workspaceID,
                  target.tabId == pane.tabID,
                  target.terminalId == pane.terminalID else {
                throw AgentControlCommandError.stale("Pane membership or terminal identity changed.")
            }
            if let liveSession = pane.piSemantic?.sessionID {
                guard target.sessionId == liveSession else { throw AgentControlCommandError.stale("The pane now hosts a different Pi session.") }
            } else if target.sessionId != nil {
                throw AgentControlCommandError.stale("The requested Pi session is no longer attached.")
            }
            return .pane(pane)
        case "workspace":
            guard let rawID = target.workspaceId else { throw AgentControlCommandError.invalid("The workspace target is incomplete.") }
            let matches = model.workspaces.filter { controllable.contains($0.machineID) && $0.workspaceID == rawID }
            guard matches.count == 1, let workspace = matches.first else {
                throw matches.isEmpty
                    ? AgentControlCommandError.notFound("The exact workspace is no longer available.")
                    : AgentControlCommandError.stale("The workspace target is ambiguous across configured aliases.")
            }
            return .workspace(workspace)
        case "tab":
            guard let workspaceID = target.workspaceId, let tabID = target.tabId else {
                throw AgentControlCommandError.invalid("The tab target is incomplete.")
            }
            let matches = model.workspaces.compactMap { workspace -> (HerdrWorkspace, HerdrTab)? in
                guard controllable.contains(workspace.machineID), workspace.workspaceID == workspaceID,
                      let tab = workspace.tabs.first(where: { $0.tabID == tabID }) else { return nil }
                return (workspace, tab)
            }
            guard matches.count == 1, let match = matches.first else {
                throw matches.isEmpty
                    ? AgentControlCommandError.notFound("The exact tab is no longer available in that workspace.")
                    : AgentControlCommandError.stale("The tab target is ambiguous across configured aliases.")
            }
            return .tab(match.0, match.1)
        default:
            throw AgentControlCommandError.invalid("Unsupported target kind.")
        }
    }

    private func targetedPane(
        _ target: AgentControlTarget?,
        model: HerdrAppModel,
        context: ExecutionContext
    ) async throws -> HerdrPane {
        guard let target else { throw AgentControlCommandError.invalid("This action requires a pane target.") }
        try await refreshForTarget(target, model: model, context: context)
        guard case let .pane(pane) = try resolve(target, model: model) else {
            throw AgentControlCommandError.invalid("This action requires a pane target.")
        }
        return pane
    }

    private func refreshForTarget(
        _ target: AgentControlTarget,
        model: HerdrAppModel,
        context: ExecutionContext
    ) async throws {
        let machineIDs = try machineIDs(for: target)
        var refreshed = 0
        var finalError: Error?
        for machineID in machineIDs.sorted() {
            do {
                if let host = registeredHost(for: machineID),
                   !modelConnectionMatches(host: host, machineID: machineID, model: model) {
                    throw AgentControlCommandError.stale(
                        "The app model has not connected to the current companion configuration yet."
                    )
                }
                try await model.refreshForAgentControl(machineID: machineID)
                try validateExecutionContext(context)
                refreshed += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                finalError = error
            }
        }
        guard refreshed > 0 else {
            throw finalError ?? AgentControlCommandError.unavailable("The target companion is offline.")
        }
    }

    private func open(
        _ resolved: ResolvedTarget,
        view: String?,
        shell: HerdrShellState,
        model: HerdrAppModel,
        context: ExecutionContext
    ) async throws -> AgentControlPresentationExpectation? {
        switch resolved {
        case let .pane(pane):
            let requestedMode = try paneMode(view, pane: pane, model: model)
            if requestedMode == .git {
                let status = try await model.fetchGitStatus(for: pane)
                try validateExecutionContext(context)
                guard PaneGitProbePolicy.availability(
                    after: .status(ok: status.ok, rootPath: status.cwd),
                    preserving: .checking
                ) == .available else {
                    throw AgentControlCommandError.unavailable("Git is not available for this pane.")
                }
            }
            showMainWindow()
            shell.openPane(id: pane.id, mode: requestedMode, model: model)
            return .pane(id: pane.id, mode: requestedMode)
        case let .workspace(workspace):
            guard view == nil else { throw AgentControlCommandError.invalid("Workspace targets do not accept a pane view.") }
            showMainWindow()
            shell.showWorkspace(id: workspace.id, highlightedTabID: nil, model: model)
            return nil
        case let .tab(workspace, tab):
            guard view == nil else { throw AgentControlCommandError.invalid("Tab targets do not accept a pane view.") }
            showMainWindow()
            shell.showWorkspace(id: workspace.id, highlightedTabID: tab.id, model: model)
            return nil
        }
    }

    private func paneMode(_ value: String?, pane: HerdrPane, model: HerdrAppModel) throws -> PaneDetailMode {
        switch value ?? (pane.supportsPiSemanticChat ? "chat" : "terminal") {
        case "chat":
            guard pane.supportsPiSemanticChat else { throw AgentControlCommandError.unavailable("This pane has no semantic Pi chat.") }
            return .chat
        case "terminal": return .terminal
        case "git": return .git
        case "skills":
            guard model.workspace(containing: pane) != nil else { throw AgentControlCommandError.unavailable("This pane has no workspace skills context.") }
            return .skills
        default: throw AgentControlCommandError.invalid("Unsupported pane view.")
        }
    }

    private func openSegment(
        _ segment: String,
        shell: HerdrShellState,
        model: HerdrAppModel,
        context: ExecutionContext
    ) async throws -> AgentControlPresentationExpectation? {
        switch segment {
        case "chat", "terminal", "git", "skills":
            guard let pane = model.pane(id: model.selectedPaneID) else { throw AgentControlCommandError.unavailable("No pane is selected.") }
            let pinnedPaneID = pane.id
            let mode = try paneMode(segment, pane: pane, model: model)
            if mode == .git {
                let status = try await model.fetchGitStatus(for: pane)
                try validateExecutionContext(context)
                guard model.selectedPaneID == pinnedPaneID else {
                    throw AgentControlCommandError.conflict("The selected pane changed while checking Git.")
                }
                guard PaneGitProbePolicy.availability(
                    after: .status(ok: status.ok, rootPath: status.cwd),
                    preserving: .checking
                ) == .available else {
                    throw AgentControlCommandError.unavailable("Git is not available for this pane.")
                }
            }
            guard model.selectedPaneID == pinnedPaneID else {
                throw AgentControlCommandError.conflict("The selected pane changed before the segment could be applied.")
            }
            showMainWindow()
            shell.openPane(id: pane.id, mode: mode, model: model)
            return .pane(id: pane.id, mode: mode)
        case "workspace":
            guard let workspace = model.workspace(id: model.selectedWorkspaceID) ?? model.pane(id: model.selectedPaneID).flatMap(model.workspace(containing:))
            else { throw AgentControlCommandError.unavailable("No workspace is selected.") }
            showMainWindow()
            shell.showWorkspace(id: workspace.id, highlightedTabID: nil, model: model)
        case "active-work": showMainWindow(); shell.show(.activeWork, model: model)
        case "pr-review": showMainWindow(); shell.show(.prReview, model: model)
        case "first-mate": showMainWindow(); shell.show(.firstMate, model: model)
        case "fleet": showMainWindow(); shell.show(.fleet, model: model)
        case "attention": showMainWindow(); shell.show(.attention, model: model)
        case "activity": showMainWindow(); shell.show(.activity, model: model)
        default: throw AgentControlCommandError.invalid("Unsupported segment.")
        }
        return nil
    }

    private func navigateHistory(
        back: Bool,
        shell: HerdrShellState,
        model: HerdrAppModel,
        context: ExecutionContext
    ) async throws -> AgentControlExecutionResult {
        showMainWindow()
        let moved = back ? shell.goBack(model: model) : shell.goForward(model: model)
        guard moved, let destination = shell.history.current else {
            throw AgentControlCommandError.unavailable(
                back ? "There is no previous navigation destination." : "There is no forward navigation destination."
            )
        }
        if let expectation = try historyPresentationExpectation(for: destination, model: model) {
            guard await presentationWaiter(expectation, model, shell) else {
                throw AgentControlCommandError.unavailable("The history destination was not presented before the bounded deadline.")
            }
        }
        try validateConnectionContext(context)
        guard shell.currentDestination(for: model) == destination else {
            throw AgentControlCommandError.conflict("The app did not remain on the requested history destination.")
        }
        stateDidChange()
        return .completed(["segment": .string(state().segment)])
    }

    private func historyPresentationExpectation(
        for destination: HerdrDestination,
        model: HerdrAppModel
    ) throws -> AgentControlPresentationExpectation? {
        switch destination {
        case let .pane(id):
            guard let pane = model.pane(id: id) else {
                throw AgentControlCommandError.notFound("The history pane is no longer available.")
            }
            return .pane(id: id, mode: pane.supportsPiSemanticChat ? .chat : .terminal)
        case let .git(id):
            guard model.pane(id: id) != nil else {
                throw AgentControlCommandError.notFound("The history pane is no longer available.")
            }
            return .pane(id: id, mode: .git)
        case .dashboard, .agentBoard, .workspace, .firstMate, .activeWork, .prReview, .fleet, .attention, .activity:
            return nil
        }
    }

    static func validateFirstMateHostSwitch(
        store: FirstMateStore,
        currentMachineID: String?,
        targetMachineID: String
    ) throws {
        guard currentMachineID == targetMachineID || !store.hasUnsentDrafts else {
            throw AgentControlCommandError.conflict("First Mate has an unsent draft; it was preserved.")
        }
    }

    private func openFirstMate(
        _ target: AgentControlTarget,
        shell: HerdrShellState,
        model: HerdrAppModel,
        command: AgentControlCommand,
        context: ExecutionContext
    ) async throws -> AgentControlExecutionResult {
        let machineID = try preferredMachineID(for: target)
        guard let featureID = target.featureId, !featureID.isEmpty else {
            throw AgentControlCommandError.stale("The First Mate target is incomplete.")
        }
        let name = command.parameters["inspector"]?.stringValue ?? "overview"
        guard let inspector = FirstMateInspector.allCases.first(where: { $0.rawValue.lowercased() == name }) else {
            throw AgentControlCommandError.invalid("Unsupported First Mate inspector.")
        }
        guard let configuration = model.firstMateConfiguration(machineID: machineID) else {
            throw AgentControlCommandError.unavailable("The First Mate companion is not configured.")
        }
        try Self.validateFirstMateHostSwitch(
            store: shell.firstMate,
            currentMachineID: shell.activeFirstMateMachineID,
            targetMachineID: machineID
        )

        // Validate with an isolated client first. A missing feature or network
        // failure must not reconfigure the shared store and disturb its UI.
        let client = firstMateClientFactory(configuration)
        let snapshot = try await client.fetchFirstMateFeature(featureID)
        try validateExecutionContext(context)
        guard snapshot.ok, snapshot.feature.id == featureID else {
            throw AgentControlCommandError.notFound("The First Mate feature no longer exists on that companion.")
        }

        // Commit the process-owned identity and exact destination before opening
        // the window. Window creation can synchronously build a new navigation
        // view whose connection task must recognize this configuration as the
        // one already installed rather than clearing the received feature.
        shell.configureFirstMateIfNeeded(
            machineID: machineID,
            configuration: configuration,
            connectionGeneration: model.connectionGeneration,
            isDemo: false,
            client: client
        )
        shell.firstMate.receive(snapshot)
        shell.firstMate.select(featureID)
        shell.firstMate.inspector = inspector
        shell.firstMate.graphMode = inspector == .workflow
        shell.showFirstMate(machineID: machineID, featureID: featureID, inspector: inspector, model: model)
        showMainWindow()
        stateDidChange()
        guard shell.firstMate.selectedFeatureID == featureID,
              shell.firstMate.inspector == inspector else {
            throw AgentControlCommandError.conflict("First Mate did not present the requested feature.")
        }
        return .completed(["presentation": .string("first-mate"), "inspector": .string(name)])
    }

    private func openHUDChat(
        _ target: AgentControlTarget,
        model: HerdrAppModel,
        context: ExecutionContext
    ) async throws -> AgentControlExecutionResult {
        let machineID = try preferredMachineID(for: target)
        guard let chatID = target.hudChatId, !chatID.isEmpty,
              let chats = hudController?.chats else {
            throw AgentControlCommandError.unavailable("The saved HUD chat target or HUD controller is unavailable.")
        }
        if let existing = chats.chats.first(where: { $0.session.historyIdentity == "\(machineID):\(chatID)" }),
           !existing.session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AgentControlCommandError.conflict("That HUD chat has an unsent draft; it was preserved.")
        }
        let localID = try await chats.openHistory(id: chatID, machineID: machineID, model: model)
        try validateExecutionContext(context)
        hudController?.openChat(localID)
        shell?.agentControlWindow = .hud
        stateDidChange()
        guard chats.selectedID == localID,
              chats.selectedChat?.session.historyIdentity == "\(machineID):\(chatID)" else {
            throw AgentControlCommandError.conflict("The HUD did not present the requested saved chat.")
        }
        return .completed(["presentation": .string("hud-chat"), "hudChatId": .string(chatID)])
    }

    private func applySidebar(_ parameters: [String: PiJSONValue], model: HerdrAppModel) {
        if let filter = parameters["filter"]?.stringValue {
            model.filter = switch filter {
            case "attention": .attention
            case "active": .active
            default: .all
            }
        }
        if let recency = parameters["recency"]?.stringValue, let value = SidebarRecency(rawValue: recency) {
            model.sidebarRecency = value
        }
        if let query = parameters["query"]?.stringValue { model.searchText = query }
    }

    private func executionContext(
        for command: AgentControlCommand,
        receiverGeneration: Int? = nil,
        host: Host? = nil
    ) throws -> ExecutionContext {
        let current = state()
        if let expected = command.expectedRevision, expected != current.revision {
            throw AgentControlCommandError.conflict("The app state changed; inspect the current receiver state and retry.")
        }
        guard let model else { throw AgentControlCommandError.unavailable("The app model is not configured.") }
        return ExecutionContext(
            receiverGeneration: receiverGeneration ?? self.receiverGeneration,
            connectionGeneration: host?.connectionGeneration ?? model.connectionGeneration,
            expectedRevision: command.expectedRevision,
            serverID: host?.serverID,
            hostMachineID: host?.machineID
        )
    }

    private func validateExecutionContext(_ context: ExecutionContext) throws {
        try validateConnectionContext(context)
        if let expectedRevision = context.expectedRevision, state().revision != expectedRevision {
            throw AgentControlCommandError.conflict("The app state changed while the command was awaiting a result.")
        }
    }

    private func validateConnectionContext(_ context: ExecutionContext) throws {
        guard context.receiverGeneration == receiverGeneration,
              let model, context.connectionGeneration == model.connectionGeneration else {
            throw AgentControlCommandError.stale("Connections changed while executing the command.")
        }
        if let serverID = context.serverID, let machineID = context.hostMachineID {
            guard let host = registeredHosts[serverID],
                  host.machineID == machineID,
                  host.connectionGeneration == context.connectionGeneration,
                  serverConnectionGenerations[serverID] == context.connectionGeneration else {
                throw AgentControlCommandError.stale("The receiving companion disconnected while executing the command.")
            }
        }
        try Task.checkCancellation()
    }

    private func validateTarget(_ target: AgentControlTarget?) throws {
        guard let target else { return }
        let identifiers = [
            target.serverId, target.machineId, target.workspaceId, target.tabId,
            target.paneId, target.terminalId, target.sessionId, target.hudChatId, target.featureId,
        ].compactMap { $0 }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:"))
        guard identifiers.allSatisfy({ value in
            !value.isEmpty && value.count <= 256 && value.unicodeScalars.allSatisfy(allowed.contains)
        }) else {
            throw AgentControlCommandError.invalid("Target identifiers must be bounded single-segment IDs.")
        }
        if let serverURL = target.serverURL,
           serverURL.count > 2_048 || serverURL.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            throw AgentControlCommandError.invalid("The target server URL is invalid.")
        }
        if let kind = target.kind,
           !["pane", "workspace", "tab", "hud-chat", "first-mate"].contains(kind) {
            throw AgentControlCommandError.invalid("Unsupported target kind.")
        }
    }

    private func requiredString(_ key: String, _ parameters: [String: PiJSONValue]) throws -> String {
        guard let value = parameters[key]?.stringValue, !value.isEmpty else {
            throw AgentControlCommandError.invalid("Missing parameter: \(key)")
        }
        return value
    }

    private func showMainWindow() {
        if hudController?.isExpanded == true { hudController?.collapse() }
        openMainWindow?()
        if !Self.isUnitTestProcess { NSApp.activate() }
        shell?.agentControlWindow = .main
    }

    private func noteHostConnected(_ host: Host) {
        registeredHosts[host.serverID] = host
        activeServerCount = registeredHosts.count
        statusText = "Listening on \(activeServerCount) companion\(activeServerCount == 1 ? "" : "s")"
    }

    private func releaseHost(
        machineID: String,
        receiverGeneration: Int,
        connectionGeneration: Int
    ) {
        guard receiverIsCurrent(receiverGeneration, connectionGeneration: connectionGeneration) else { return }
        let serverIDs = registeredHosts.compactMap {
            $0.value.machineID == machineID && $0.value.connectionGeneration == connectionGeneration ? $0.key : nil
        }
        for serverID in serverIDs {
            registeredHosts[serverID] = nil
            pendingAcknowledgements[serverID] = nil
            busyServerIDs.remove(serverID)
            commandQueue.removeAll { $0.host.serverID == serverID }
        }
        activeServerCount = registeredHosts.count
        statusText = activeServerCount == 0
            ? "No compatible authenticated companion is available"
            : "Listening on \(activeServerCount) companion\(activeServerCount == 1 ? "" : "s")"
    }

    private func receiverIsCurrent(
        _ receiverGeneration: Int,
        connectionGeneration: Int? = nil
    ) -> Bool {
        guard !Task.isCancelled, isEnabled, receiverGeneration == self.receiverGeneration else { return false }
        guard let connectionGeneration else { return true }
        return model?.connectionGeneration == connectionGeneration
    }

    private func hostIsCurrent(_ host: Host, receiverGeneration: Int) -> Bool {
        guard receiverIsCurrent(receiverGeneration, connectionGeneration: host.connectionGeneration),
              let registered = registeredHosts[host.serverID] else { return false }
        return registered.machineID == host.machineID
            && registered.connectionGeneration == host.connectionGeneration
            && serverConnectionGenerations[host.serverID] == host.connectionGeneration
    }

    private func ensureReceiverCurrent(
        _ receiverGeneration: Int,
        connectionGeneration: Int
    ) throws {
        guard receiverIsCurrent(receiverGeneration, connectionGeneration: connectionGeneration) else {
            throw CancellationError()
        }
    }

    private func sleepWhileCurrent(
        for duration: Duration,
        receiverGeneration: Int,
        connectionGeneration: Int
    ) async throws {
        try await Task.sleep(for: duration)
        try ensureReceiverCurrent(receiverGeneration, connectionGeneration: connectionGeneration)
    }

    #if DEBUG
    var receiverGenerationForTesting: Int { receiverGeneration }
    var configuredConnectionGenerationForTesting: Int? { configuredConnectionGeneration }
    var hasPollingTaskForTesting: Bool { pollTask != nil }
    var hasConnectionObservationForTesting: Bool { connectionObservationIsArmed }
    func serverIDForTesting(machineID: String) -> String? { serverID(for: machineID) }
    func restartForTesting() { restart() }
    func stopForTesting() { stop(status: "Stopped by test") }
    #endif

    private func state() -> AgentControlUIState {
        guard let model, let shell else {
            return AgentControlUIState(revision: stateRevision, window: .main, segment: "unconfigured", selection: nil, modal: nil, enabled: isEnabled)
        }
        let segment = shell.agentControlSegment(model: model)
        let observedWindow: AgentControlWindow = if hudController?.isExpanded == true {
            .hud
        } else if shell.agentControlWindow == .settings {
            .settings
        } else {
            shell.agentControlWindow == .hud ? .main : shell.agentControlWindow
        }
        let selection = stateSelection(window: observedWindow, segment: segment, model: model, shell: shell)
        let candidate = AgentControlUIState(
            revision: stateRevision,
            window: observedWindow,
            segment: segment,
            selection: selection,
            modal: effectiveModal(shell: shell),
            enabled: isEnabled
        )
        var fingerprint = candidate
        fingerprint.revision = 0
        if lastStateFingerprint != fingerprint {
            stateRevision &+= 1
            lastStateFingerprint = fingerprint
        }
        var result = candidate
        result.revision = stateRevision
        return result
    }

    private func stateSelection(
        window: AgentControlWindow,
        segment: String,
        model: HerdrAppModel,
        shell: HerdrShellState
    ) -> AgentControlTarget? {
        if window == .hud,
           let identity = hudController?.chats?.selectedChat?.session.historyIdentity,
           let separator = identity.lastIndex(of: ":") {
            let machineID = String(identity[..<separator])
            let chatID = String(identity[identity.index(after: separator)...])
            guard let serverID = serverID(for: machineID), !chatID.isEmpty else { return nil }
            return AgentControlTarget(kind: "hud-chat", serverId: serverID, machineId: machineID, hudChatId: chatID)
        }
        // Settings and a fresh HUD composer have no current navigable target;
        // never report a pane that is merely visible in a background window.
        guard window == .main else { return nil }
        if segment == "first-mate", let machineID = shell.activeFirstMateMachineID,
           let featureID = shell.firstMate.selectedFeatureID,
           let serverID = serverID(for: machineID) {
            return AgentControlTarget(kind: "first-mate", serverId: serverID, machineId: machineID, featureId: featureID)
        }
        if segment == "pr-review", let machineID = shell.prReviewMachineID,
           let reviewID = shell.prReview.selectedReviewID,
           let serverID = serverID(for: machineID) {
            return AgentControlTarget(kind: "pr-review", serverId: serverID, machineId: machineID, featureId: reviewID)
        }
        if segment == "workspace", let workspace = model.workspace(id: model.selectedWorkspaceID),
           let serverID = serverID(for: workspace.machineID) {
            if let tabID = shell.highlightedOverviewTabID {
                return AgentControlTarget(
                    kind: "tab", serverId: serverID, machineId: workspace.machineID,
                    workspaceId: workspace.workspaceID,
                    tabId: MachineScopedID.split(tabID)?.rawID ?? tabID
                )
            }
            return AgentControlTarget(
                kind: "workspace", serverId: serverID, machineId: workspace.machineID,
                workspaceId: workspace.workspaceID
            )
        }
        if ["chat", "terminal", "git", "skills"].contains(segment),
           let pane = model.pane(id: model.selectedPaneID),
           model.isPresentingPane(id: pane.id, mode: PaneDetailMode(rawValue: segment)),
           let serverID = serverID(for: pane.machineID) {
            return AgentControlTarget(
                kind: "pane", serverId: serverID, machineId: pane.machineID,
                workspaceId: pane.workspaceID, tabId: pane.tabID, paneId: pane.paneID,
                terminalId: pane.terminalID, sessionId: pane.piSemantic?.sessionID
            )
        }
        return nil
    }

    private func serverID(for machineID: String) -> String? {
        guard let model else { return nil }
        let connectionGeneration = model.connectionGeneration
        guard let mapping = serverToMachines.first(where: {
            $0.value.contains(machineID)
                && serverConnectionGenerations[$0.key] == connectionGeneration
        }) else { return nil }
        guard let host = registeredHosts[mapping.key] else {
            return model.isDemoMode ? mapping.key : nil
        }
        return modelConnectionMatches(host: host, machineID: machineID, model: model)
            ? mapping.key
            : nil
    }

    private func registeredHost(for machineID: String) -> Host? {
        guard let serverID = serverToMachines.first(where: { $0.value.contains(machineID) })?.key else {
            return nil
        }
        return registeredHosts[serverID]
    }

    /// Model snapshots and API clients are rebuilt by the process connection
    /// driver. Until that runtime carries this generation's exact configuration,
    /// never refresh or advertise its retained panes through a newly registered
    /// control host.
    private func modelConnectionMatches(
        host: Host,
        machineID: String,
        model: HerdrAppModel
    ) -> Bool {
        if model.isDemoMode { return true }
        guard model.canControl(machineID: machineID) else { return false }
        if let pane = model.workspaces.lazy.flatMap(\.panes).first(where: { $0.machineID == machineID }) {
            return model.serverConfiguration(for: pane) == host.configuration
        }
        if model.machines.first?.id == machineID {
            return model.activeServerConfiguration == host.configuration
        }
        return false
    }

    private func effectiveModal(shell: HerdrShellState) -> String? {
        if let modal = shell.agentControlBlockingModal { return modal }
        guard !Self.isUnitTestProcess else { return nil }
        if NSApp.modalWindow != nil || NSApp.windows.contains(where: { $0.attachedSheet != nil }) {
            return "system-dialog"
        }
        return nil
    }

    private func requirePRReviewOpen(shell: HerdrShellState, model: HerdrAppModel) throws {
        guard shell.resolvedScope(for: model) == .prReview, shell.prReview.selectedReviewID != nil else {
            throw AgentControlCommandError.disabled("Open a PR review first.")
        }
    }

    private func prReviewState(_ store: PRReviewStore) -> [String: PiJSONValue] {
        guard let review = store.snapshot?.review ?? store.selectedReview else { return [:] }
        let files: [PiJSONValue] = (store.snapshot?.files ?? []).prefix(400).map { file in
            .object([
                "path": .string(file.path),
                "impact": .string(file.impact?.rawValue ?? "unranked"),
                "guided_order": file.guidedOrder.map { .number(Double($0)) } ?? .null,
                "viewed": .bool(file.viewed),
                "additions": .number(Double(file.additions)),
                "deletions": .number(Double(file.deletions)),
                "status": .string(file.status),
            ])
        }
        let runs: [PiJSONValue] = (store.snapshot?.runs ?? []).map {
            .object([
                "id": .string($0.id),
                "skill_id": .string($0.skillID),
                "state": .string($0.state.rawValue),
            ])
        }
        let documents: [PiJSONValue] = (store.snapshot?.documents ?? []).map {
            .object([
                "id": .string($0.id),
                "kind": .string($0.kind.rawValue),
                "title": .string($0.title),
            ])
        }
        func lineObject(_ value: (path: String, start: Int, end: Int, side: PRReviewSide)?) -> PiJSONValue {
            guard let value else { return .null }
            return .object([
                "path": .string(value.path),
                "start": .number(Double(value.start)),
                "end": .number(Double(value.end)),
                "side": .string(value.side.rawValue),
            ])
        }
        return [
            "review_id": .string(review.id),
            "url": .string(review.url),
            "number": .number(Double(review.number)),
            "title": .string(review.title),
            "tab": .string(store.tab.rawValue),
            "view_mode": .string(store.viewMode.rawValue),
            "filter": .string(store.impactFilter.rawValue),
            "hide_viewed": .bool(store.hideViewed),
            "selected_path": store.selectedPath.map(PiJSONValue.string) ?? .null,
            "visible_lines": lineObject(store.visibleLines),
            "highlight": lineObject(store.highlight),
            "files": .array(files),
            "runs": .array(runs),
            "documents": .array(documents),
        ]
    }

    private static let modalBlockedActions: Set<String> = [
        "ui.open", "ui.segment", "ui.back", "ui.forward", "ui.reveal",
        "ui.settings", "ui.hud", "ui.notes", "ui.sidebar", "chat.summarize",
        "pr-review.open", "pr-review.select-file", "pr-review.scroll-to-line", "pr-review.highlight-lines", "pr-review.clear-highlight", "pr-review.set-filter", "pr-review.set-view-mode", "pr-review.set-tab",
    ]

    private static func waitForPresentation(
        _ expectation: AgentControlPresentationExpectation,
        model: HerdrAppModel,
        shell: HerdrShellState
    ) async -> Bool {
        for _ in 0..<40 {
            if Task.isCancelled { return false }
            switch expectation {
            case let .pane(id, mode):
                if shell.resolvedScope(for: model) == .session,
                   model.isPresentingPane(id: id, mode: mode) {
                    return true
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return false
            }
        }
        return false
    }

    private static func waitForVisibleLine(
        path: String,
        line: Int,
        side: PRReviewSide,
        store: PRReviewStore
    ) async -> Bool {
        for _ in 0..<40 {
            if Task.isCancelled { return false }
            if let visible = store.visibleLines,
               visible.path == path,
               visible.side == side,
               visible.start <= line,
               line <= visible.end {
                return true
            }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return false
            }
        }
        return false
    }

    private static func commandIsExpired(_ command: AgentControlCommand, now: Date = .now) -> Bool {
        guard let expiry = HerdrTimestamp.date(from: command.expiresAt) else { return true }
        return expiry <= now
    }

    private static func isPermanentAcknowledgementError(_ error: Error) -> Bool {
        if case let APIError.server(status, _) = error, status == 404 || status == 409 { return true }
        if let commandError = error as? AgentControlCommandError {
            return [
                "not_found", "conflict", "request_conflict", "state_conflict",
                "invalid_request", "invalid_receiver", "receiver_mismatch", "stale_target",
            ].contains(commandError.code)
        }
        return false
    }

    private static func isSafeServerID(_ value: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_:"))
        return value.hasPrefix("srv_") && value.count <= 128
            && value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static var isUnitTestProcess: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}
