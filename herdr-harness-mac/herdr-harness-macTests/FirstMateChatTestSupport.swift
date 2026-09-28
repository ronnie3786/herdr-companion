import Foundation
@testable import herdr_harness_mac

/// A scripted First Mate companion for the chat window's model tests. Every
/// answer can be swapped between calls; calls are counted.
final class SyntheticChatFleetClient: FirstMateClient, @unchecked Sendable {
    typealias ReadHandler = @Sendable (_ featureID: String, _ messageID: String) async throws -> FirstMateReadResponse

    private let lock = NSLock()
    private var _capabilities: Result<[String], APIError>
    private var _features: Result<[FirstMateFeature], APIError>
    private var _fleet: Result<[FirstMateFleetEntry], APIError>
    private var _read: ReadHandler
    private var _snapshots: [String: FirstMateSnapshot] = [:]
    private var _capabilityCalls = 0
    private var _featureListCalls = 0
    private var _featureCalls = 0
    private var _fleetCalls = 0
    private var _reads: [(featureID: String, messageID: String)] = []

    init(
        capabilities: Result<[String], APIError> = .success(["first-mate-v1", "first-mate-fleet-v1"]),
        features: [FirstMateFeature] = [],
        fleet: [FirstMateFleetEntry] = [],
        read: ReadHandler? = nil
    ) {
        _capabilities = capabilities
        _features = .success(features)
        _fleet = .success(fleet)
        _read = read ?? { featureID, messageID in
            FirstMateReadResponse(featureID: featureID, readThroughMessageID: messageID, unread: false)
        }
    }

    var capabilities: Result<[String], APIError> {
        get { lock.withLock { _capabilities } }
        set { lock.withLock { _capabilities = newValue } }
    }
    var features: Result<[FirstMateFeature], APIError> {
        get { lock.withLock { _features } }
        set { lock.withLock { _features = newValue } }
    }
    var fleet: Result<[FirstMateFleetEntry], APIError> {
        get { lock.withLock { _fleet } }
        set { lock.withLock { _fleet = newValue } }
    }
    var read: ReadHandler {
        get { lock.withLock { _read } }
        set { lock.withLock { _read = newValue } }
    }
    var snapshots: [String: FirstMateSnapshot] {
        get { lock.withLock { _snapshots } }
        set { lock.withLock { _snapshots = newValue } }
    }
    var capabilityCalls: Int { lock.withLock { _capabilityCalls } }
    var featureListCalls: Int { lock.withLock { _featureListCalls } }
    var featureCalls: Int { lock.withLock { _featureCalls } }
    var fleetCalls: Int { lock.withLock { _fleetCalls } }
    var reads: [(featureID: String, messageID: String)] { lock.withLock { _reads } }
    /// Runs before the capability probe answers (tests that check overlap).
    private var _beforeCapabilities: (@Sendable () async -> Void)?
    var beforeCapabilities: (@Sendable () async -> Void)? {
        get { lock.withLock { _beforeCapabilities } }
        set { lock.withLock { _beforeCapabilities = newValue } }
    }

    func fetchFirstMateCapabilities() async throws -> FirstMateCapabilities {
        let (result, before) = lock.withLock { _capabilityCalls += 1; return (_capabilities, _beforeCapabilities) }
        await before?()
        return FirstMateCapabilities(ok: true, capabilities: try result.get())
    }
    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList {
        let result = lock.withLock { _featureListCalls += 1; return _features }
        return FirstMateFeatureList(ok: true, features: try result.get())
    }
    func fetchFirstMateFleet() async throws -> FirstMateFleetResponse {
        let result = lock.withLock { _fleetCalls += 1; return _fleet }
        return FirstMateFleetResponse(features: try result.get())
    }
    func markFirstMateRead(featureID: String, throughMessageID: String) async throws -> FirstMateReadResponse {
        let handler = lock.withLock { _reads.append((featureID, throughMessageID)); return _read }
        return try await handler(featureID, throughMessageID)
    }
    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot {
        let snapshot = lock.withLock { _featureCalls += 1; return _snapshots[id] }
        if let snapshot { return snapshot }
        if case .success(let features) = features, let feature = features.first(where: { $0.id == id }) {
            return FirstMateSnapshot(feature: feature)
        }
        throw APIError.invalidResponse
    }
    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse { throw APIError.invalidResponse }
    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse { throw APIError.invalidResponse }
}

