import Foundation

enum PRReviewImpact: String, Codable, Equatable, Sendable {
    case low
    case medium
    case high
    case unknown

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }
}

enum PRReviewStatus: String, Codable, Equatable, Sendable {
    case preparing
    case ready
    case failed
    case unknown

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }
}

enum PRReviewRankingState: String, Codable, Equatable, Sendable {
    case idle
    case running
    case done
    case failed
    case unknown

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }
}

enum PRReviewRunState: String, Codable, Equatable, Sendable {
    case queued
    case running
    case finished
    case failed
    case ended
    case unknown

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }
}

enum PRReviewDocumentKind: String, Codable, Equatable, Sendable {
    case markdown
    case html
    case audio
    case video
    case link
    case file
    case unknown

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }
}

enum PRReviewSkillKind: String, Codable, Equatable, Sendable {
    case review
    case explainer
    case utility
    case custom
    case unknown

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }
}

/// Deleted is an explicit companion status, never inferred from removal
/// counts, filenames, or red hunks. Both the file list and the diff endpoint
/// report the same stable value.
enum PRReviewDeletedStatus {
    static func matches(_ status: String) -> Bool {
        status.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("deleted") == .orderedSame
    }
}

extension PRReviewFile {
    var isDeleted: Bool { PRReviewDeletedStatus.matches(status) }
}

extension PRReviewDiffFile {
    var isDeleted: Bool { PRReviewDeletedStatus.matches(status) }
}

enum PRReviewSide: String, Codable, Equatable, Sendable {
    case before
    case after

    /// The diff UI uses before/after, while the Companion file-text endpoint
    /// intentionally exposes the stable old/new vocabulary.
    var wireSide: String {
        switch self {
        case .before: "old"
        case .after: "new"
        }
    }
}

struct PRReviewSelection: Equatable, Sendable {
    struct Span: Equatable, Sendable {
        var side: PRReviewSide
        var start: Int
        var end: Int
    }

    var path: String
    var oldPath: String
    var spans: [Span]
    var text: String
    /// Kept with the transient selection so existing review callbacks can carry
    /// the composer text without expanding every view's callback signature.
    var question: String? = nil
}

enum PRReviewTab: String, Codable, CaseIterable, Equatable, Sendable {
    case files
    case context
    case agents
    case skills
}

enum PRReviewViewMode: String, Codable, CaseIterable, Equatable, Sendable {
    case github
    case guided
}

enum PRReviewImpactFilter: String, Codable, CaseIterable, Equatable, Sendable {
    case all
    case high
    case medium
    case low
    case unranked
}

