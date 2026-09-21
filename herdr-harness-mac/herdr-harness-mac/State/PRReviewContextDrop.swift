import AppKit
import UniformTypeIdentifiers

@MainActor
extension PRReviewStore {
    @discardableResult
    func acceptContextDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        let linkProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }
        guard !fileProviders.isEmpty || !linkProviders.isEmpty else { return false }

        Task {
            var files: [URL] = []
            for provider in fileProviders {
                do {
                    let data = try await Self.droppedData(provider, type: UTType.fileURL.identifier)
                    if let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
                        files.append(url)
                    }
                } catch {
                    reportImportError("Couldn't read the dropped file: \(error.localizedDescription)")
                }
            }
            importContextItems(urls: files)

            for provider in linkProviders where !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                do {
                    let data = try await Self.droppedData(provider, type: UTType.url.identifier)
                    if let url = URL(dataRepresentation: data, relativeTo: nil) {
                        await addLink(url: url.absoluteString, title: "")
                    }
                } catch {
                    reportImportError("Couldn't read the dropped link: \(error.localizedDescription)")
                }
            }
        }
        return true
    }

    @discardableResult
    func acceptContextPasteboardDrop(_ pasteboard: NSPasteboard) -> Bool {
        guard PRReviewContextDropPolicy.accepts(pasteboardTypes: pasteboard.types ?? []) else { return false }

        if let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
            as? [NSFilePromiseReceiver], !receivers.isEmpty {
            acceptContextPromisedFiles(receivers)
            return true
        }

        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: false]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            let files = urls.filter(\.isFileURL)
            let links = urls.filter { !$0.isFileURL }
            importContextItems(urls: files)
            Task {
                for link in links {
                    await addLink(url: link.absoluteString, title: "")
                }
            }
            return !files.isEmpty || !links.isEmpty
        }
        return false
    }

    func importContextItems(urls: [URL]) {
        let candidates = contextImportableURLs(from: urls)
        guard !candidates.isEmpty else { return }
        Task { await uploadDocuments(urls: candidates) }
    }

    /// Folder expansion stays local so we can reject unsafe or oversized files
    /// before any upload begins and give one clear recovery path to the user.
    func contextImportableURLs(from urls: [URL]) -> [URL] {
        var result: [URL] = []
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]

        func appendIfAllowed(_ url: URL) {
            guard result.count < 50 else { return }
            do {
                let values = try url.resourceValues(forKeys: keys)
                guard values.isRegularFile == true else { return }
                guard PRReviewContextDocumentTypes.allowedExtensions.contains(url.pathExtension.lowercased()) else {
                    reportImportError("\(url.lastPathComponent) is not a supported review document.")
                    return
                }
                if Int64(values.fileSize ?? 0) > AttachmentPolicy.maximumFileBytes {
                    reportImportError("\(url.lastPathComponent) is larger than 20 MB; add it as a link instead.")
                    return
                }
                result.append(url)
            } catch {
                reportImportError("Couldn't read \(url.lastPathComponent).")
            }
        }

        for url in urls where result.count < 50 {
            do {
                let values = try url.resourceValues(forKeys: keys)
                if values.isDirectory == true {
                    guard let enumerator = FileManager.default.enumerator(
                        at: url,
                        includingPropertiesForKeys: Array(keys),
                        options: [.skipsHiddenFiles, .skipsPackageDescendants]
                    ) else { continue }
                    for case let child as URL in enumerator where result.count < 50 {
                        appendIfAllowed(child)
                    }
                } else {
                    appendIfAllowed(url)
                }
            } catch {
                reportImportError("Couldn't read \(url.lastPathComponent).")
            }
        }
        return result
    }

    func reportImportError(_ message: String) {
        contextImportError = message
    }

    private func acceptContextPromisedFiles(_ receivers: [NSFilePromiseReceiver]) {
        let directory = HerdrAttachmentDropPolicy.promiseDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for receiver in receivers.prefix(50) {
            receiver.receivePromisedFiles(atDestination: directory, options: [:], operationQueue: .main) {
                [weak self] url, error in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let error {
                        self.reportImportError("Couldn't read the dropped file: \(error.localizedDescription)")
                        return
                    }
                    self.importContextItems(urls: [url])
                }
            }
        }
    }

    private static func droppedData(_ provider: NSItemProvider, type: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
    }
}
