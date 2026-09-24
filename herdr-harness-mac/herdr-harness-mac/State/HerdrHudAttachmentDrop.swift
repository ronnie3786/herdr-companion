import AppKit
import UniformTypeIdentifiers

/// The narrow promise-fulfillment seam used by the HUD. `NSFilePromiseReceiver`
/// cannot be constructed outside a live drag, so tests drive this protocol with
/// a synthetic receiver and the production adapter forwards to AppKit.
@MainActor
protocol HerdrPromisedFileReceiver {
    /// Materializes this receiver's promised files into `directory`. The
    /// completion is called once per promised file on `operationQueue`; the
    /// delivered URL is only guaranteed to exist until the completion returns.
    func loadPromisedFiles(
        atDestination directory: URL,
        operationQueue: OperationQueue,
        completion: @escaping (URL?, (any Error)?) -> Void
    )
}

extension NSFilePromiseReceiver: HerdrPromisedFileReceiver {
    func loadPromisedFiles(
        atDestination directory: URL,
        operationQueue: OperationQueue,
        completion: @escaping (URL?, (any Error)?) -> Void
    ) {
        // Arm the promise while the dragging pasteboard is still valid; AppKit
        // then writes every promised file into `directory`.
        receivePromisedFiles(
            atDestination: directory,
            options: [:],
            operationQueue: operationQueue
        ) { url, error in
            completion(url, error)
        }
    }
}

enum HerdrAttachmentDropError: LocalizedError {
    case imageSize
    case unreadableDroppedItem

    var errorDescription: String? {
        switch self {
        case .imageSize:
            "Images must be between 1 byte and 20 MB."
        case .unreadableDroppedItem:
            "Drop a local file or image into the HUD."
        }
    }
}

/// Writes a drop payload into its own staging directory, so two drops can never
/// collide over a filename and cleanup is a single directory removal. Every
/// import copies the staged file into `HerdrHudSession`'s durable attachment
/// store before the staging directory is dropped.
enum HerdrAttachmentStaging {
    static func directory(inside root: URL? = nil) throws -> URL {
        let root = root ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrDropStaging", isDirectory: true)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func write(_ data: Data, filename: String) throws -> URL {
        let directory = try directory()
        let url = directory.appendingPathComponent(sanitizedFilename(filename))
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Copies a file-backed provider or promise representation while it is
    /// still guaranteed to exist.
    static func copy(_ source: URL, filename: String) throws -> URL {
        let directory = try directory()
        let url = directory.appendingPathComponent(sanitizedFilename(filename))
        try FileManager.default.copyItem(at: source, to: url)
        return url
    }

    /// Removes the staging directory after the durable copy exists.
    static func remove(_ staged: URL) {
        try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
    }

    private static func sanitizedFilename(_ filename: String) -> String {
        let name = (filename.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).lastPathComponent
        return name.isEmpty ? "Dropped item" : name
    }
}

extension HerdrHudSession {
    // MARK: - SwiftUI provider route

    /// Finder files and image data from browsers or screenshot tools share the
    /// same validated, durable attachment import path.
    ///
    /// The HUD's live drop destination is the AppKit `HerdrHudDropTarget`,
    /// because only AppKit can materialize file promises; this provider entry
    /// point stays for callers that already hold `NSItemProvider`s and is
    /// exercised as the conformance-safe path.
    @discardableResult
    func acceptAttachmentDrop(_ providers: [NSItemProvider]) -> Bool {
        let supported = providers.filter(HerdrAttachmentDropPolicy.providerCarriesAttachment)
        guard !supported.isEmpty else { return false }
        Task { @MainActor in
            for provider in supported.prefix(Self.maxAttachments) {
                await self.importDroppedProvider(provider)
            }
        }
        return true
    }

    /// Resolves one provider to a durable attachment. Every registered image
    /// representation is tried in order, and a file-backed representation is
    /// the fallback when the data loader is missing.
    func importDroppedProvider(_ provider: NSItemProvider) async {
        var lastError: (any Error)?

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            do {
                if let url = try await Self.droppedFileURL(provider) {
                    addAttachments([url])
                    return
                }
                lastError = HerdrAttachmentDropError.unreadableDroppedItem
            } catch {
                lastError = error
            }
        }

        var sawImageCandidate = false
        for type in HerdrAttachmentDropPolicy.imageTypeCandidates(for: provider) {
            sawImageCandidate = true
            do {
                let staged = try await Self.stagedImageRepresentation(provider, type: type)
                addAttachments([staged])
                HerdrAttachmentStaging.remove(staged)
                return
            } catch {
                lastError = error
            }
        }

        if !sawImageCandidate, lastError == nil {
            lastError = HerdrAttachmentDropError.unreadableDroppedItem
        }
        let message = lastError ?? HerdrAttachmentDropError.unreadableDroppedItem
        reportAttachmentError("Couldn't attach the dropped item: \(message.localizedDescription)")
    }

    private static func droppedFileURL(_ provider: NSItemProvider) async throws -> URL? {
        let data = try await droppedData(provider, type: UTType.fileURL.identifier)
        guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else { return nil }
        return url
    }

    /// Stages one image representation. Data is preferred; a provider that only
    /// exposes a file-backed representation is copied out of AppKit's temporary
    /// file before that file is deleted.
    private static func stagedImageRepresentation(_ provider: NSItemProvider, type: String) async throws -> URL {
        let extensionName = UTType(type)?.preferredFilenameExtension ?? "png"
        do {
            let data = try await droppedData(provider, type: type)
            guard !data.isEmpty, Int64(data.count) <= AttachmentPolicy.maximumFileBytes else {
                throw HerdrAttachmentDropError.imageSize
            }
            return try HerdrAttachmentStaging.write(
                data,
                filename: "Dropped image \(UUID().uuidString).\(extensionName)"
            )
        } catch let dataError {
            if let staged = try? await droppedFileRepresentation(provider, type: type, extensionName: extensionName) {
                return staged
            }
            throw dataError
        }
    }

