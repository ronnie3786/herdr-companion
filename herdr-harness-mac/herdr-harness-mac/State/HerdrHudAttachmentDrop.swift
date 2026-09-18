import AppKit
import UniformTypeIdentifiers

extension HerdrHudSession {
    /// Finder files and image data from browsers or screenshot tools share
    /// the same validated, durable attachment import path.
    func acceptAttachmentDrop(_ providers: [NSItemProvider]) -> Bool {
        let supported = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }
        guard !supported.isEmpty else { return false }
        Task {
            for provider in supported.prefix(Self.maxAttachments) {
                do {
                    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                        let data = try await Self.droppedData(provider, type: UTType.fileURL.identifier)
                        guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else {
                            reportAttachmentError("Drop a local file or image into the HUD.")
                            continue
                        }
                        addAttachments([url])
                    } else if let type = provider.registeredTypeIdentifiers.first(where: {
                        UTType($0)?.conforms(to: .image) == true
                    }) {
                        let data = try await Self.droppedData(provider, type: type)
                        guard !data.isEmpty, Int64(data.count) <= AttachmentPolicy.maximumFileBytes else {
                            reportAttachmentError("Images must be between 1 byte and 20 MB.")
                            continue
                        }
                        let ext = UTType(type)?.preferredFilenameExtension ?? "png"
                        let url = FileManager.default.temporaryDirectory
                            .appendingPathComponent("Dropped image \(UUID().uuidString).\(ext)")
                        try data.write(to: url, options: .atomic)
                        defer { try? FileManager.default.removeItem(at: url) }
                        addAttachments([url])
                    }
                } catch {
                    reportAttachmentError("Couldn't attach the dropped item: \(error.localizedDescription)")
                }
            }
        }
        return true
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

    /// AppKit drop path, used by the HUD's drop target.
    ///
    /// A drag out of the system screenshot preview is a file promise, so it is
    /// resolved through `NSFilePromiseReceiver` before the fallbacks; a file
    /// already on disk keeps its existing real-file path, and raw image data is
    /// written to a staging file first.
    @discardableResult
    func acceptPasteboardDrop(_ pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        guard HerdrAttachmentDropPolicy.accepts(pasteboardTypes: types) else { return false }

        if let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
            as? [NSFilePromiseReceiver], !receivers.isEmpty {
            acceptPromisedFiles(receivers)
            return true
        }

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            addAttachments(urls)
            return true
        }

        if let imageURL = Self.stagedImageFile(from: pasteboard) {
            addAttachments([imageURL])
            try? FileManager.default.removeItem(at: imageURL)
            return true
        }
        return false
    }

    /// Materializes promised files. The promise is fulfilled into a staging
    /// directory owned by this app; `addAttachments` then copies the file into
    /// the durable attachment store, so the staging copy is removed here.
    func acceptPromisedFiles(_ receivers: [NSFilePromiseReceiver]) {
        let directory = HerdrAttachmentDropPolicy.promiseDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for receiver in receivers.prefix(Self.maxAttachments) {
            receiver.receivePromisedFiles(
                atDestination: directory,
                options: [:],
                operationQueue: .main
            ) { [weak self] url, error in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let error {
                        self.reportAttachmentError(
                            "Couldn’t attach the dropped item: \(error.localizedDescription)"
                        )
                        return
                    }
                    self.addAttachments([url])
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    private static func stagedImageFile(from pasteboard: NSPasteboard) -> URL? {
        let pngData = pasteboard.data(forType: .png)
        let data = pngData ?? pasteboard.data(forType: .tiff)
        guard let data, !data.isEmpty, Int64(data.count) <= AttachmentPolicy.maximumFileBytes else { return nil }
        let ext = pngData == nil ? "tiff" : "png"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Dropped image \(UUID().uuidString).\(ext)")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        return url
    }
}
