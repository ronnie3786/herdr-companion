import Foundation

/// A package-qualified verification verdict from the companion's durable
/// evidence ledger.
///
/// Clients never recompute suite coverage. They decode the assessment the
/// companion recorded and present exactly the gate set, tested revision, and
/// missing or previously passing suites it names. Unknown future status values
/// are retained verbatim and never treated as verified.
struct FirstMateVerificationStatus: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = (try? container.decode(String.self)) ?? Self.unavailable.rawValue
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static let verified = Self(rawValue: "verified")
    static let partiallyVerified = Self(rawValue: "partially_verified")
    static let failed = Self(rawValue: "failed")
    static let unavailable = Self(rawValue: "unavailable")

    /// A future companion may add statuses this client does not know. They stay
    /// unrecognized so no presentation can silently promote them to verified.
    var isRecognized: Bool {
        self == .verified || self == .partiallyVerified || self == .failed || self == .unavailable
    }

    var isVerified: Bool { self == .verified }

    var title: String {
        switch self {
        case .verified: "Verified"
        case .partiallyVerified: "Partially verified"
        case .failed: "Failed"
        default: "Verification unavailable"
        }
    }

    var tone: FirstMateVerificationTone {
        switch self {
        case .verified: .positive
        case .partiallyVerified: .caution
        case .failed: .negative
        default: .unavailable
        }
    }

    var systemImage: String {
        switch self {
        case .verified: "checkmark.shield.fill"
        case .partiallyVerified: "exclamationmark.shield.fill"
        case .failed: "xmark.shield.fill"
        default: "questionmark.circle"
        }
    }
}

enum FirstMateVerificationTone: Equatable, Sendable {
    case positive
    case caution
    case negative
    case unavailable
}

/// One package-qualified suite reference or result. The same shape covers the
/// selected gate set, missing suites, previously passing omissions, and
/// failures; only the fields the companion reported are populated.
struct FirstMateVerificationSuite: Codable, Equatable, Hashable, Sendable {
    var key: String?
    var label: String?
    var package: String?
    var suite: String?
    var configuration: String?
    var workspace: String?
    var reason: String?
    var outcome: String?
    var testedRevision: String?
    var runID: String?
    var fresh: Bool?
    var passedCount: Int?
    var failedCount: Int?
    var skippedCount: Int?

    enum CodingKeys: String, CodingKey {
        case key, label, package, suite, configuration, workspace, reason, outcome, fresh
        case testedRevision = "tested_revision"
        case runID = "run_id"
        case passedCount = "passed_count"
        case failedCount = "failed_count"
        case skippedCount = "skipped_count"
    }

    init(key: String? = nil, label: String? = nil, package: String? = nil, suite: String? = nil,
         configuration: String? = nil, workspace: String? = nil, reason: String? = nil,
         outcome: String? = nil, testedRevision: String? = nil, runID: String? = nil,
         fresh: Bool? = nil, passedCount: Int? = nil, failedCount: Int? = nil, skippedCount: Int? = nil) {
        self.key = key
        self.label = label
        self.package = package
        self.suite = suite
        self.configuration = configuration
        self.workspace = workspace
        self.reason = reason
        self.outcome = outcome
        self.testedRevision = testedRevision
        self.runID = runID
        self.fresh = fresh
        self.passedCount = passedCount
        self.failedCount = failedCount
        self.skippedCount = skippedCount
    }

    /// Compact projections sometimes carry missing suites as plain labels. They
    /// still decode instead of failing the whole assessment.
    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let text = try? container.decode(String.self) {
            label = text.isEmpty ? nil : text
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decodeIfPresent(String.self, forKey: .key)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        package = try container.decodeIfPresent(String.self, forKey: .package)
        suite = try container.decodeIfPresent(String.self, forKey: .suite)
        configuration = try container.decodeIfPresent(String.self, forKey: .configuration)
        workspace = try container.decodeIfPresent(String.self, forKey: .workspace)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        outcome = try container.decodeIfPresent(String.self, forKey: .outcome)
        testedRevision = try container.decodeIfPresent(String.self, forKey: .testedRevision)
        runID = try container.decodeIfPresent(String.self, forKey: .runID)
        fresh = try container.decodeIfPresent(Bool.self, forKey: .fresh)
        passedCount = try container.decodeIfPresent(Int.self, forKey: .passedCount)
        failedCount = try container.decodeIfPresent(Int.self, forKey: .failedCount)
        skippedCount = try container.decodeIfPresent(Int.self, forKey: .skippedCount)
    }