    /// Copies a file-backed provider representation while AppKit's temporary
    /// file still exists: the header promises it is deleted when the completion
    /// handler returns, so the copy must happen inside the handler.
    private static func droppedFileRepresentation(
        _ provider: NSItemProvider,
        type: String,
        extensionName: String
    ) async throws -> URL {
        let gate = HerdrSingleResumeGate()
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                guard gate.claim() else { return }
                guard let url else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    return
                }
                do {
                    let name = url.pathExtension.isEmpty
                        ? "Dropped image.\(extensionName)"
                        : url.lastPathComponent
                    continuation.resume(returning: try HerdrAttachmentStaging.copy(url, filename: name))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func droppedData(_ provider: NSItemProvider, type: String) async throws -> Data {
        let gate = HerdrSingleResumeGate()
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                // Some providers call their completion more than once; resuming
                // a checked continuation twice traps, so the first result wins.
                guard gate.claim() else { return }
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
    }

    // MARK: - AppKit pasteboard route

    /// AppKit drop path, used by the HUD's drop target. The dragging pasteboard
    /// must be read synchronously, while the drag is still live; every mutation
    /// of observable session state then happens on a later main-actor turn, so
    /// an AppKit drag callback never overlaps a SwiftUI update.
    ///
    /// A drag out of the system screenshot preview is a file promise, so it is
    /// resolved through `NSFilePromiseReceiver` before the fallbacks; a file
    /// already on disk keeps its real path, and raw image data is staged first.
    @discardableResult
    func acceptPasteboardDrop(_ pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        guard HerdrAttachmentDropPolicy.accepts(pasteboardTypes: types) else { return false }

        let receivers = HerdrAttachmentDropPolicy.filePromiseReceivers(in: pasteboard)
        if !receivers.isEmpty {
            acceptPromisedFiles(receivers.map { $0 as any HerdrPromisedFileReceiver })
            return true
        }

        // A browser image drag carries a web URL beside the pixels; only real
        // files may take the file branch, otherwise the URL would shadow the
        // image data and the drop would fail as an unreadable file.
        let fileURLs = HerdrAttachmentDropPolicy.localFileURLs(in: pasteboard)
        let imagePayload = HerdrAttachmentDropPolicy.imagePayload(in: pasteboard)
        guard !fileURLs.isEmpty || imagePayload != nil else { return false }

        Task { @MainActor in
            if !fileURLs.isEmpty {
                self.addAttachments(fileURLs)
                return
            }
            guard let imagePayload else { return }
            guard !imagePayload.data.isEmpty,
                  Int64(imagePayload.data.count) <= AttachmentPolicy.maximumFileBytes
            else {
                self.reportAttachmentError(HerdrAttachmentDropError.imageSize.localizedDescription)
                return
            }
            do {
                let extensionName = imagePayload.type.preferredFilenameExtension ?? "png"
                let staged = try HerdrAttachmentStaging.write(
                    imagePayload.data,
                    filename: "Dropped image \(UUID().uuidString).\(extensionName)"
                )
                defer { HerdrAttachmentStaging.remove(staged) }
                self.addAttachments([staged])
            } catch {
                self.reportAttachmentError("Couldn't attach the dropped image: \(error.localizedDescription)")
            }
        }
        return true
    }

    /// Arms every promised file while the drag is live. Each delivered file is
    /// imported on the main actor and its staging copy is removed only after
    /// `addAttachments` made the durable copy.
    func acceptPromisedFiles(_ receivers: [any HerdrPromisedFileReceiver]) {
        let root = HerdrAttachmentDropPolicy.promiseDirectory()
        guard let directory = try? HerdrAttachmentStaging.directory(inside: root) else {
            reportAttachmentError(HerdrAttachmentDropError.unreadableDroppedItem.localizedDescription)
            return
        }
        for receiver in receivers.prefix(Self.maxAttachments) {
            receiver.loadPromisedFiles(atDestination: directory, operationQueue: .main) { [weak self] url, error in
                // The promise reader can arrive on AppKit's queue; hop to the
                // main actor instead of assuming the executor.
                let message = error?.localizedDescription
                Task { @MainActor in
                    guard let self else { return }
                    self.finishPromisedFile(url: url, errorMessage: message, stagingDirectory: directory)
                }
            }
        }
    }

    private func finishPromisedFile(url: URL?, errorMessage: String?, stagingDirectory: URL) {
        if let errorMessage {
            reportAttachmentError("Couldn't attach the dropped item: \(errorMessage)")
            // A cancelled or failed promise can leave a partial file behind.
            try? FileManager.default.removeItem(at: stagingDirectory)
            return
        }
        if let url {
            addAttachments([url])
            // The durable copy exists now (or validation already reported why
            // it does not); remove this file, and the per-drop directory once
            // the last promised file of a multi-file promise has arrived.
            try? FileManager.default.removeItem(at: url)
        } else {
            reportAttachmentError("Couldn't attach the dropped item.")
        }
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: stagingDirectory.path)) ?? []
        if remaining.isEmpty {
            try? FileManager.default.removeItem(at: stagingDirectory)
        }
    }
}

/// Several AppKit loaders are documented to be able to call their completion
/// more than once. Resuming a checked continuation twice traps, so the first
/// result wins.
private final class HerdrSingleResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !hasResumed else { return false }
        hasResumed = true
        return true
    }
}