struct PRReviewSummary: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var url: String
    var owner: String
    var repo: String
    var number: Int
    var title: String
    var author: String
    var baseRef: String
    var headRef: String
    var baseSHA: String
    var headSHA: String
    var mergeBaseSHA: String?
    var githubState: String
    var isDraft: Bool
    var status: PRReviewStatus
    var error: String?
    var checkoutPath: String?
    var workspaceID: String?
    var tabID: String?
    var workspaceError: String?
    var additions: Int
    var deletions: Int
    var changedFiles: Int
    var rankingState: PRReviewRankingState
    var rankingError: String?
    var archivedAt: String?
    var createdAt: String?
    var updatedAt: String?
    var preparedAt: String?
    var revision: Int
    var runningRuns: Int
    var documentCount: Int
    var body: String?
    var viewerReview: DashboardReviewState? = nil
    var skillRuns: [DashboardSkillRun]? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case url
        case owner
        case repo
        case number
        case title
        case author
        case baseRef = "base_ref"
        case headRef = "head_ref"
        case baseSHA = "base_sha"
        case headSHA = "head_sha"
        case mergeBaseSHA = "merge_base_sha"
        case githubState = "github_state"
        case isDraft = "is_draft"
        case status
        case error
        case checkoutPath = "checkout_path"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case workspaceError = "workspace_error"
        case additions
        case deletions
        case changedFiles = "changed_files"
        case rankingState = "ranking_state"
        case rankingError = "ranking_error"
        case archivedAt = "archived_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case preparedAt = "prepared_at"
        case revision
        case runningRuns = "running_runs"
        case documentCount = "document_count"
        case body
        case viewerReview = "viewer_review", skillRuns = "skill_runs"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        owner = try container.decodeIfPresent(String.self, forKey: .owner) ?? ""
        repo = try container.decodeIfPresent(String.self, forKey: .repo) ?? ""
        number = try container.decodeIfPresent(Int.self, forKey: .number) ?? 0
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        author = try container.decodeIfPresent(String.self, forKey: .author) ?? ""
        baseRef = try container.decodeIfPresent(String.self, forKey: .baseRef) ?? ""
        headRef = try container.decodeIfPresent(String.self, forKey: .headRef) ?? ""
        baseSHA = try container.decodeIfPresent(String.self, forKey: .baseSHA) ?? ""
        headSHA = try container.decodeIfPresent(String.self, forKey: .headSHA) ?? ""
        mergeBaseSHA = try container.decodeIfPresent(String.self, forKey: .mergeBaseSHA)
        githubState = try container.decodeIfPresent(String.self, forKey: .githubState) ?? ""
        isDraft = try container.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
        status = try container.decodeIfPresent(PRReviewStatus.self, forKey: .status) ?? .unknown
        error = try container.decodeIfPresent(String.self, forKey: .error)
        checkoutPath = try container.decodeIfPresent(String.self, forKey: .checkoutPath)
        workspaceID = try container.decodeIfPresent(String.self, forKey: .workspaceID)
        tabID = try container.decodeIfPresent(String.self, forKey: .tabID)
        workspaceError = try container.decodeIfPresent(String.self, forKey: .workspaceError)
        additions = try container.decodeIfPresent(Int.self, forKey: .additions) ?? 0
        deletions = try container.decodeIfPresent(Int.self, forKey: .deletions) ?? 0
        changedFiles = try container.decodeIfPresent(Int.self, forKey: .changedFiles) ?? 0
        rankingState = try container.decodeIfPresent(PRReviewRankingState.self, forKey: .rankingState) ?? .unknown
        rankingError = try container.decodeIfPresent(String.self, forKey: .rankingError)
        archivedAt = try container.decodeIfPresent(String.self, forKey: .archivedAt)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        preparedAt = try container.decodeIfPresent(String.self, forKey: .preparedAt)
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        runningRuns = try container.decodeIfPresent(Int.self, forKey: .runningRuns) ?? 0
        documentCount = try container.decodeIfPresent(Int.self, forKey: .documentCount) ?? 0
        body = try container.decodeIfPresent(String.self, forKey: .body)
        viewerReview = try container.decodeIfPresent(DashboardReviewState.self, forKey: .viewerReview)
        skillRuns = try container.decodeIfPresent([DashboardSkillRun].self, forKey: .skillRuns)
    }
}

struct PRReviewFile: Codable, Equatable, Identifiable, Sendable {
    var path: String
    var oldPath: String
    var status: String
    var additions: Int
    var deletions: Int
    var impact: PRReviewImpact?
    var impactReason: String?
    var guidedOrder: Int?
    var guidedReason: String?
    var viewed: Bool
    var viewedAt: String?
    var viewedSource: String?

    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case path
        case oldPath = "old_path"
        case status
        case additions
        case deletions
        case impact
        case impactReason = "impact_reason"
        case guidedOrder = "guided_order"
        case guidedReason = "guided_reason"
        case viewed
        case viewedAt = "viewed_at"
        case viewedSource = "viewed_source"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        oldPath = try container.decodeIfPresent(String.self, forKey: .oldPath) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        additions = try container.decodeIfPresent(Int.self, forKey: .additions) ?? 0
        deletions = try container.decodeIfPresent(Int.self, forKey: .deletions) ?? 0
        impact = try container.decodeIfPresent(PRReviewImpact.self, forKey: .impact)
        impactReason = try container.decodeIfPresent(String.self, forKey: .impactReason)
        guidedOrder = try container.decodeIfPresent(Int.self, forKey: .guidedOrder)
        guidedReason = try container.decodeIfPresent(String.self, forKey: .guidedReason)
        viewed = try container.decodeIfPresent(Bool.self, forKey: .viewed) ?? false
        viewedAt = try container.decodeIfPresent(String.self, forKey: .viewedAt)
        viewedSource = try container.decodeIfPresent(String.self, forKey: .viewedSource)
    }
}