    /// The package-qualified display label the companion reported. Falls back
    /// to composing the identity so an incomplete payload can never hide a
    /// suite behind a blank row.
    var displayLabel: String {
        if let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return label }
        let name = suite?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let packageName = package?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var composed: String
        if packageName.isEmpty {
            composed = name
        } else if name.isEmpty {
            composed = packageName
        } else {
            composed = "\(packageName)/\(name)"
        }
        if let configuration, !configuration.isEmpty { composed += " (\(configuration))" }
        return composed.isEmpty ? "Unnamed suite" : composed
    }

    var outcomeTitle: String? {
        switch outcome {
        case "passed": "Passed"
        case "failed": "Failed"
        case "error": "Error"
        case "skipped": "Skipped"
        case let value?: value.replacingOccurrences(of: "_", with: " ").capitalized
        case nil: nil
        }
    }

    var isPassing: Bool { outcome == "passed" }
    var isFailing: Bool { outcome == "failed" || outcome == "error" }

    /// A short, deterministic identity used for accessibility and list
    /// reconciliation. Identically named suites in different packages stay
    /// distinct.
    var stableIdentity: String {
        if let key, !key.isEmpty { return key }
        return "\(package ?? "")\u{1F}\(suite ?? displayLabel)\u{1F}\(configuration ?? "")"
    }
}

/// A selected run that no longer matches the current workspace revision, with
/// the companion's reason. Stale evidence is named, never hidden.
struct FirstMateVerificationEvidence: Codable, Equatable, Hashable, Sendable {
    var runID: String?
    var workspace: String?
    var testedRevision: String?
    var reason: String?

    enum CodingKeys: String, CodingKey {
        case workspace, reason
        case runID = "run_id"
        case testedRevision = "tested_revision"
    }

    init(runID: String? = nil, workspace: String? = nil, testedRevision: String? = nil, reason: String? = nil) {
        self.runID = runID
        self.workspace = workspace
        self.testedRevision = testedRevision
        self.reason = reason
    }
}

/// The companion's authoritative coverage assessment. This is decoded, never
/// recomputed: the exact gate set, results, and tested revision travel with
/// every verdict so a green always ships with the list it applies to.
struct FirstMateVerification: Codable, Equatable, Sendable {
    var status: FirstMateVerificationStatus = .unavailable
    var label: String?
    var featureRevision: Int?
    var assessedRevisions: [String: String] = [:]
    var sourceRevisions: [String] = []
    var gateSet: [FirstMateVerificationSuite] = []
    var requiredSuites: [FirstMateVerificationSuite] = []
    var missingSuites: [FirstMateVerificationSuite] = []
    var previouslyGreenMissing: [FirstMateVerificationSuite] = []
    var failingSuites: [FirstMateVerificationSuite] = []
    var staleEvidence: [FirstMateVerificationEvidence] = []
    var coverageReasons: [String] = []
    var evidencePresent = false
    var computedAt: String?

    enum CodingKeys: String, CodingKey {
        case status, label
        case featureRevision = "feature_revision"
        case assessedRevisions = "assessed_revisions"
        case sourceRevisions = "source_revisions"
        case gateSet = "gate_set"
        case requiredSuites = "required_suites"
        case missingSuites = "missing_suites"
        case previouslyGreenMissing = "previously_green_missing"
        case failingSuites = "failing_suites"
        case staleEvidence = "stale_evidence"
        case coverageReasons = "coverage_reasons"
        case evidencePresent = "evidence_present"
        case computedAt = "computed_at"
    }

