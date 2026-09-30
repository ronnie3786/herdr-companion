import Foundation

// Wire models for the companion's SimPortal routes (first-mate-simulator-previews-v1).
// See docs/first-mate/simulator-previews.md. Unknown status strings are kept as
// they arrive and never read as ready or running.

/// A companion's SimPortal connection: whether builds can be saved and
/// simulators started on that machine right now.
struct FirstMateSimulatorStatus: Decodable, Equatable, Sendable {
    struct Storage: Decodable, Equatable, Sendable {
        let freeBytes: Int64?
        let minFreeBytes: Int64?
        let admissionAllowed: Bool?

        enum CodingKeys: String, CodingKey {
            case freeBytes = "free_bytes"
            case minFreeBytes = "min_free_bytes"
            case admissionAllowed = "admission_allowed"
        }
    }

    struct Policy: Decodable, Equatable, Sendable {
        let idleShutdownMinutes: Int
        let maxRunningPreviews: Int

        enum CodingKeys: String, CodingKey {
            case idleShutdownMinutes = "idle_shutdown_minutes"
            case maxRunningPreviews = "max_running_previews"
        }
    }

    let configured: Bool
    let state: String
    let reason: String?
    let registrationAvailable: Bool
    let previewAvailable: Bool
    let storage: Storage?
    let defaultDevice: FirstMateSimulatorDevice?
    let policy: Policy?
    let runningPreviews: Int

    enum CodingKeys: String, CodingKey {
        case configured, state, reason, storage, policy
        case registrationAvailable = "registration_available"
        case previewAvailable = "preview_available"
        case defaultDevice = "default_device"
        case runningPreviews = "running_previews"
    }

    init(configured: Bool, state: String, reason: String? = nil, registrationAvailable: Bool = false,
         previewAvailable: Bool = false, storage: Storage? = nil, defaultDevice: FirstMateSimulatorDevice? = nil,
         policy: Policy? = nil, runningPreviews: Int = 0) {
        self.configured = configured
        self.state = state
        self.reason = reason
        self.registrationAvailable = registrationAvailable
        self.previewAvailable = previewAvailable
        self.storage = storage
        self.defaultDevice = defaultDevice
        self.policy = policy
        self.runningPreviews = runningPreviews
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        configured = try container.decodeIfPresent(Bool.self, forKey: .configured) ?? false
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? "unavailable"
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        registrationAvailable = try container.decodeIfPresent(Bool.self, forKey: .registrationAvailable) ?? false
        previewAvailable = try container.decodeIfPresent(Bool.self, forKey: .previewAvailable) ?? false
        storage = try container.decodeIfPresent(Storage.self, forKey: .storage)
        defaultDevice = try container.decodeIfPresent(FirstMateSimulatorDevice.self, forKey: .defaultDevice)
        policy = try container.decodeIfPresent(Policy.self, forKey: .policy)
        runningPreviews = try container.decodeIfPresent(Int.self, forKey: .runningPreviews) ?? 0
    }

    /// Running previews can be watched and stopped (also while disk is low).
    var canWatch: Bool { state == "ready" || state == "storage_low" }
}

struct FirstMateSimulatorDevice: Decodable, Equatable, Sendable {
    let deviceType: String?
    let runtime: String?
    let deviceTypeName: String?
    let runtimeName: String?

    enum CodingKeys: String, CodingKey {
        case runtime
        case deviceType = "device_type"
        case deviceTypeName = "device_type_name"
        case runtimeName = "runtime_name"
    }

    /// "iPhone 17 Pro · iOS 26.2"
    var label: String? {
        let parts = [deviceTypeName, runtimeName].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var isTablet: Bool { (deviceTypeName ?? deviceType ?? "").localizedCaseInsensitiveContains("iPad") }
}

struct FirstMateSimulatorProblem: Decodable, Equatable, Sendable {
    let code: String?
    let message: String?
}

/// A saved simulator build: one checkpoint of a feature.
struct FirstMateSimulatorBuild: Decodable, Identifiable, Equatable, Sendable {
    struct App: Decodable, Equatable, Sendable {
        let name: String?
        let bundleID: String?
        let version: String?
        let build: String?
        let minimumOS: String?

