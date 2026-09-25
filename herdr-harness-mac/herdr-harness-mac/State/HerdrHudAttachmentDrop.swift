import AppKit
import UniformTypeIdentifiers

/// The narrow promise-fulfillment seam used by the HUD. `NSFilePromiseReceiver`
/// cannot be constructed outside a live drag, so tests drive this protocol with
/// a synthetic receiver and the production adapter forwards to AppKit.
@MainActor
protocol HerdrPromisedFileReceiver: AnyObject {
    /// The number of files this receiver will deliver. `NSFilePromiseReceiver`
    /// fills `fileNames` in once the promise is armed and reports one promised
    /// file per pasteboard item for an ordinary drag; a legacy item can deliver
    /// several files through one receiver. A receiver that cannot say keeps the
    /// single-completion default.
    var promisedFileCount: Int { get }

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
    var promisedFileCount: Int { fileNames.count }

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
        // image data and the drop would fail as an unreadable file. Resolve
        // one representation per pasteboard item so two image items import two
        // attachments and a file item never hides an inline image item.
        let payloads = HerdrAttachmentDropPolicy.itemPayloads(in: pasteboard)
        guard !payloads.isEmpty else { return false }

        Task { @MainActor in
            self.importPasteboardPayloads(payloads)
        }
        return true
    }

    /// Imports every resolved pasteboard item on a later main-actor turn. Image
    /// data is staged per item first and all URLs then take the same validated
    /// `addAttachments` import path, so item order is preserved, the 4-file,
    /// 20 MB, and 21 MB limits still apply, and an item that fails leaves the
    /// rest of the drop and the draft intact.
    private func importPasteboardPayloads(_ payloads: [HerdrAttachmentDropPolicy.ItemPayload]) {
        var urls: [URL] = []
        var staged: [URL] = []
        var firstImageError: String?
        for payload in payloads {
            switch payload {
            case let .file(url):
                urls.append(url)
            case let .image(data, type):
                guard !data.isEmpty,
                      Int64(data.count) <= AttachmentPolicy.maximumFileBytes
                else {
                    firstImageError = firstImageError ?? HerdrAttachmentDropError.imageSize.localizedDescription
                    continue
                }
                do {
                    let extensionName = type.preferredFilenameExtension ?? "png"
                    let file = try HerdrAttachmentStaging.write(
                        data,
                        filename: "Dropped image \(UUID().uuidString).\(extensionName)"
                    )
                    staged.append(file)
                    urls.append(file)
                } catch {
                    firstImageError = firstImageError
                        ?? "Couldn't attach the dropped image: \(error.localizedDescription)"
                }
            }
        }
        let hadImport = !urls.isEmpty
        if hadImport {
            addAttachments(urls)
        }
        for file in staged {
            HerdrAttachmentStaging.remove(file)
        }
        // `addAttachments` clears any earlier error while validating the batch,
        // so an item that failed before the import reports itself unless the
        // import path had its own, more relevant error to show.
        if let firstImageError, !hadImport || validationError == nil {
            reportAttachmentError(firstImageError)
        }
    }

    /// Arms every promised file while the drag is live. All receivers of one
    /// drop share a staging directory, which AppKit requires, and the directory
    /// is removed only after the whole batch has reported each promised file.
    /// A receiver that finishes first therefore cannot delete files a sibling
    /// still has to write, and an individual failure reports a recoverable
    /// error while the same receiver's remaining promised files still arrive.
    func acceptPromisedFiles(_ receivers: [any HerdrPromisedFileReceiver]) {
        let batch = Array(receivers.prefix(Self.maxAttachments))
        let root = HerdrAttachmentDropPolicy.promiseDirectory()
        guard !batch.isEmpty,
              let directory = try? HerdrAttachmentStaging.directory(inside: root)
        else {
            reportAttachmentError(HerdrAttachmentDropError.unreadableDroppedItem.localizedDescription)
            return
        }
        let tracker = HerdrPromiseBatch(directory: directory, session: self)
        activePromiseBatches.append(tracker)
        for receiver in batch {
            let receiverID = tracker.register(receiver)
            receiver.loadPromisedFiles(atDestination: directory, operationQueue: .main) { [weak tracker] url, error in
                // The promise reader can arrive on AppKit's queue; hop to the
                // main actor instead of assuming the executor.
                let message = error?.localizedDescription
                Task { @MainActor in
                    tracker?.finish(receiverID: receiverID, url: url, errorMessage: message)
                }
            }
        }
    }

    /// Releases a settled promise batch. Called on the main actor from
    /// `HerdrPromiseBatch` once the shared staging directory is removed.
    func endPromiseBatch(_ batch: HerdrPromiseBatch) {
        activePromiseBatches.removeAll { $0 === batch }
    }
}

/// One drop's promised-file batch. The shared destination must outlive every
/// sibling receiver: a receiver only settles once it has reported its promised
/// files, and the directory is removed when the whole batch has settled. A
/// failure counts as one of that receiver's promised files and never touches
/// files another receiver wrote or that the same receiver still owes.
@MainActor
final class HerdrPromiseBatch {
    private struct ReceiverSlot {
        var delivered = 0
        var settled = false
    }

    private let directory: URL
    private weak var session: HerdrHudSession?
    private var receivers: [ObjectIdentifier: any HerdrPromisedFileReceiver] = [:]
    private var slots: [ObjectIdentifier: ReceiverSlot] = [:]
    private var unsettledReceivers = 0

    init(directory: URL, session: HerdrHudSession) {
        self.directory = directory
        self.session = session
    }

    /// Adds a receiver to the batch and returns its identifier. Registration
    /// happens while the drop is still synchronous, before any completion can
    /// run, so every receiver shares the same lifetime.
    func register(_ receiver: any HerdrPromisedFileReceiver) -> ObjectIdentifier {
        let receiverID = ObjectIdentifier(receiver)
        receivers[receiverID] = receiver
        slots[receiverID] = ReceiverSlot()
        unsettledReceivers += 1
        return receiverID
    }

    func finish(receiverID: ObjectIdentifier, url: URL?, errorMessage: String?) {
        guard var slot = slots[receiverID] else { return }
        slot.delivered += 1
        // `fileNames` is the only pre-completion signal for a legacy item that
        // delivers several files through one receiver. Every callback, file or
        // failure, counts as one delivered file: a partial failure must not
        // settle a receiver that still owes the batch promised files, because
        // that would remove the shared directory before a delayed delivery of
        // the same receiver arrives. A receiver whose count is not yet readable
        // keeps the previous one-completion behavior.
        let promisedCount = max(receivers[receiverID]?.promisedFileCount ?? 1, 1)
        if !slot.settled, slot.delivered >= promisedCount {
            slot.settled = true
            unsettledReceivers -= 1
        }
        slots[receiverID] = slot

        if let errorMessage {
            session?.reportAttachmentError("Couldn't attach the dropped item: \(errorMessage)")
        } else if let url {
            session?.addAttachments([url])
            // The durable copy exists now (or validation already reported why
            // it does not); remove only this file, never the whole batch.
            try? FileManager.default.removeItem(at: url)
        } else {
            session?.reportAttachmentError("Couldn't attach the dropped item.")
        }

        if unsettledReceivers <= 0 {
            // Any partial file from a failed promise goes with the directory
            // only after every sibling has been delivered and imported.
            try? FileManager.default.removeItem(at: directory)
            session?.endPromiseBatch(self)
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
