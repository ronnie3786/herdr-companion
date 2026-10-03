import CryptoKit
import Foundation

/// The identity of a skill package's files, computed exactly as the companion's
/// `content_hash` does, so an import can tell whether this Mac's copy matches.
enum AgentRoleSkillContentHash {
    struct File: Sendable {
        let path: String
        let executable: Bool
        let data: Data
    }

    /// SHA-256 over each file, in code-point order of its path: the UTF-8 of
    /// `json.dumps([path, executable, len(data)])`, then the file's bytes.
    static func hash(_ files: [File]) -> String {
        var digest = SHA256()
        let ordered = files.sorted {
            $0.path.unicodeScalars.lexicographicallyPrecedes($1.path.unicodeScalars) { $0.value < $1.value }
        }
        for file in ordered {
            digest.update(data: Data("[\(jsonString(file.path)), \(file.executable), \(file.data.count)]".utf8))
            digest.update(data: file.data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Nil when a file's content isn't valid base64.
    static func hash(_ bundle: AgentRoleSkillBundle) -> String? {
        var files: [File] = []
        for file in bundle.files {
            guard let data = Data(base64Encoded: file.content) else { return nil }
            files.append(File(path: file.path, executable: file.executable, data: data))
        }
        return hash(files)
    }

    /// A JSON string as Python's `json.dumps` writes it with `ensure_ascii=True`.
    static func jsonString(_ text: String) -> String {
        var json = "\""
        for unit in text.utf16 {
            switch unit {
            case 0x22: json += "\\\""
            case 0x5C: json += "\\\\"
            case 0x0A: json += "\\n"
            case 0x0D: json += "\\r"
            case 0x09: json += "\\t"
            case 0x08: json += "\\b"
            case 0x0C: json += "\\f"
            case 0x20...0x7E: json.unicodeScalars.append(Unicode.Scalar(UInt8(unit)))
            default: json += String(format: "\\u%04x", unit)
            }
        }
        return json + "\""
    }
}
