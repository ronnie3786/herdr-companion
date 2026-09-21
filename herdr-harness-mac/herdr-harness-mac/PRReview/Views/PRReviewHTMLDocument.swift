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
}
