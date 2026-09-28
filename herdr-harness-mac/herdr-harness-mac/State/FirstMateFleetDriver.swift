import AppKit
import Foundation

/// The machines First Mate's fleet index observes: every machine with a
/// First Mate configuration, with the connection generation and demo flag.
struct FirstMateFleetRoster {
    /// What restarts observation: machine identity, name, and credentials.
    /// Held in memory only; it contains tokens.
    struct Identity: Hashable {
        struct Machine: Hashable {
            let id: String
            let name: String
            let urlString: String
            let token: String
        }

        let isDemo: Bool
        let generation: Int
        let machines: [Machine]
    }

    var isDemo: Bool
    var connectionGeneration: Int
    /// Configured machines, in roster order.
    var machines: [HerdrMachine]
    var configurations: [String: ServerConfiguration]

    static let empty = FirstMateFleetRoster(isDemo: false, connectionGeneration: 0, machines: [], configurations: [:])

    var identity: Identity {
        Identity(
            isDemo: isDemo,
            generation: connectionGeneration,
            machines: machines.compactMap { machine in
                guard let configuration = configurations[machine.id] else { return nil }
                return .init(id: machine.id, name: machine.name, urlString: configuration.baseURL.absoluteString, token: configuration.token)
            }
        )
    }

    /// Demo mode observes nothing: the empty roster also clears fleet data a
    /// previous connection left behind.
    func sources(makeClient: (ServerConfiguration) -> any FirstMateClient) -> [FirstMateFleetSource] {
        guard !isDemo else { return [] }
        return machines.compactMap { machine in
            guard let configuration = configurations[machine.id] else { return nil }
            return FirstMateFleetSource(machine: machine, configuration: configuration, client: makeClient(configuration))
        }
    }

    @MainActor
    static func current(model: HerdrAppModel) -> FirstMateFleetRoster {
        let configurations = Dictionary(uniqueKeysWithValues: model.machines.compactMap { machine in
            model.firstMateConfiguration(machineID: machine.id).map { (machine.id, $0) }
        })
        return FirstMateFleetRoster(
            isDemo: model.isDemoMode,
            connectionGeneration: model.connectionGeneration,
            machines: model.machines.filter { configurations[$0.id] != nil },
            configurations: configurations
        )
    }
}

/// Keeps First Mate's fleet index observed for the life of the process.
///
/// The main window used to observe the index from a view task, so closing it
/// stopped polling and froze the Dock badge, the Dock menu, and the chat
/// window's list. The driver belongs to the process instead: either window
/// starts it (idempotently), and it keeps running with every window closed.
///
/// It samples the roster every second, like `HerdrConnectionDriver`'s pulse,
/// and on any machine, name, credential, generation, or demo change it
/// reconciles the shell's cached stores and restarts observation. The index
/// polls every 10 s while Herdr is the active app and every 30 s in the
/// background, and refreshes at once on activation. Under XCTest it is inert
/// unless a test asks otherwise.
@MainActor
final class FirstMateFleetDriver {
    static let activeInterval: Duration = .seconds(10)
    static let backgroundInterval: Duration = .seconds(30)
    static let sampleInterval: Duration = .seconds(1)