struct PRReviewSkill: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var kind: PRReviewSkillKind
    var runner: String
    var promptTemplate: String
    var commandTemplate: String
    var outputs: [String]
    var description: String
    var builtin: Bool
    var enabled: Bool

    init(
        id: String,
        title: String,
        kind: PRReviewSkillKind,
        runner: String,
        promptTemplate: String,
        commandTemplate: String,
        outputs: [String],
        description: String,
        builtin: Bool,
        enabled: Bool
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.runner = runner
        self.promptTemplate = promptTemplate
        self.commandTemplate = commandTemplate
        self.outputs = outputs
        self.description = description
        self.builtin = builtin
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case kind
        case runner
        case promptTemplate = "prompt_template"
        case commandTemplate = "command_template"
        case outputs
        case description
        case builtin
        case enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        kind = try container.decodeIfPresent(PRReviewSkillKind.self, forKey: .kind) ?? .unknown
        runner = try container.decodeIfPresent(String.self, forKey: .runner) ?? ""
        promptTemplate = try container.decodeIfPresent(String.self, forKey: .promptTemplate) ?? ""
        commandTemplate = try container.decodeIfPresent(String.self, forKey: .commandTemplate) ?? ""
        outputs = try container.decodeIfPresent([String].self, forKey: .outputs) ?? []
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        builtin = try container.decodeIfPresent(Bool.self, forKey: .builtin) ?? false
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

struct PRReviewSkillMark: Codable, Equatable, Sendable {
    var state: String
    var actor: String?
    var note: String?
    var markedAt: String?

    enum CodingKeys: String, CodingKey {
        case state
        case actor
        case note
        case markedAt = "marked_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? ""
        actor = try container.decodeIfPresent(String.self, forKey: .actor)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        markedAt = try container.decodeIfPresent(String.self, forKey: .markedAt)
    }
}

struct PRReviewSkillState: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var kind: PRReviewSkillKind
    var runner: String
    var promptTemplate: String
    var commandTemplate: String
    var outputs: [String]
    var description: String
    var builtin: Bool
    var enabled: Bool
    var state: String
    var mark: PRReviewSkillMark?
    var runCount: Int
    var lastRunAt: String?
    var running: Bool

    init(
        id: String,
        title: String,
        kind: PRReviewSkillKind,
        runner: String,
        promptTemplate: String,
        commandTemplate: String,
        outputs: [String],
        description: String,
        builtin: Bool,
        enabled: Bool,
        state: String,
        mark: PRReviewSkillMark?,
        runCount: Int,
        lastRunAt: String?,
        running: Bool
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.runner = runner
        self.promptTemplate = promptTemplate
        self.commandTemplate = commandTemplate
        self.outputs = outputs
        self.description = description
        self.builtin = builtin
        self.enabled = enabled
        self.state = state
        self.mark = mark
        self.runCount = runCount
        self.lastRunAt = lastRunAt
        self.running = running
    }

    var skill: PRReviewSkill {
        PRReviewSkill(
            id: id,
            title: title,
            kind: kind,
            runner: runner,
            promptTemplate: promptTemplate,
            commandTemplate: commandTemplate,
            outputs: outputs,
            description: description,
            builtin: builtin,
            enabled: enabled
        )
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case kind
        case runner
        case promptTemplate = "prompt_template"
        case commandTemplate = "command_template"
        case outputs
        case description
        case builtin
        case enabled
        case state
        case mark
        case runCount = "run_count"
        case lastRunAt = "last_run_at"
        case running
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        kind = try container.decodeIfPresent(PRReviewSkillKind.self, forKey: .kind) ?? .unknown
        runner = try container.decodeIfPresent(String.self, forKey: .runner) ?? ""
        promptTemplate = try container.decodeIfPresent(String.self, forKey: .promptTemplate) ?? ""
        commandTemplate = try container.decodeIfPresent(String.self, forKey: .commandTemplate) ?? ""
        outputs = try container.decodeIfPresent([String].self, forKey: .outputs) ?? []
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        builtin = try container.decodeIfPresent(Bool.self, forKey: .builtin) ?? false
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? "not_run"
        mark = try container.decodeIfPresent(PRReviewSkillMark.self, forKey: .mark)
        runCount = try container.decodeIfPresent(Int.self, forKey: .runCount) ?? 0
        lastRunAt = try container.decodeIfPresent(String.self, forKey: .lastRunAt)
        running = try container.decodeIfPresent(Bool.self, forKey: .running) ?? false
    }
}

