import Foundation

struct PRReviewHTMLDocument: Equatable {
    let fileURL: URL
    let readAccessURL: URL

    init(cachedFileURL: URL) {
        fileURL = cachedFileURL.standardizedFileURL
        readAccessURL = fileURL.deletingLastPathComponent().standardizedFileURL
    }

    func allows(_ url: URL) -> Bool {
        if url.absoluteString == "about:blank" { return true }
        guard url.isFileURL else { return false }
        let root = readAccessURL.path.hasSuffix("/") ? readAccessURL.path : readAccessURL.path + "/"
        return url.standardizedFileURL.path.hasPrefix(root)
    }

    static func linkedDocumentID(_ url: URL) -> String? {
        let prefix = "herdr-pr-review-document:"
        let value = url.absoluteString
        guard value.hasPrefix(prefix) else { return nil }
        let id = String(value.dropFirst(prefix.count))
        guard id.hasPrefix("prdoc_"), id.count <= 100,
              id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-" )).contains($0) })
        else { return nil }
        return id
    }
}