    init(status: FirstMateVerificationStatus = .unavailable, label: String? = nil,
         featureRevision: Int? = nil, assessedRevisions: [String: String] = [:],
         sourceRevisions: [String] = [], gateSet: [FirstMateVerificationSuite] = [],
         requiredSuites: [FirstMateVerificationSuite] = [],
         missingSuites: [FirstMateVerificationSuite] = [],
         previouslyGreenMissing: [FirstMateVerificationSuite] = [],
         failingSuites: [FirstMateVerificationSuite] = [],
         staleEvidence: [FirstMateVerificationEvidence] = [],
         coverageReasons: [String] = [], evidencePresent: Bool = false, computedAt: String? = nil) {
        self.status = status
        self.label = label
        self.featureRevision = featureRevision
        self.assessedRevisions = assessedRevisions
        self.sourceRevisions = sourceRevisions
        self.gateSet = gateSet
        self.requiredSuites = requiredSuites
        self.missingSuites = missingSuites
        self.previouslyGreenMissing = previouslyGreenMissing
        self.failingSuites = failingSuites
        self.staleEvidence = staleEvidence
        self.coverageReasons = coverageReasons
        self.evidencePresent = evidencePresent
        self.computedAt = computedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(FirstMateVerificationStatus.self, forKey: .status) ?? .unavailable
        label = try container.decodeIfPresent(String.self, forKey: .label)
        featureRevision = try container.decodeIfPresent(Int.self, forKey: .featureRevision)
        assessedRevisions = try container.decodeIfPresent([String: String].self, forKey: .assessedRevisions) ?? [:]
        sourceRevisions = try container.decodeIfPresent([String].self, forKey: .sourceRevisions) ?? []
        gateSet = try container.decodeIfPresent([FirstMateVerificationSuite].self, forKey: .gateSet) ?? []
        requiredSuites = try container.decodeIfPresent([FirstMateVerificationSuite].self, forKey: .requiredSuites) ?? []
        missingSuites = try container.decodeIfPresent([FirstMateVerificationSuite].self, forKey: .missingSuites) ?? []
        previouslyGreenMissing = try container.decodeIfPresent([FirstMateVerificationSuite].self, forKey: .previouslyGreenMissing) ?? []
        failingSuites = try container.decodeIfPresent([FirstMateVerificationSuite].self, forKey: .failingSuites) ?? []
        staleEvidence = try container.decodeIfPresent([FirstMateVerificationEvidence].self, forKey: .staleEvidence) ?? []
        coverageReasons = try container.decodeIfPresent([String].self, forKey: .coverageReasons) ?? []
        evidencePresent = try container.decodeIfPresent(Bool.self, forKey: .evidencePresent) ?? false
        computedAt = try container.decodeIfPresent(String.self, forKey: .computedAt)
    }

    /// True for the additive empty object a legacy companion returns when no
    /// structured evidence exists. The feature decoder keeps that state as
    /// "reported but unavailable" rather than inventing a verdict.
    var isEmpty: Bool {
        !evidencePresent
            && gateSet.isEmpty
            && requiredSuites.isEmpty
            && missingSuites.isEmpty
            && previouslyGreenMissing.isEmpty
            && failingSuites.isEmpty
            && staleEvidence.isEmpty
            && coverageReasons.isEmpty
            && sourceRevisions.isEmpty
            && assessedRevisions.isEmpty
            && computedAt == nil
            && featureRevision == nil
    }

    var computedAtDate: Date? { computedAt.flatMap(HerdrTimestamp.date(from:)) }

    /// Orders assessments so a delayed response can never replace newer
    /// evidence with an older verdict. The feature revision leads; the
    /// computation timestamp breaks ties. Missing ordering evidence is not
    /// treated as newer, so cached state survives an ambiguous payload.
    func isAtLeastAsFresh(as other: FirstMateVerification) -> Bool {
        switch (featureRevision, other.featureRevision) {
        case let (.some(current), .some(cached)):
            if current != cached { return current > cached }
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            break
        }
        if let current = computedAtDate, let cached = other.computedAtDate {
            return current >= cached
        }
        return false
    }

    var testedRevisions: [String] {
        var values: [String] = []
        for revision in sourceRevisions where !revision.isEmpty && !values.contains(revision) {
            values.append(revision)
        }
        if values.isEmpty {
            for entry in gateSet {
                if let revision = entry.testedRevision, !revision.isEmpty, !values.contains(revision) {
                    values.append(revision)
                }
            }
        }
        if values.isEmpty {
            values = assessedRevisions.values.filter { !$0.isEmpty }.sorted()
        }
        return values
    }
}

/// Pure presentation rules for the verification summary. Kept outside the view
/// so both native clients and their tests can assert labels, tones, and the
/// accessible description without rendering.
struct FirstMateVerificationPresentation: Equatable, Sendable {
    let verification: FirstMateVerification?
    let isLastReported: Bool