        enum CodingKeys: String, CodingKey {
            case name, version, build
            case bundleID = "bundle_id"
            case minimumOS = "minimum_os"
        }
    }

    struct Source: Decodable, Equatable, Sendable {
        let revision: String?
        let workingTree: String?
        let configuration: String?
        let target: String?

        enum CodingKeys: String, CodingKey {
            case revision, configuration, target
            case workingTree = "working_tree"
        }
    }

    let id: String
    let featureID: String
    let name: String
    let checkpointID: String
    let checkpointLabel: String
    let stageTitle: String?
    let visitID: String?
    let assignmentID: String?
    let hubBuildID: String?
    let origin: String
    let status: String
    let statusDetail: String?
    let app: App?
    let source: Source?
    let error: FirstMateSimulatorProblem?
    let launchable: Bool
    let createdAt: String
    let previews: [FirstMateSimulatorPreview]

    enum CodingKeys: String, CodingKey {
        case id, name, origin, status, app, source, error, launchable, previews
        case featureID = "feature_id"
        case checkpointID = "checkpoint_id"
        case checkpointLabel = "checkpoint_label"
        case stageTitle = "stage_title"
        case visitID = "visit_id"
        case assignmentID = "assignment_id"
        case hubBuildID = "hub_build_id"
        case statusDetail = "status_detail"
        case createdAt = "created_at"
    }

    init(id: String, featureID: String, name: String, checkpointID: String, checkpointLabel: String,
         stageTitle: String? = nil, visitID: String? = nil, assignmentID: String? = nil, hubBuildID: String? = nil,
         origin: String = "agent", status: String, statusDetail: String? = nil, app: App? = nil,
         source: Source? = nil, error: FirstMateSimulatorProblem? = nil, launchable: Bool, createdAt: String,
         previews: [FirstMateSimulatorPreview] = []) {
        self.id = id
        self.featureID = featureID
        self.name = name
        self.checkpointID = checkpointID
        self.checkpointLabel = checkpointLabel
        self.stageTitle = stageTitle
        self.visitID = visitID
        self.assignmentID = assignmentID
        self.hubBuildID = hubBuildID
        self.origin = origin
        self.status = status
        self.statusDetail = statusDetail
        self.app = app
        self.source = source
        self.error = error
        self.launchable = launchable
        self.createdAt = createdAt
        self.previews = previews
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        featureID = try container.decode(String.self, forKey: .featureID)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Simulator build"
        checkpointID = try container.decodeIfPresent(String.self, forKey: .checkpointID) ?? ""
        checkpointLabel = try container.decodeIfPresent(String.self, forKey: .checkpointLabel) ?? "Checkpoint"
        stageTitle = try container.decodeIfPresent(String.self, forKey: .stageTitle)
        visitID = try container.decodeIfPresent(String.self, forKey: .visitID)
        assignmentID = try container.decodeIfPresent(String.self, forKey: .assignmentID)
        hubBuildID = try container.decodeIfPresent(String.self, forKey: .hubBuildID)
        origin = try container.decodeIfPresent(String.self, forKey: .origin) ?? "agent"
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        statusDetail = try container.decodeIfPresent(String.self, forKey: .statusDetail)
        app = try container.decodeIfPresent(App.self, forKey: .app)
        source = try container.decodeIfPresent(Source.self, forKey: .source)
        error = try container.decodeIfPresent(FirstMateSimulatorProblem.self, forKey: .error)
        // Only an explicit true opens a simulator.
        launchable = try container.decodeIfPresent(Bool.self, forKey: .launchable) ?? false
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        previews = try container.decodeIfPresent([FirstMateSimulatorPreview].self, forKey: .previews) ?? []
    }

    var date: Date? { HerdrTimestamp.date(from: createdAt) }

