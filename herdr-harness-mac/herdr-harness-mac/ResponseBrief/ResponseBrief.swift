import CoreFoundation
import Foundation

struct ResponseBrief: Codable, Equatable, Identifiable, Sendable {
    struct Point: Codable, Equatable, Identifiable, Sendable {
        let text: String
        let startLine: Int
        let endLine: Int

        var id: String { "\(startLine):\(endLine):\(text)" }
    }

    struct Detail: Codable, Equatable, Identifiable, Sendable {
        enum Kind: String, Codable, Sendable {
            case table
            case code
            case detail
        }

        let label: String
        let kind: Kind
        let startLine: Int
        let endLine: Int

        var id: String { "\(kind.rawValue):\(startLine):\(endLine):\(label)" }
    }

    let version: Int
    let title: String
    let summary: String
    let points: [Point]
    let details: [Detail]

    var id: String { "\(version):\(title):\(summary)" }

    static func decodeValidated(_ data: Data, source: String) throws -> ResponseBrief {
        guard data.count <= ResponseBriefLimits.maximumOutputBytes else {
            throw ResponseBriefValidationError.outputTooLarge
        }
        try validateShape(data)
        let brief: ResponseBrief
        do {
            brief = try JSONDecoder().decode(ResponseBrief.self, from: data)
        } catch {
            throw ResponseBriefValidationError.malformedJSON
        }
        try brief.validate(source: source)
        return brief
    }

    func sourceSlice(startLine: Int, endLine: Int, source: String) -> String? {
        let lines = ResponseBriefSourceLines.split(source)
        guard startLine >= 1, endLine >= startLine, endLine <= lines.count else { return nil }
        return lines[(startLine - 1)...(endLine - 1)].joined(separator: "\n")
    }

    private func validate(source: String) throws {
        guard version == 1 else { throw ResponseBriefValidationError.unsupportedVersion }
        guard !title.isEmpty, title.count <= 100,
              !summary.isEmpty, summary.count <= 800,
              points.count <= 4,
              details.count <= 6
        else { throw ResponseBriefValidationError.invalidBounds }
        guard points.allSatisfy({ !$0.text.isEmpty && $0.text.count <= 400 }),
              details.allSatisfy({ !$0.label.isEmpty && $0.label.count <= 100 })
        else { throw ResponseBriefValidationError.invalidBounds }

        try ResponseBriefConcisionPolicy(source: source).validate(self)

        let lineCount = ResponseBriefSourceLines.split(source).count
        let ranges = points.map { ($0.startLine, $0.endLine) }
            + details.map { ($0.startLine, $0.endLine) }
        guard ranges.allSatisfy({ $0.0 >= 1 && $0.1 >= $0.0 && $0.1 <= lineCount }) else {
            throw ResponseBriefValidationError.invalidLineRange
        }
    }

    private static func validateShape(_ data: Data) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ResponseBriefValidationError.malformedJSON
        }
        guard let root = object as? [String: Any],
              Set(root.keys) == ["version", "title", "summary", "points", "details"],
              root["version"] is NSNumber,
              root["title"] is String,
              root["summary"] is String,
              let points = root["points"] as? [[String: Any]],
              let details = root["details"] as? [[String: Any]]
        else { throw ResponseBriefValidationError.invalidSchema }

        guard points.allSatisfy({ point in
            Set(point.keys) == ["text", "startLine", "endLine"]
                && point["text"] is String
                && Self.isInteger(point["startLine"])
                && Self.isInteger(point["endLine"])
        }), details.allSatisfy({ detail in
            Set(detail.keys) == ["label", "kind", "startLine", "endLine"]
                && detail["label"] is String
                && detail["kind"] is String
                && Self.isInteger(detail["startLine"])
                && Self.isInteger(detail["endLine"])
        }) else { throw ResponseBriefValidationError.invalidSchema }
    }

    private static func isInteger(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) != CFBooleanGetTypeID()
            && number.doubleValue.rounded() == number.doubleValue
    }
}

enum ResponseBriefValidationError: LocalizedError, Equatable {
    case malformedJSON
    case invalidSchema
    case unsupportedVersion
    case invalidBounds
    case notConcise
    case invalidLineRange
    case outputTooLarge

    var errorDescription: String? {
        switch self {
        case .malformedJSON: "The brief service returned malformed JSON."
        case .invalidSchema: "The brief service returned an unexpected format."
        case .unsupportedVersion: "This brief uses an unsupported format version."
        case .invalidBounds: "The brief exceeded its content limits."
        case .notConcise: "The generated brief was not shorter enough to display. Regenerate it for a more concise result."
        case .invalidLineRange: "The brief referred to text outside the original response."
        case .outputTooLarge: "The brief response exceeded 32 KiB."
        }
    }
}

enum ResponseBriefLimits {
    static let maximumOutputBytes = 32 * 1_024
    static let maximumContextItemBytes = 16 * 1_024
    static let maximumEnvelopeBytes = 64 * 1_024
    static let targetChunkBytes = 15_500
    static let templateVersion = 1
}

enum ResponseBriefSourceLines {
    static func split(_ source: String) -> [String] {
        // Foundation separates on the LF code unit even when Swift's grapheme
        // segmentation treats CRLF as one Character. Empty and trailing lines,
        // bare CR bytes, and each line's remaining contents stay unchanged.
        source.components(separatedBy: "\n")
    }
}