    /// The unit-test bundle is hosted by the real app; its windows must not
    /// start live polling.
    static var isHostedByTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
    }

    let fleet: FirstMateFleetIndex
    private let reconcile: @MainActor (FirstMateFleetRoster) -> Void
    private let makeClient: @MainActor (ServerConfiguration) -> any FirstMateClient
    private let isInert: Bool
    private let sampleInterval: Duration
    private let activeInterval: Duration
    private let backgroundInterval: Duration

    private var roster: (@MainActor () -> FirstMateFleetRoster)?
    private var samplingTask: Task<Void, Never>?
    private var activityTasks: [Task<Void, Never>] = []
    private var observeTask: Task<Void, Never>?
    private var observeToken = 0
    private(set) var observedIdentity: FirstMateFleetRoster.Identity?
    /// How many times observation (re)started. Tests read it.
    private(set) var observationStarts = 0
    private(set) var isApplicationActive = true

    init(
        fleet: FirstMateFleetIndex,
        reconcile: @escaping @MainActor (FirstMateFleetRoster) -> Void,
        makeClient: @escaping @MainActor (ServerConfiguration) -> any FirstMateClient = { HerdrAPIClient(configuration: $0) },
        isInert: Bool = FirstMateFleetDriver.isHostedByTests,
        sampleInterval: Duration = FirstMateFleetDriver.sampleInterval,
        activeInterval: Duration = FirstMateFleetDriver.activeInterval,
        backgroundInterval: Duration = FirstMateFleetDriver.backgroundInterval
    ) {
        self.fleet = fleet
        self.reconcile = reconcile
        self.makeClient = makeClient
        self.isInert = isInert
        self.sampleInterval = sampleInterval
        self.activeInterval = activeInterval
        self.backgroundInterval = backgroundInterval
    }

    var isRunning: Bool { samplingTask != nil }

    /// Starts the driver for the app model's roster. Safe to call on every
    /// window appearance: only the first call starts anything.
    func start(model: HerdrAppModel) {
        start { [weak model] in model.map(FirstMateFleetRoster.current(model:)) ?? .empty }
    }

    /// Starts the driver with a roster provider (tests inject one).
    func start(roster: @escaping @MainActor () -> FirstMateFleetRoster) {
        guard !isInert, samplingTask == nil else { return }
        self.roster = roster
        applicationActivityChanged(isActive: NSApp?.isActive ?? true, refresh: false)
        let interval = sampleInterval
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.sync()
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
        activityTasks = [
            Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                    self?.applicationActivityChanged(isActive: true)
                }
            },
            Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: NSApplication.didResignActiveNotification) {
                    self?.applicationActivityChanged(isActive: false)
                }
            },
        ]
    }

    /// Stops sampling and observation (tests; the app never stops it).
    func stop() {
        samplingTask?.cancel()
        samplingTask = nil
        activityTasks.forEach { $0.cancel() }
        activityTasks = []
        observeTask?.cancel()
        observeTask = nil
        observedIdentity = nil
        roster = nil
    }

    /// Compares the roster with the observed one and restarts observation on
    /// a change. Also resumes observing when the previous observation ended
    /// and nothing else observes the index (for example after the chat
    /// window's fallback observer stopped).
    func sync() {
        guard let roster else { return }
        let current = roster()
        let identity = current.identity
        let changed = identity != observedIdentity
        let lapsed = observeTask == nil && !fleet.hasObserver && !identity.isDemo && !identity.machines.isEmpty
        guard changed || lapsed else { return }
        if changed {
            observedIdentity = identity
            // Connection-owned First Mate stores are reconciled on every
            // roster or credential change, whether or not First Mate is on
            // screen.
            reconcile(current)
        }
        observeTask?.cancel()
        observeToken &+= 1
        observationStarts += 1
        let token = observeToken
        let sources = current.sources(makeClient: makeClient)
        let generation = current.connectionGeneration
        let fleet = fleet
        observeTask = Task { [weak self] in
            await fleet.observe(sources: sources, connectionGeneration: generation)
            guard let self, self.observeToken == token else { return }
            self.observeTask = nil
        }
    }

    /// 10 s while Herdr is active, 30 s in the background. Activation also
    /// refreshes at once, because a 30 s wait already running is not cut short.
    func applicationActivityChanged(isActive: Bool, refresh: Bool = true) {
        isApplicationActive = isActive
        applyPollingInterval()
        guard isActive, refresh, observeTask != nil else { return }
        let fleet = fleet
        Task { await fleet.refresh() }
    }

    /// The First Mate HUD's faster interval while it shows (nil when hidden).
    /// It floats over other apps, so it must not slow to the background rate.
    private(set) var hudInterval: Duration?

    /// Sets or clears the HUD's interval. Showing the HUD also refreshes at
    /// once, so it never opens on a list up to 30 s old.
    func setHudPolling(_ interval: Duration?) {
        guard hudInterval != interval else { return }
        hudInterval = interval
        applyPollingInterval()
        guard interval != nil, observeTask != nil else { return }
        let fleet = fleet
        Task { await fleet.refresh() }
    }

    /// The shortest interval anything asks for.
    static func pollingInterval(isActive: Bool, hud: Duration?, active: Duration, background: Duration) -> Duration {
        let base = isActive ? active : background
        guard let hud else { return base }
        return min(base, hud)
    }

    private func applyPollingInterval() {
        fleet.pollingInterval = Self.pollingInterval(
            isActive: isApplicationActive, hud: hudInterval, active: activeInterval, background: backgroundInterval)
    }
}