    /// "Receipts 1.4 (212)", or nil before SimPortal reports the app.
    var appLabel: String? {
        guard let app else { return nil }
        var text = app.name ?? ""
        if let version = app.version {
            text += text.isEmpty ? version : " \(version)"
            if let build = app.build, build != version { text += " (\(build))" }
        }
        return text.isEmpty ? nil : text
    }

    /// A preview of this build that is starting or running, newest first.
    var activePreview: FirstMateSimulatorPreview? {
        previews.first { $0.isActive }
    }

    /// What the row says when the build cannot be opened.
    var unavailableReason: String? {
        guard !launchable else { return nil }
        switch status {
        case "registering": return "Saving to SimPortal…"
        case "failed": return error?.message.map { "Not saved: \($0)" } ?? "SimPortal could not save this build"
        case "deleted": return "Removed from SimPortal"
        case "unavailable": return statusDetail ?? "Unavailable on this machine's SimPortal"
        case "cancelled": return "Saving was cancelled"
        case "interrupted", "outcome_unknown": return "Saving was interrupted; check SimPortal"
        default: return statusDetail ?? "Not available (\(status.replacingOccurrences(of: "_", with: " ")))"
        }
    }
}

/// One simulator SimPortal started for a build, as the companion tracks it.
struct FirstMateSimulatorPreview: Decodable, Identifiable, Equatable, Sendable {
    struct Step: Decodable, Equatable, Sendable {
        let name: String
        let state: String
    }

    struct Operation: Decodable, Equatable, Sendable {
        let id: String
        let kind: String
        let status: String
        let step: String?
        let steps: [Step]
        let error: FirstMateSimulatorProblem?
    }

    struct Observation: Decodable, Equatable, Sendable {
        let deviceState: String?
        let viewerCount: Int?

        enum CodingKeys: String, CodingKey {
            case deviceState = "device_state"
            case viewerCount = "viewer_count"
        }
    }

    struct Links: Decodable, Equatable, Sendable {
        let local: URL?
        let tailnet: URL?
    }

    struct Idle: Decodable, Equatable, Sendable {
        let shutdownAfterMinutes: Int
        let shutdownAt: String?
        let watchers: Int

        enum CodingKeys: String, CodingKey {
            case watchers
            case shutdownAfterMinutes = "shutdown_after_minutes"
            case shutdownAt = "shutdown_at"
        }
    }

    let id: String
    let featureID: String
    let buildID: String
    let phase: String
    let status: String
    let device: FirstMateSimulatorDevice?
    let stopReason: String?
    let updatedAt: String?
    // Detail responses only.
    let udid: String?
    let streamAvailable: Bool
    let operation: Operation?
    let observation: Observation?
    let error: FirstMateSimulatorProblem?
    let browserLinks: Links?
    let idle: Idle?

    enum CodingKeys: String, CodingKey {
        case id, phase, status, device, udid, operation, observation, error, idle
        case featureID = "feature_id"
        case buildID = "build_id"
        case stopReason = "stop_reason"
        case updatedAt = "updated_at"
        case streamAvailable = "stream_available"
        case browserLinks = "browser_links"
    }