struct PRReviewRun: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var reviewID: String
    var skillID: String
    var skillTitle: String
    var state: PRReviewRunState
    var launch: String?
    var command: String?
    var workspaceID: String?
    var tabID: String?
    var paneID: String?
    var actor: String?
    var note: String?
    var error: String?
    var createdAt: String?
    var startedAt: String?
    var finishedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case reviewID = "review_id"
        case skillID = "skill_id"
        case skillTitle = "skill_title"
        case state
        case launch
        case command
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case paneID = "pane_id"
        case actor
        case note
        case error
        case createdAt = "created_at"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }
}

struct PRReviewDocument: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var reviewID: String
    var runID: String?
    var kind: PRReviewDocumentKind
    var title: String
    var mediaType: String
    var filename: String?
    var url: String?
    var byteSize: Int64
    var contentHash: String?
    var origin: String
    var originPath: String?
    var createdAt: String?
    var downloadable: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case reviewID = "review_id"
        case runID = "run_id"
        case kind
        case title
        case mediaType = "media_type"
        case filename
        case url
        case byteSize = "byte_size"
        case contentHash = "content_hash"
        case origin
        case originPath = "origin_path"
        case createdAt = "created_at"
        case downloadable
    }
}

struct PRReviewEvent: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var sequence: Int
    var reviewID: String
    var type: String
    var summary: String
    var payload: [String: PiJSONValue]
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case sequence
        case reviewID = "review_id"
        case type
        case summary
        case payload
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        sequence = try container.decodeIfPresent(Int.self, forKey: .sequence) ?? 0
        reviewID = try container.decodeIfPresent(String.self, forKey: .reviewID) ?? ""
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        payload = (try? container.decode([String: PiJSONValue].self, forKey: .payload)) ?? [:]
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }
}

struct PRReviewSnapshot: Codable, Equatable, Sendable {
    var ok: Bool
    var review: PRReviewSummary
    var files: [PRReviewFile]
    var skills: [PRReviewSkillState]
    var runs: [PRReviewRun]
    var documents: [PRReviewDocument]
    var events: [PRReviewEvent]

    enum CodingKeys: String, CodingKey {
        case ok
        case review
        case files
        case skills
        case runs
        case documents
        case events
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? true
        review = try container.decode(PRReviewSummary.self, forKey: .review)
        files = try container.decodeIfPresent([PRReviewFile].self, forKey: .files) ?? []
        skills = try container.decodeIfPresent([PRReviewSkillState].self, forKey: .skills) ?? []
        runs = try container.decodeIfPresent([PRReviewRun].self, forKey: .runs) ?? []
        documents = try container.decodeIfPresent([PRReviewDocument].self, forKey: .documents) ?? []
        events = try container.decodeIfPresent([PRReviewEvent].self, forKey: .events) ?? []
    }
}

struct PRReviewListResponse: Codable, Sendable {
    var ok: Bool
    var reviews: [PRReviewSummary]

    enum CodingKeys: String, CodingKey {
        case ok
        case reviews
    }
}

struct PRReviewCapabilities: Codable, Equatable, Sendable {
    var ok: Bool
    var capabilities: [String]
    var available: Bool
    var reason: String?
    var skills: [PRReviewSkill]
    var ghAvailable: Bool?
    var runner: String?
    var runnerAvailable: Bool?
    var piAvailable: Bool?
    var workspaceLabel: String?
    var autoRank: Bool?
    var syncViewedToGitHub: Bool?

    var supportsV1: Bool {
        capabilities.contains("pr-review-v1")
    }

