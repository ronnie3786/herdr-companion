import Foundation
import Observation
import UniformTypeIdentifiers

/// Material outlives its view, but never its exact companion/store lifecycle.
@MainActor @Observable
final class FirstMateMobileComposerDrafts {
    @ObservationIgnored private var values: [FirstMateFeatureTarget: FirstMateMobileComposerDraft] = [:]

    func draft(for target: FirstMateFeatureTarget, store: FirstMateStore) -> FirstMateMobileComposerDraft {
        if let value = values[target], value.lifecycle == store.lifecycle { return value }
        values[target]?.discard()
        let value = FirstMateMobileComposerDraft(target: target, lifecycle: store.lifecycle)
        values[target] = value
        return value
    }

    func retain(machines: Set<String>) {
        for key in Array(values.keys) where !machines.contains(key.machineID) {
            values.removeValue(forKey: key)?.discard()
        }
    }

    func discardAll() { retain(machines: []) }
}

@MainActor @Observable
final class FirstMateMobileComposerDraft {
    let target: FirstMateFeatureTarget
    let lifecycle: FirstMateStore.LifecycleIdentity
    private(set) var attachments: [TerminalAttachment] = []
    private(set) var picks: [FirstMateMentionCandidate] = []
    private(set) var containsDictation = false
    private(set) var revision = 0
    private(set) var generation = UUID()
    var error: String?
    var recoveredVoice: String?
    @ObservationIgnored private var uploads: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var frozen: [String: Frozen] = [:]
    private struct Frozen {
        let handle: FirstMateOutgoingMessage.Handle
        let text: String
        let attachments: [TerminalAttachment]
        let picks: [FirstMateMentionCandidate]
        let dictation: Bool
        var detachedRevision: Int
        var restoredRevision: Int?
    }

    init(target: FirstMateFeatureTarget, lifecycle: FirstMateStore.LifecycleIdentity) {
        self.target = target; self.lifecycle = lifecycle
    }

    var blocksSending: Bool { attachments.contains { $0.status != .uploaded || $0.uploadedPath == nil } }
    var hasAttachments: Bool { !attachments.isEmpty }

    func isAlive(store: FirstMateStore, context: FirstMateStore.OperationContext) -> Bool {
        lifecycle == store.lifecycle && lifecycle == context.lifecycleIdentity
            && context.matchesFeature(target.featureID) && store.isDestinationAlive(context)
    }

    func edit(_ text: String, store: FirstMateStore, context: FirstMateStore.OperationContext) {
        guard isAlive(store: store, context: context) else { return }
        revision &+= 1
        store.setComposerDraft(text, for: context)
        if text.isEmpty { containsDictation = false; picks = [] }
    }

    func choose(_ pick: FirstMateMentionCandidate, store: FirstMateStore, context: FirstMateStore.OperationContext) {
        guard isAlive(store: store, context: context) else { return }
        let text = FirstMateMentionTrigger.insert(pick.name, into: store.composerDraft(for: context))
        edit(text, store: store, context: context)
        picks.removeAll { $0.name == pick.name }
        picks.append(pick)
    }

    /// Called synchronously after reservation, before any completion Task.
    func detach(_ handle: FirstMateOutgoingMessage.Handle, text: String) {
        let record = Frozen(handle: handle, text: text, attachments: attachments, picks: picks,
                            dictation: containsDictation, detachedRevision: revision + 1)
        attachments = []; picks = []; containsDictation = false
        revision &+= 1; generation = UUID(); frozen[handle.outgoingID] = record
    }

    func settle(_ handle: FirstMateOutgoingMessage.Handle, state: FirstMateOutgoingMessage.State?, store: FirstMateStore) {
        guard var record = frozen[handle.outgoingID], record.handle == handle,
              isAlive(store: store, context: handle.context) else { return }
        if state?.isFailure != true {
            record.attachments.forEach { $0.removeSourceFileIfOwned() }
            frozen[handle.outgoingID] = nil
            return
        }
        guard revision == record.detachedRevision, store.composerDraft(for: handle.context).isEmpty,
              attachments.isEmpty else { return }
        store.setComposerDraft(record.text, for: handle.context)
        attachments = record.attachments; picks = record.picks; containsDictation = record.dictation
        revision &+= 1; record.restoredRevision = revision
        frozen[handle.outgoingID] = record
    }

    func prepareRetry(_ handle: FirstMateOutgoingMessage.Handle, store: FirstMateStore) {
        guard var record = frozen[handle.outgoingID], record.handle == handle,
              record.restoredRevision == revision, isAlive(store: store, context: handle.context) else { return }
        store.setComposerDraft("", for: handle.context)
        attachments = []; picks = []; containsDictation = false; revision &+= 1; generation = UUID()
        record.detachedRevision = revision; record.restoredRevision = nil
        frozen[handle.outgoingID] = record
    }

