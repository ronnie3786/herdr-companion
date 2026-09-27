import Foundation

/// A skim of one long reply (companion capability `first-mate-skim-v1`): a
/// short, casual rewrite whose linked phrases open the exact original text.
/// The companion sends ids, offsets, and the normalized document only. Every
/// excerpt is sliced from the reply text the client already has, so nothing a
/// model wrote is ever shown as the original. See docs/first-mate/skim.md.
struct FirstMateSkim: Codable, Equatable, Sendable {
    enum Status: String, Codable, Equatable, Sendable {
        case pending, ready, failed, rejected, unknown

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: value) ?? .unknown
        }
    }

    var status: Status
    var format: String?
    var promptVersion: String?
    var segmenterVersion: Int?
    var skimVersion: Int?
    var document: SkimDocument?
    var segments: [SkimSegment]?
    var replySHA256: String?

    enum CodingKeys: String, CodingKey {
        case status, format, document, segments
        case promptVersion = "prompt_version", segmenterVersion = "segmenter_version"
        case skimVersion = "skim_version", replySHA256 = "reply_sha256"
    }

    init(status: Status, format: String? = "breath_tight", promptVersion: String? = "skim-v2",
         segmenterVersion: Int? = 1, skimVersion: Int? = 1, document: SkimDocument? = nil,
         segments: [SkimSegment]? = nil, replySHA256: String? = nil) {
        self.status = status
        self.format = format
        self.promptVersion = promptVersion
        self.segmenterVersion = segmenterVersion
        self.skimVersion = skimVersion
        self.document = document
        self.segments = segments
        self.replySHA256 = replySHA256
    }

    /// A malformed document or segment table makes the skim unusable, never
    /// the message: readers fall back to the full reply.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = (try? c.decode(Status.self, forKey: .status)) ?? .unknown
        format = try? c.decodeIfPresent(String.self, forKey: .format)
        promptVersion = try? c.decodeIfPresent(String.self, forKey: .promptVersion)
        segmenterVersion = try? c.decodeIfPresent(Int.self, forKey: .segmenterVersion)
        skimVersion = try? c.decodeIfPresent(Int.self, forKey: .skimVersion)
        document = try? c.decodeIfPresent(SkimDocument.self, forKey: .document)
        segments = try? c.decodeIfPresent([SkimSegment].self, forKey: .segments)
        replySHA256 = try? c.decodeIfPresent(String.self, forKey: .replySHA256)
    }
}

/// The normalized skim document (Skim v1, SPEC section 4.1).
struct SkimDocument: Codable, Equatable, Sendable {
    var version: Int
    var format: String
    var status: String
    var statusLabel: String
    var headline: [SkimToken]
    var blocks: [SkimBlock]
    var drawers: [SkimDrawer]
    var rest: SkimRest
    var anchors: [SkimAnchor]
    var stats: SkimStats?

    init(version: Int = 1, format: String = "breath_tight", status: String = "answer", statusLabel: String = "Answer",
         headline: [SkimToken] = [], blocks: [SkimBlock], drawers: [SkimDrawer] = [], rest: SkimRest = .init(refs: []),
         anchors: [SkimAnchor], stats: SkimStats? = nil) {
        self.version = version
        self.format = format
        self.status = status
        self.statusLabel = statusLabel
        self.headline = headline
        self.blocks = blocks
        self.drawers = drawers
        self.rest = rest
        self.anchors = anchors
        self.stats = stats
    }

    enum CodingKeys: String, CodingKey {
        case version, format, status, statusLabel, headline, blocks, drawers, rest, anchors, stats
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        format = try c.decode(String.self, forKey: .format)
        status = try c.decode(String.self, forKey: .status)
        statusLabel = try c.decode(String.self, forKey: .statusLabel)
        headline = try c.decodeIfPresent([SkimToken].self, forKey: .headline) ?? []
        blocks = try c.decode([SkimBlock].self, forKey: .blocks)
        drawers = try c.decodeIfPresent([SkimDrawer].self, forKey: .drawers) ?? []
        rest = try c.decodeIfPresent(SkimRest.self, forKey: .rest) ?? SkimRest(refs: [])
        anchors = try c.decode([SkimAnchor].self, forKey: .anchors)
        stats = try? c.decodeIfPresent(SkimStats.self, forKey: .stats)
    }
}

