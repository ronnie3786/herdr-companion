import Foundation

struct PRReviewGuideScope: Codable, Equatable, Sendable {
    var machineID: String
    var reviewID: String
    var baseSHA: String
    var headSHA: String
    var comparison: GitComparison? = nil
    var comparisonSelection: GitComparisonSelection? = nil
}

struct PRReviewGuideSource: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var documentID: String
    var title: String
    var reviewer: String?
    var excerpt: String
    var freshness: String
    var provenance: String?
    var headSHA: String?
    var runID: String?
    var disposition: String?
    var url: String?
    enum CodingKeys: String, CodingKey {
        case id, title, reviewer, excerpt, freshness, provenance, disposition, url
        case documentID = "document_id", headSHA = "head_sha", runID = "run_id"
    }
    var attribution: String { reviewer?.isEmpty == false ? reviewer! : title }
}

struct PRReviewGuideSegment: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var path: String?
    var side: PRReviewSide?
    var startLine: Int?
    var endLine: Int?
    var spokenText: String
    var drawings: [PRReviewGuideDrawing]
    var sourceRefs: [String]
    enum CodingKeys: String, CodingKey {
        case id, path, side, drawings
        case startLine = "start_line", endLine = "end_line", spokenText = "spoken_text", sourceRefs = "source_refs"
    }
    var target: PRReviewGuideTarget? {
        guard let path, let startLine, let endLine, startLine > 0, endLine >= startLine else { return nil }
        return .init(path: path, side: side ?? .after, startLine: startLine, endLine: endLine)
    }
}

struct PRReviewGuideChapter: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var objective: String
    var displayText: String
    var spokenText: String
    var segments: [PRReviewGuideSegment]
    var suggestedQuestions: [String]
    enum CodingKeys: String, CodingKey {
        case id, title, objective, segments
        case displayText = "display_text", spokenText = "spoken_text", suggestedQuestions = "suggested_questions"
    }
}

struct PRReviewGuideCoverage: Codable, Equatable, Sendable { var limitations: [String] }

struct PRReviewGuideAssessment: Codable, Equatable, Sendable {
    var sourceID: String
    var status: String
    var explanation: String
    var headSHA: String
    enum CodingKeys: String, CodingKey {
        case status, explanation
        case sourceID = "source_id", headSHA = "head_sha"
    }
}

struct PRReviewGuide: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var state: String
    var reviewID: String
    var baseSHA: String
    var headSHA: String
    var contextSnapshotID: String?
    var chapters: [PRReviewGuideChapter]?
    var sources: [PRReviewGuideSource]?
    var coverage: PRReviewGuideCoverage?
    var error: String?
    var assessments: [PRReviewGuideAssessment]? = nil
    var warnings: [String]? = nil
    var comparison: GitComparison? = nil
    enum CodingKeys: String, CodingKey {
        case id, state, chapters, sources, coverage, error, assessments, warnings, comparison
        case reviewID = "review_id", baseSHA = "base_sha", headSHA = "head_sha", contextSnapshotID = "context_snapshot_id"
    }
}

struct PRReviewGuideResponse: Decodable, Sendable { var guide: PRReviewGuide }

struct PRReviewGuideRequest: Encodable, Sendable {
    struct ViewerState: Encodable, Sendable {
        struct VisibleLines: Encodable, Sendable {
            var path: String
            var side: String
            var startLine: Int
            var endLine: Int
            enum CodingKeys: String, CodingKey {
                case path, side
                case startLine = "start_line", endLine = "end_line"
            }
        }
        var path: String?
        var visibleLines: VisibleLines?
        var diffStyle: String
        var overflow: String
        enum CodingKeys: String, CodingKey {
            case path, overflow
            case visibleLines = "visible_lines", diffStyle = "diff_style"
        }
    }
    struct Selection: Encodable, Sendable {
        struct Span: Encodable, Sendable { var side: String; var startLine: Int; var endLine: Int }
        var text: String
        var spans: [Span]
    }
    var requestID: String
    var baseSHA: String
    var headSHA: String
    var kind: String
    var question: String?
    var path: String?
    var chapterID: String?
    var continueFromGuideID: String?
    var selection: Selection?
    var comparison: GitComparisonSelection? = nil
    var viewerState: ViewerState? = nil
    enum CodingKeys: String, CodingKey {
        case kind, question, path, selection, comparison
        case viewerState = "viewer_state"
        case requestID = "request_id", baseSHA = "base_sha", headSHA = "head_sha"
        case chapterID = "chapter_id", continueFromGuideID = "continue_from_guide_id"
    }
}

protocol PRReviewGuideClient: Sendable {
    func startPRReviewGuide(reviewID: String, request: PRReviewGuideRequest) async throws -> PRReviewGuide
    func fetchPRReviewGuide(reviewID: String, guideID: String) async throws -> PRReviewGuide
    func prReviewNarrationCapabilities() async throws -> PRReviewNarrationCapabilities
    func captionedPRReviewSpeech(text: String, voice: String, drawings: [PRReviewGuideDrawing]) async throws -> PRReviewNarrationManifest
    func transcribeVoice(fileURL: URL) async throws -> VoiceTranscriptionResponse
}

struct PRReviewGuideTranscript: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var question: String
    var answer: PRReviewGuide
}