    func receiveVoice(_ text: String, initialRevision: Int, initialText: String,
                      store: FirstMateStore, context: FirstMateStore.OperationContext) -> Bool {
        guard isAlive(store: store, context: context) else { return false }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { error = "Nothing heard."; return false }
        guard revision == initialRevision, store.composerDraft(for: context) == initialText else {
            recoveredVoice = text
            error = "Your draft changed. The voice transcript is saved below."
            return false
        }
        edit(initialText + (initialText.isEmpty ? "" : "\n") + text, store: store, context: context)
        containsDictation = true
        return true
    }

    /// Imports must pass their original generation and owner guard after loading.
    func enqueue(_ candidates: [AttachmentCandidate], store: FirstMateStore,
                 context: FirstMateStore.OperationContext, generation expectedGeneration: UUID,
                 canUpload: @escaping @MainActor () -> Bool) {
        guard expectedGeneration == generation, isAlive(store: store, context: context),
              store.operationContext == context, canUpload(), store.attachmentsSupported else {
            cleanup(candidates); return
        }
        do {
            try AttachmentPolicy.validate(existingAttachments: attachments, incomingCandidates: candidates)
            let items = candidates.map {
                TerminalAttachment(id: UUID(), filename: $0.filename, sourceURL: $0.sourceURL,
                    byteCount: $0.byteCount, sourceOwnership: $0.ownership, status: .uploading, uploaded: nil, error: nil)
            }
            attachments += items; revision &+= 1; error = nil
            for item in items { upload(item, store: store, context: context, canUpload: canUpload) }
        } catch { cleanup(candidates); self.error = error.localizedDescription }
    }

    func retry(_ item: TerminalAttachment, store: FirstMateStore, context: FirstMateStore.OperationContext,
               canUpload: @escaping @MainActor () -> Bool) {
        guard isAlive(store: store, context: context), store.operationContext == context,
              canUpload(), store.attachmentsSupported, attachments.contains(where: { $0.id == item.id }),
              uploads[item.id] == nil else { return }
        upload(item, store: store, context: context, canUpload: canUpload)
    }

    func remove(_ item: TerminalAttachment) {
        uploads.removeValue(forKey: item.id)?.cancel()
        attachments.removeAll { $0.id == item.id }; revision &+= 1
        item.removeSourceFileIfOwned()
    }

    private func upload(_ item: TerminalAttachment, store: FirstMateStore, context: FirstMateStore.OperationContext,
                        canUpload: @escaping @MainActor () -> Bool) {
        update(item.id) { $0.status = .uploading; $0.error = nil }
        let originalGeneration = generation
        uploads[item.id] = Task { [weak self] in
            guard let self else { return }
            defer { self.uploads[item.id] = nil }
            let scoped = item.sourceURL.startAccessingSecurityScopedResource()
            defer { if scoped { item.sourceURL.stopAccessingSecurityScopedResource() } }
            do {
                try Task.checkCancellation()
                guard canUpload(), self.generation == originalGeneration,
                      self.isAlive(store: store, context: context), store.operationContext == context,
                      self.attachments.contains(where: { $0.id == item.id }) else { throw CancellationError() }
                let thumbnail = await Task.detached(priority: .utility) {
                    ComposerAttachmentThumbnail.encodedData(at: item.sourceURL)
                }.value
                try Task.checkCancellation()
                guard canUpload(), store.operationContext == context else { throw CancellationError() }
                self.update(item.id) { $0.thumbnailData = thumbnail }
                let uploaded: UploadedAttachment
                if store.isDemo {
                    uploaded = .init(id: item.id.uuidString, filename: item.filename, originalFilename: item.filename,
                        contentType: "application/octet-stream", size: Int(item.byteCount), path: "synthetic/" + item.filename,
                        workspaceID: nil, createdAt: FirstMateDemo.timestamp)
                } else {
                    uploaded = try await store.uploadAttachment(at: item.sourceURL,
                        contentType: UTType(filenameExtension: item.sourceURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream",
                        expectedContext: context)
                }
                try Task.checkCancellation()
                guard self.isAlive(store: store, context: context), self.generation == originalGeneration else { return }
                self.update(item.id) { $0.uploaded = uploaded; $0.status = .uploaded; $0.error = nil }
                item.removeSourceFileIfOwned()
            } catch {
                guard self.isAlive(store: store, context: context), self.generation == originalGeneration else {
                    item.removeSourceFileIfOwned(); return
                }
                self.update(item.id) {
                    $0.status = .failed
                    $0.error = error is CancellationError ? "Upload stopped. Return to this conversation to retry." : error.localizedDescription
                }
            }
        }
    }

    private func update(_ id: UUID, _ action: (inout TerminalAttachment) -> Void) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        action(&attachments[index])
    }

    private func cleanup(_ candidates: [AttachmentCandidate]) {
        for candidate in candidates where candidate.ownership == .appTemporary {
            try? FileManager.default.removeItem(at: candidate.sourceURL)
        }
    }

    func discard() {
        uploads.values.forEach { $0.cancel() }; uploads = [:]
        (attachments + frozen.values.flatMap(\.attachments)).forEach { $0.removeSourceFileIfOwned() }
        attachments = []; picks = []; frozen = [:]; containsDictation = false; recoveredVoice = nil
        revision &+= 1; generation = UUID()
    }
}
