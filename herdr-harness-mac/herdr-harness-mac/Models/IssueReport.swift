import Foundation

/// Whether a report describes something broken or something wanted.
///
/// Raw values are the wire format of `POST /api/v1/issue-reports`.
enum IssueReportKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case bug
    case feature

    var id: String { rawValue }

    /// Label shown by the report sheet's segmented picker.
    var label: String {
        switch self {
        case .bug: "Bug"
        case .feature: "Feature request"
        }
    }

    var systemImage: String {
        switch self {
        case .bug: "ladybug"
        case .feature: "lightbulb"
        }
    }
}

/// One file inlined into a report request.
///
/// The property names are the JSON keys of the companion server contract and
/// must not be renamed or remapped.
struct IssueReportAttachmentBody: Encodable, Equatable, Sendable {
    let filename: String
    let contentType: String
    let dataBase64: String
}

/// Request body of `POST /api/v1/issue-reports`.
struct IssueReportRequest: Encodable, Equatable, Sendable {
    let kind: IssueReportKind
    let title: String
    /// The user's description, sent exactly as written.
    let body: String
    let autofix: Bool
    let environment: [String: String]
    let attachments: [IssueReportAttachmentBody]
    /// Idempotency key chosen by the client for one draft (8–64 letters,
    /// digits, `-` or `_`). A retry that repeats an id the server already
    /// filed gets the stored result back instead of a second GitHub issue.
    let clientReportId: String
}

/// An attachment after the server uploaded it to the repository.
struct IssueReportUploadedAttachment: Decodable, Equatable, Sendable {
    let filename: String
    let url: String
    let contentType: String
    let size: Int
}

/// The filed report as returned by the companion server.
///
/// `id`, `issueNumber` and `issueUrl` are required; every other field falls
/// back to an empty value so a successfully filed issue is never reported as a
/// failure because a newer server added or dropped a descriptive field.
struct IssueReportRecord: Decodable, Equatable, Sendable {
    let id: String
    let kind: IssueReportKind
    let title: String
    let autofix: Bool
    let issueNumber: Int
    let issueUrl: String
    let repository: String
    let attachments: [IssueReportUploadedAttachment]
    let createdAt: String

    init(
        id: String,
        kind: IssueReportKind,
        title: String,
        autofix: Bool,
        issueNumber: Int,
        issueUrl: String,
        repository: String,
        attachments: [IssueReportUploadedAttachment],
        createdAt: String
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.autofix = autofix
        self.issueNumber = issueNumber
        self.issueUrl = issueUrl
        self.repository = repository
        self.attachments = attachments
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, autofix, issueNumber, issueUrl, repository, attachments, createdAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        issueNumber = try container.decode(Int.self, forKey: .issueNumber)
        issueUrl = try container.decode(String.self, forKey: .issueUrl)
        let rawKind = try container.decodeIfPresent(String.self, forKey: .kind) ?? ""
        kind = IssueReportKind(rawValue: rawKind) ?? .bug
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        autofix = try container.decodeIfPresent(Bool.self, forKey: .autofix) ?? false
        repository = try container.decodeIfPresent(String.self, forKey: .repository) ?? ""
        attachments = try container.decodeIfPresent([IssueReportUploadedAttachment].self, forKey: .attachments) ?? []
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }
}

/// Envelope of `POST /api/v1/issue-reports`.
struct IssueReportResponse: Decodable, Sendable {
    let ok: Bool
    let report: IssueReportRecord
}

/// `GET /api/v1/issue-reports/capabilities`.
///
/// Decoding is tolerant: a missing limit falls back to the client's own
/// defaults, and a missing `available` is treated as unavailable.
struct IssueReportCapabilities: Decodable, Equatable, Sendable {
    static let defaultMaxAttachments = 6
    static let defaultMaxAttachmentBytes: Int64 = 20 * 1024 * 1024
    static let defaultMaxTotalAttachmentBytes: Int64 = 40 * 1024 * 1024

    let ok: Bool
    let available: Bool
    let repository: String?
    let reason: String?
    let maxAttachments: Int
    let maxAttachmentBytes: Int64
    let maxTotalAttachmentBytes: Int64
    let publicRepository: Bool

    init(
        ok: Bool = true,
        available: Bool,
        repository: String? = nil,
        reason: String? = nil,
        maxAttachments: Int = IssueReportCapabilities.defaultMaxAttachments,
        maxAttachmentBytes: Int64 = IssueReportCapabilities.defaultMaxAttachmentBytes,
        maxTotalAttachmentBytes: Int64 = IssueReportCapabilities.defaultMaxTotalAttachmentBytes,
        publicRepository: Bool = true
    ) {
        self.ok = ok
        self.available = available
        self.repository = repository
        self.reason = reason
        self.maxAttachments = maxAttachments
        self.maxAttachmentBytes = maxAttachmentBytes
        self.maxTotalAttachmentBytes = maxTotalAttachmentBytes
        self.publicRepository = publicRepository
    }

    private enum CodingKeys: String, CodingKey {
        case ok, available, repository, reason
        case maxAttachments, maxAttachmentBytes, maxTotalAttachmentBytes, publicRepository
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? true
        available = try container.decodeIfPresent(Bool.self, forKey: .available) ?? false
        repository = try container.decodeIfPresent(String.self, forKey: .repository)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        maxAttachments = try container.decodeIfPresent(Int.self, forKey: .maxAttachments)
            ?? Self.defaultMaxAttachments
        maxAttachmentBytes = try container.decodeIfPresent(Int64.self, forKey: .maxAttachmentBytes)
            ?? Self.defaultMaxAttachmentBytes
        maxTotalAttachmentBytes = try container.decodeIfPresent(Int64.self, forKey: .maxTotalAttachmentBytes)
            ?? Self.defaultMaxTotalAttachmentBytes
        publicRepository = try container.decodeIfPresent(Bool.self, forKey: .publicRepository) ?? true
    }
}