/// Generated text is plain text: words, inline code, and anchors that point
/// at segment ids. Styling belongs to the client.
enum SkimToken: Codable, Equatable, Sendable {
    case text(String)
    case code(String)
    case anchor(id: String, label: [SkimToken], refs: [String])

    private enum CodingKeys: String, CodingKey { case t, v, id, label, refs }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .t) {
        case "text": self = .text(try c.decode(String.self, forKey: .v))
        case "code": self = .code(try c.decode(String.self, forKey: .v))
        case "anchor":
            self = .anchor(id: try c.decode(String.self, forKey: .id),
                           label: try c.decode([SkimToken].self, forKey: .label),
                           refs: try c.decode([String].self, forKey: .refs))
        default:
            throw DecodingError.dataCorruptedError(forKey: .t, in: c, debugDescription: "Unknown skim token")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try c.encode("text", forKey: .t)
            try c.encode(value, forKey: .v)
        case .code(let value):
            try c.encode("code", forKey: .t)
            try c.encode(value, forKey: .v)
        case .anchor(let id, let label, let refs):
            try c.encode("anchor", forKey: .t)
            try c.encode(id, forKey: .id)
            try c.encode(label, forKey: .label)
            try c.encode(refs, forKey: .refs)
        }
    }

    /// The reader-facing text: anchors read as their label.
    var plainText: String {
        switch self {
        case .text(let value), .code(let value): value
        case .anchor(_, let label, _): label.map(\.plainText).joined()
        }
    }
}

/// `say`, `ask`, `heads_up`, `what`, `why`, `next`, and `reply` carry one line
/// of tokens; `list` carries items.
enum SkimBlock: Codable, Equatable, Sendable {
    case line(kind: String, tokens: [SkimToken])
    case list(items: [[SkimToken]])

    private enum CodingKeys: String, CodingKey { case kind, tokens, items }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        if kind == "list" {
            self = .list(items: try c.decode([[SkimToken]].self, forKey: .items))
        } else {
            self = .line(kind: kind, tokens: try c.decode([SkimToken].self, forKey: .tokens))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .line(let kind, let tokens):
            try c.encode(kind, forKey: .kind)
            try c.encode(tokens, forKey: .tokens)
        case .list(let items):
            try c.encode("list", forKey: .kind)
            try c.encode(items, forKey: .items)
        }
    }

    var kind: String {
        switch self {
        case .line(let kind, _): kind
        case .list: "list"
        }
    }
}

struct SkimAnchor: Codable, Equatable, Sendable {
    var id: String
    var label: String
    var refs: [String]
    /// `code`, `table`, or `text`: what the phrase opens.
    var kind: String
}

struct SkimDrawer: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var kind: String
    var peek: String
    var refs: [String]
}

struct SkimRest: Codable, Equatable, Sendable {
    var refs: [String]
}

struct SkimStats: Codable, Equatable, Sendable {
    var sourceWords: Int
    var skimWords: Int
}

/// One addressable block of the canonical reply. Offsets are UTF-16 code units
/// into the reply with line endings canonicalized to LF.
struct SkimSegment: Codable, Equatable, Sendable {
    var id: String
    var n: Int
    var kind: String
    var startLine: Int
    var endLine: Int
    var start: Int
    var end: Int
    var words: Int?
    var section: String?
    var lang: String?
    var codeLines: Int?
    var rows: Int?
    var ordered: Bool?
    var level: Int?
    var pseudo: Bool?
}