/// Holds one asynchronous answer until the test releases it.
actor ChatTestGate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var opened = false
    private(set) var arrived = false

    func wait() async {
        arrived = true
        guard !opened else { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func open() {
        opened = true
        waiting?.resume()
        waiting = nil
    }
}

enum ChatFixtures {
    static func feature(
        _ id: String,
        title: String? = nil,
        status: String = "running",
        archived: Bool = false,
        activityAt: String? = nil,
        latestMessage: String? = nil
    ) -> FirstMateFeature {
        var feature = FirstMateDemo.newFeature(title: title ?? "Synthetic \(id)", goal: "A synthetic goal", cwd: "/tmp/synthetic", id: id).feature
        feature.status = status
        if archived { feature.archivedAt = "2030-01-01T00:00:00Z" }
        if activityAt != nil || latestMessage != nil {
            feature.dashboardSummary = FirstMateDashboardSummary(
                currentStageTitle: nil, currentStageIndex: nil, stageCount: 0, latestMessage: latestMessage,
                latestMessageAt: activityAt, needsUser: false, needsUserPrompt: nil, assignmentCount: 0,
                runningAssignmentCount: 0, activityAt: activityAt
            )
        }
        return feature
    }

    static func entry(
        _ id: String,
        hud: FirstMateHudStatus,
        unread: Bool = true,
        latestFirstMate: String? = "fmm_\(UUID().uuidString.prefix(8))",
        latest: FirstMateFleetLatestMessage? = nil,
        activityAt: String? = "2030-01-01T10:00:00Z",
        archived: Bool = false,
        step: Int? = nil
    ) -> FirstMateFleetEntry {
        let status: String = switch hud {
        case .blocked: "blocked"
        case .turn, .ready: "awaiting_direction"
        case .working: "running"
        case .idle, .unknown: "ready"
        case .done: "completed"
        }
        return FirstMateFleetEntry(
            featureID: id, title: "Synthetic \(id)", status: status, hudStatus: hud, stepIndex: step,
            latestMessage: latest ?? latestFirstMate.map { .init(id: $0, role: "assistant", text: "Update for \(id)", createdAt: activityAt) },
            latestFirstMateMessageID: latestFirstMate, unread: unread, activityAt: activityAt,
            archivedAt: archived ? "2030-01-01T00:00:00Z" : nil
        )
    }

    static func host(
        _ id: String,
        name: String? = nil,
        features: [FirstMateFeature] = [],
        entries: [FirstMateFleetEntry]? = nil,
        error: String? = nil
    ) -> FirstMateFleetHost {
        FirstMateFleetHost(
            machineID: id, machineName: name ?? "\(id.capitalized) Mac", features: features, isLoading: false,
            error: error, unsupported: false, lastUpdated: Date(timeIntervalSince1970: 1_900_000_000),
            supportsFleet: entries != nil,
            fleetEntries: entries.map { Dictionary($0.map { ($0.featureID, $0) }, uniquingKeysWith: { first, _ in first }) }
        )
    }

    static func machine(_ id: String) -> HerdrMachine {
        HerdrMachine(id: id, name: "\(id.capitalized) Mac", urlString: "https://\(id).example.invalid")
    }

    static func source(_ id: String, client: SyntheticChatFleetClient, token: String = "token") -> FirstMateFleetSource {
        let machine = machine(id)
        return FirstMateFleetSource(
            machine: machine,
            configuration: ServerConfiguration(urlString: machine.urlString, token: "\(id)-\(token)")!,
            client: client
        )
    }

    @MainActor
    static func model(demo: Bool) -> HerdrAppModel {
        let name = "FirstMateChatTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return HerdrAppModel(
            credentials: TestCredentialStore(),
            arguments: demo ? ["HerdrTests", "-HerdrDemoMode", "-HerdrResetSidebarState"] : ["HerdrTests"],
            userDefaults: defaults,
            configuredMachines: []
        )
    }

    @MainActor
    static func shell() -> HerdrShellState {
        let name = "FirstMateChatTests.shell.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return HerdrShellState(userDefaults: defaults)
    }

    /// Fails instead of hanging when a condition is not met in time.
    @MainActor
    static func waitUntil(_ description: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { throw ChatTestTimeout(description: description) }
            try await clock.sleep(for: .milliseconds(5))
        }
    }

    static func conversation(
        _ title: String,
        hud: FirstMateHudStatus,
        step: Int? = nil,
        activityAt: Date? = nil,
        unread: Bool = false
    ) -> FirstMateConversation {
        FirstMateConversation(
            id: FirstMateFleetFeatureID(machineID: "local", featureID: title), machineID: "local", machineName: "Local Mac",
            featureID: title, title: title, label: title, emoji: "🧪", hudStatus: hud, featureStatus: "running",
            stepIndex: step, stepFraction: nil, now: nil, previewText: "", previewIsFromUser: false,
            isWorkingOnReply: false, activityAt: activityAt, latestFirstMateMessageID: nil, isUnread: unread, isArchived: false
        )
    }
}

struct ChatTestTimeout: Error, CustomStringConvertible {
    let description: String
}