    init(verification: FirstMateVerification?, isLastReported: Bool = false) {
        self.verification = verification
        self.isLastReported = isLastReported
    }

    var hasEvidence: Bool { verification != nil }
    var status: FirstMateVerificationStatus { verification?.status ?? .unavailable }
    var statusTitle: String { status.title }
    var statusTone: FirstMateVerificationTone { status.tone }
    var statusSymbol: String { status.systemImage }
    var isVerified: Bool { status.isVerified }
    var hasUnrecognizedStatus: Bool { verification != nil && !status.isRecognized }

    var testedRevisions: [String] { verification?.testedRevisions ?? [] }

    var testedRevisionText: String? {
        let revisions = testedRevisions
        guard !revisions.isEmpty else { return nil }
        let shortened = revisions.map(Self.shortRevision)
        return revisions.count == 1
            ? "Tested revision \(shortened[0])"
            : "Tested revisions \(shortened.joined(separator: ", "))"
    }

    var testedRevisionAccessibilityText: String? {
        let revisions = testedRevisions
        guard !revisions.isEmpty else { return nil }
        return revisions.count == 1
            ? "Tested revision \(revisions[0])"
            : "Tested revisions \(revisions.joined(separator: ", "))"
    }

    var gateSet: [FirstMateVerificationSuite] { verification?.gateSet ?? [] }
    var missingSuites: [FirstMateVerificationSuite] { verification?.missingSuites ?? [] }
    var previouslyGreenMissingSuites: [FirstMateVerificationSuite] { verification?.previouslyGreenMissing ?? [] }
    var failingSuites: [FirstMateVerificationSuite] { verification?.failingSuites ?? [] }
    var staleEvidence: [FirstMateVerificationEvidence] { verification?.staleEvidence ?? [] }
    var coverageReasons: [String] { verification?.coverageReasons ?? [] }

    var lastReportedNote: String {
        "Showing the last reported evidence. The companion connection is unavailable, so newer runs may not appear here."
    }

    var unavailableNote: String {
        "No structured suite evidence is reported for this feature. A green workflow status cannot be tied to a gate set until the companion reports one."
    }

    static func shortRevision(_ revision: String) -> String {
        revision.count > 12 ? String(revision.prefix(12)) + "…" : revision
    }

    var accessibilitySummary: String {
        var parts = ["Verification: \(statusTitle)."]
        if isLastReported {
            parts.append("Last reported while the companion connection was unavailable.")
        }
        if hasUnrecognizedStatus {
            parts.append("The companion reported the unrecognized status \(status.rawValue); it is not treated as verified.")
        }
        if let tested = testedRevisionAccessibilityText {
            parts.append(tested + ".")
        } else if isVerified {
            parts.append("No tested revision was reported.")
        }
        if let verification, verification.evidencePresent || !gateSet.isEmpty {
            if gateSet.isEmpty {
                parts.append("No selected gate results.")
            } else {
                let entries = gateSet.map { entry in
                    "\(entry.displayLabel) \(entry.outcomeTitle ?? "result unavailable")"
                }
                parts.append("Gate set of \(gateSet.count): " + entries.joined(separator: "; ") + ".")
            }
        }
        if !missingSuites.isEmpty {
            parts.append("Missing suites: " + missingSuites.map(\.displayLabel).joined(separator: "; ") + ".")
        }
        if !previouslyGreenMissingSuites.isEmpty {
            parts.append("Previously passing suites dropped from the gate set: "
                + previouslyGreenMissingSuites.map(\.displayLabel).joined(separator: "; ") + ".")
        }
        if !failingSuites.isEmpty {
            parts.append("Failing suites: " + failingSuites.map(\.displayLabel).joined(separator: "; ") + ".")
        }
        if !staleEvidence.isEmpty {
            let entries = staleEvidence.map { evidence in
                let revision = evidence.testedRevision.map(Self.shortRevision) ?? "an unknown revision"
                return "\(revision): \(evidence.reason ?? "stale")"
            }
            parts.append("Stale evidence: " + entries.joined(separator: "; ") + ".")
        }
        if !coverageReasons.isEmpty {
            parts.append("Coverage: " + coverageReasons.joined(separator: " ") + ".")
        }
        if !hasEvidence {
            parts.append(unavailableNote)
        }
        return parts.joined(separator: " ")
    }
}
