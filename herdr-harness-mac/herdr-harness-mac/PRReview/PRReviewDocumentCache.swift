import Foundation

/// Cache paths are derived exclusively from server-issued identifiers. This
/// keeps authenticated document downloads out of WebKit and other viewers.
struct PRReviewDocumentCache: Sendable {
    struct RetentionPolicy: Sendable, Equatable {
        static let standard = RetentionPolicy(
            maximumFileCount: 512,
            maximumByteCount: 8 * 1_024 * 1_024 * 1_024,
            maximumAge: 60 * 24 * 60 * 60
        )

        let maximumFileCount: Int
        let maximumByteCount: Int64
        let maximumAge: TimeInterval
    }

    struct CleanupReport: Sendable, Equatable {
        let removedPaths: [String]
        let remainingFileCount: Int
        let remainingByteCount: Int64
    }

    enum CacheError: LocalizedError, Sendable {
        case unsafeDestination

        var errorDescription: String? {
            "Herdr could not create a safe local path for this PR review document."
        }
    }

    private struct CacheFile {
        let url: URL
        let modifiedAt: Date
        let byteCount: Int64
    }

    let rootURL: URL
    let retentionPolicy: RetentionPolicy

    init(
        rootURL: URL = Self.defaultRootURL(),
        retentionPolicy: RetentionPolicy = .standard
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.retentionPolicy = retentionPolicy
    }

    func destinationURL(
        machineID: String,
        reviewID: String,
        document: PRReviewDocument
    ) throws -> URL {
        let directory = rootURL
            .appending(path: token(machineID), directoryHint: .isDirectory)
            .appending(path: token(reviewID), directoryHint: .isDirectory)
            .appending(path: "\(token(document.id))-\(token(document.contentHash))", directoryHint: .isDirectory)
        let destination = directory
            .appending(path: safeFilename(document.filename.isEmpty ? document.title : document.filename))
            .standardizedFileURL
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard destination.path.hasPrefix(rootPath) else { throw CacheError.unsafeDestination }
        return destination
    }

    /// Prepares only app-owned directories. A staging `.partial` file is
    /// installed atomically by `HerdrAPIClient` after it validates the stream.
    func prepareDestinationURL(
        machineID: String,
        reviewID: String,
        document: PRReviewDocument,
        fileManager: FileManager = .default
    ) throws -> URL {
        let destination = try destinationURL(machineID: machineID, reviewID: reviewID, document: document)
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CacheError.unsafeDestination
        }
        return destination
    }

    @discardableResult
    func cleanup(
        fileManager: FileManager = .default,
        now: Date = .now,
        protecting protectedURLs: Set<URL> = []
    ) throws -> CleanupReport {
        guard fileManager.fileExists(atPath: rootURL.path) else {
            return CleanupReport(removedPaths: [], remainingFileCount: 0, remainingByteCount: 0)
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(at: rootURL, includingPropertiesForKeys: Array(keys)) else {
            return CleanupReport(removedPaths: [], remainingFileCount: 0, remainingByteCount: 0)
        }
        var files: [CacheFile] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            files.append(CacheFile(
                url: url.standardizedFileURL,
                modifiedAt: values.contentModificationDate ?? .distantPast,
                byteCount: Int64(max(0, values.fileSize ?? 0))
            ))
        }

        let protectedPaths = Set(protectedURLs.map { $0.standardizedFileURL.path })
        let cutoff = now.addingTimeInterval(-retentionPolicy.maximumAge)
        var remove = Set(files.filter { $0.modifiedAt < cutoff && !protectedPaths.contains($0.url.path) }.map(\.url.path))
        var remaining = files.filter { !remove.contains($0.url.path) }
        var bytes = remaining.reduce(Int64(0)) { $0 + $1.byteCount }
        for file in remaining.filter({ !protectedPaths.contains($0.url.path) }).sorted(by: { $0.modifiedAt < $1.modifiedAt }) {
            guard remaining.count > retentionPolicy.maximumFileCount || bytes > retentionPolicy.maximumByteCount else { break }
            guard remove.insert(file.url.path).inserted else { continue }
            bytes -= file.byteCount
            remaining.removeAll { $0.url == file.url }
        }
        let removed = files.filter { remove.contains($0.url.path) }.map(\.url)
        for url in removed { try fileManager.removeItem(at: url) }
        return CleanupReport(removedPaths: removed.map(\.path), remainingFileCount: remaining.count, remainingByteCount: max(0, bytes))
    }

    func markAccessed(_ url: URL, at date: Date = .now, fileManager: FileManager = .default) throws {
        let path = url.standardizedFileURL.path
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard path.hasPrefix(rootPath) else { throw CacheError.unsafeDestination }
        try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    private static func defaultRootURL() -> URL {
        let caches = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return caches.appending(path: HerdrAppIdentity.bundleIdentifier, directoryHint: .isDirectory)
            .appending(path: "PRReviewDocuments", directoryHint: .isDirectory)
    }

    private func token(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    private func safeFilename(_ supplied: String) -> String {
        let leaf = (supplied as NSString).lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_ ()[]"))
        let result = String(leaf.unicodeScalars.prefix(120).map { allowed.contains($0) ? Character(String($0)) : "-" })
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return result.isEmpty || result == "." || result == ".." ? "document" : result
    }
}