    enum CodingKeys: String, CodingKey {
        case ok
        case capabilities
        case available
        case reason
        case skills
        case ghAvailable = "gh_available"
        case runner
        case runnerAvailable = "runner_available"
        case piAvailable = "pi_available"
        case workspaceLabel = "workspace_label"
        case autoRank = "auto_rank"
        case syncViewedToGitHub = "sync_viewed_to_github"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? true
        capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        available = try container.decodeIfPresent(Bool.self, forKey: .available) ?? false
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        skills = try container.decodeIfPresent([PRReviewSkill].self, forKey: .skills) ?? []
        ghAvailable = try container.decodeIfPresent(Bool.self, forKey: .ghAvailable)
        runner = try container.decodeIfPresent(String.self, forKey: .runner)
        runnerAvailable = try container.decodeIfPresent(Bool.self, forKey: .runnerAvailable)
        piAvailable = try container.decodeIfPresent(Bool.self, forKey: .piAvailable)
        workspaceLabel = try container.decodeIfPresent(String.self, forKey: .workspaceLabel)
        autoRank = try container.decodeIfPresent(Bool.self, forKey: .autoRank)
        syncViewedToGitHub = try container.decodeIfPresent(Bool.self, forKey: .syncViewedToGitHub)
    }
}

struct PRReviewDiff: Codable, Equatable, Sendable {
    var ok: Bool
    var reviewID: String
    var baseSHA: String
    var headSHA: String
    var truncated: Bool
    var files: [PRReviewDiffFile]

    enum CodingKeys: String, CodingKey {
        case ok
        case reviewID = "review_id"
        case baseSHA = "base_sha"
        case headSHA = "head_sha"
        case truncated
        case files
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? true
        reviewID = try container.decodeIfPresent(String.self, forKey: .reviewID) ?? ""
        baseSHA = try container.decodeIfPresent(String.self, forKey: .baseSHA) ?? ""
        headSHA = try container.decodeIfPresent(String.self, forKey: .headSHA) ?? ""
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        files = try container.decodeIfPresent([PRReviewDiffFile].self, forKey: .files) ?? []
    }
}

struct PRReviewDiffFile: Codable, Equatable, Sendable {
    var path: String
    var oldPath: String?
    var status: String
    var additions: Int
    var deletions: Int
    var binary: Bool
    var truncated: Bool
    var hunks: [PRReviewDiffHunk]

    enum CodingKeys: String, CodingKey {
        case path
        case oldPath = "old_path"
        case status
        case additions
        case deletions
        case binary
        case truncated
        case hunks
    }
}

struct PRReviewDiffHunk: Codable, Equatable, Sendable {
    var oldStart: Int
    var oldLines: Int
    var newStart: Int
    var newLines: Int
    var header: String
    var lines: [PRReviewDiffLine]

    enum CodingKeys: String, CodingKey {
        case oldStart = "old_start"
        case oldLines = "old_lines"
        case newStart = "new_start"
        case newLines = "new_lines"
        case header
        case lines
    }
}

struct PRReviewDiffLine: Codable, Equatable, Sendable {
    var kind: String
    var oldNumber: Int?
    var newNumber: Int?
    var text: String

    enum CodingKeys: String, CodingKey {
        case kind
        case oldNumber = "old_number"
        case newNumber = "new_number"
        case text
    }
}

struct PRReviewFileText: Codable, Equatable, Sendable {
    var ok: Bool
    var path: String
    var side: PRReviewSide
    var startLine: Int
    var endLine: Int
    var totalLines: Int
    var text: String

    enum CodingKeys: String, CodingKey {
        case ok
        case path
        case side
        case startLine = "start_line"
        case endLine = "end_line"
        case totalLines = "total_lines"
        case text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? true
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        side = try container.decodeIfPresent(PRReviewSide.self, forKey: .side) ?? .after
        startLine = try container.decodeIfPresent(Int.self, forKey: .startLine) ?? 0
        endLine = try container.decodeIfPresent(Int.self, forKey: .endLine) ?? 0
        totalLines = try container.decodeIfPresent(Int.self, forKey: .totalLines) ?? 0
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
    }
}

struct PRReviewFindings: Codable, Equatable, Sendable {
    var ok: Bool
    var path: String
    var text: String
    var documentIDs: [String]

    enum CodingKeys: String, CodingKey {
        case ok
        case path
        case text
        case documentIDs = "document_ids"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? true
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        documentIDs = try container.decodeIfPresent([String].self, forKey: .documentIDs) ?? []
    }
}