    init(id: String, featureID: String, buildID: String, phase: String, status: String,
         device: FirstMateSimulatorDevice? = nil, stopReason: String? = nil, updatedAt: String? = nil,
         udid: String? = nil, streamAvailable: Bool = false, operation: Operation? = nil,
         observation: Observation? = nil, error: FirstMateSimulatorProblem? = nil, browserLinks: Links? = nil,
         idle: Idle? = nil) {
        self.id = id
        self.featureID = featureID
        self.buildID = buildID
        self.phase = phase
        self.status = status
        self.device = device
        self.stopReason = stopReason
        self.updatedAt = updatedAt
        self.udid = udid
        self.streamAvailable = streamAvailable
        self.operation = operation
        self.observation = observation
        self.error = error
        self.browserLinks = browserLinks
        self.idle = idle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        featureID = try container.decode(String.self, forKey: .featureID)
        buildID = try container.decode(String.self, forKey: .buildID)
        phase = try container.decodeIfPresent(String.self, forKey: .phase) ?? "unknown"
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        device = try container.decodeIfPresent(FirstMateSimulatorDevice.self, forKey: .device)
        stopReason = try container.decodeIfPresent(String.self, forKey: .stopReason)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        udid = try container.decodeIfPresent(String.self, forKey: .udid)
        streamAvailable = try container.decodeIfPresent(Bool.self, forKey: .streamAvailable) ?? false
        operation = try container.decodeIfPresent(Operation.self, forKey: .operation)
        observation = try container.decodeIfPresent(Observation.self, forKey: .observation)
        error = try container.decodeIfPresent(FirstMateSimulatorProblem.self, forKey: .error)
        browserLinks = try container.decodeIfPresent(Links.self, forKey: .browserLinks)
        idle = try container.decodeIfPresent(Idle.self, forKey: .idle)
    }

    var isActive: Bool { phase == "starting" || phase == "running" }
}

struct FirstMateSimulatorFeatureSummary: Decodable, Equatable, Sendable {
    let id: String
    let title: String?
    let label: String?
    let emoji: String?
}

struct FirstMateSimulatorBuildList: Decodable, Sendable {
    let featureID: String
    let simulator: FirstMateSimulatorStatus
    let builds: [FirstMateSimulatorBuild]
    let selectedBuildID: String?

    enum CodingKeys: String, CodingKey {
        case simulator, builds
        case featureID = "feature_id"
        case selectedBuildID = "selected_build_id"
    }
}

struct FirstMateSimulatorOpenResponse: Decodable, Sendable {
    let preview: FirstMateSimulatorPreview
    let reused: Bool
    let stoppedToMakeRoom: [FirstMateSimulatorPreview]

    enum CodingKeys: String, CodingKey {
        case preview, reused
        case stoppedToMakeRoom = "stopped_to_make_room"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preview = try container.decode(FirstMateSimulatorPreview.self, forKey: .preview)
        reused = try container.decodeIfPresent(Bool.self, forKey: .reused) ?? false
        stoppedToMakeRoom = try container.decodeIfPresent([FirstMateSimulatorPreview].self, forKey: .stoppedToMakeRoom) ?? []
    }
}

struct FirstMateSimulatorPreviewDetail: Decodable, Sendable {
    let preview: FirstMateSimulatorPreview
    let build: FirstMateSimulatorBuild?
    let feature: FirstMateSimulatorFeatureSummary?
    let simulator: FirstMateSimulatorStatus?
}

struct FirstMateSimulatorPreviewEnvelope: Decodable, Sendable {
    let preview: FirstMateSimulatorPreview
}

/// SimPortal's start and stop steps, in the words the window shows.
enum FirstMateSimulatorPolicyText {
    /// "1 hour", "90 minutes", "2 hours"; short: "1 hr", "90 min".
    static func duration(minutes: Int, short: Bool = false) -> String {
        if minutes >= 60, minutes % 60 == 0 {
            let hours = minutes / 60
            return short ? "\(hours) hr" : hours == 1 ? "an hour" : "\(hours) hours"
        }
        return short ? "\(minutes) min" : minutes == 1 ? "a minute" : "\(minutes) minutes"
    }
}

enum FirstMateSimulatorStepText {
    static let startSteps = ["validating", "staging_app", "creating_simulator", "booting", "installing", "launching", "checking_stream"]

    static func title(for step: String) -> String {
        switch step {
        case "validating": "Checking the build"
        case "staging_app": "Preparing the app"
        case "creating_simulator": "Creating the simulator"
        case "booting": "Booting iOS"
        case "installing": "Installing the app"
        case "launching": "Launching the app"
        case "checking_stream": "Checking the picture"
        case "releasing_stream": "Releasing the stream"
        case "shutting_down": "Shutting down"
        default: step.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
