import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct FirstMateComposerAttachmentActions {
    let photos: () -> Void
    let files: () -> Void
    let paste: () -> Void
    var sample: (() -> Void)?
}

struct FirstMateConversationComposer: View {
    @Bindable var model: HerdrAppModel
    @Bindable var fleet: FirstMateMobileFleetStore
    @Bindable var store: FirstMateStore
    @Bindable var material: FirstMateMobileComposerDraft
    let target: FirstMateFeatureTarget
    let placeholder: String
    let canControl: Bool
    let active: Bool
    let send: @MainActor () -> Bool
    let openDocuments: (() -> Void)?
    let presentationChanged: (Bool) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var voice = FirstMateMobileVoiceController()
    @State private var sheet: AccessorySheet?
    @State private var photos: [PhotosPickerItem] = []
    @State private var showsPhotos = false
    @State private var showsFiles = false
    @State private var preparation = ComposerPhotoPreparationState()
    @State private var photoTask: Task<Void, Never>?
    @State private var importTicket: ImportTicket?

    private struct AccessorySheet: Identifiable {
        enum Kind { case model, context }
        let id = UUID()
        let kind: Kind
        let context: FirstMateStore.OperationContext
    }
    private struct ImportTicket {
        let store: FirstMateStore
        let material: FirstMateMobileComposerDraft
        let target: FirstMateFeatureTarget
        let context: FirstMateStore.OperationContext
        let generation: UUID
        let navigation: UUID
    }
    private var ownerAvailable: Bool {
        active && canControl && model.selectedTab == .firstMate && model.firstMateCanControl(machineID: target.machineID)
            && fleet.store(for: target) === store && fleet.selectedTarget == target
            && store.selectedFeatureID == target.featureID && material.lifecycle == store.lifecycle && store.controlAvailable
    }
    private var busy: Bool { store.isSending || store.isSubmitting(featureID: target.featureID) }
    private var covered: Bool { showsPhotos || showsFiles || sheet != nil }
    private var text: Binding<String> {
        let context = store.operationContext
        return Binding(get: { store.composerDraft(for: context) }, set: { material.edit($0, store: store, context: context) })
    }
    private var contextPresentation: FirstMateCoordinatorContextPresentation? {
        store.snapshots[target.featureID].map { .init(feature: $0.feature, capabilityAvailable: store.contextSupported) }
    }
    private var mentionOptions: [FirstMateMentionOption] {
        guard let match = FirstMateMentionTrigger.match(in: text.wrappedValue) else { return [] }
        return FirstMateMentionOption.options(query: match.query,
            features: FirstMateMentionOption.taggableFeatures(fleet.conversations, machineID: target.machineID),
            crew: store.snapshots[target.featureID]?.assignments ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            accessories
            if !mentionOptions.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(mentionOptions) { option in
                            Button {
                                material.choose(option.candidate, store: store, context: store.operationContext)
                            } label: {
                                HStack(spacing: 6) {
                                    FirstMateEmojiDisc(emoji: option.emoji, size: 24)
                                    Text(option.candidate.name).herdrFont(.caption)
                                }.padding(.horizontal, 8).frame(minHeight: 44).background(HerdrTheme.codeFill, in: .capsule)
                            }.buttonStyle(.plain).disabled(!ownerAvailable)
                                .accessibilityLabel("Tag \(option.candidate.name), \(option.detail)")
                        }
                    }
                }.scrollIndicators(.hidden).accessibilityIdentifier("first-mate-mention-picker")
            }
            if !material.attachments.isEmpty {
                ComposerAttachmentTray(attachments: material.attachments,
                    retry: { item in
                        let ticket = captureImport()
                        material.retry(item, store: store, context: ticket.context, canUpload: { current(ticket) })
                    }, remove: material.remove)
            }
            if preparation.isPreparing { ProgressView(preparation.statusText).herdrFont(.caption) }
            if let error = material.error {
                Text(error).herdrFont(.caption).foregroundStyle(HerdrTheme.warning).fixedSize(horizontal: false, vertical: true)
            }
            if let recovered = material.recoveredVoice {
                DisclosureGroup("Saved voice transcript") {
                    Text(recovered).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Button("Append to draft") {
                        let context = store.operationContext
                        let old = store.composerDraft(for: context)
                        _ = material.receiveVoice(recovered, initialRevision: material.revision, initialText: old, store: store, context: context)
                        material.recoveredVoice = nil; material.error = nil
                    }.frame(minHeight: 44).disabled(!ownerAvailable)
                }.herdrFont(.footnote)
            }
            FirstMateMessageComposer(text: text, placeholder: placeholder,
                canControl: ownerAvailable, isSending: busy || material.blocksSending || preparation.blocksSending,
                send: { _ = send() }, openDocuments: openDocuments,
                attachmentActions: store.attachmentsSupported ? .init(
                    photos: { importTicket = captureImport(); showsPhotos = true },
                    files: { importTicket = captureImport(); showsFiles = true },
                    paste: { _ = ComposerCodeBlockPaste.paste(into: text) }, sample: sampleAttachmentAction) : nil,
                hasAttachments: material.hasAttachments, voice: voice, beginVoice: beginVoice,
                composerHint: voice.hint,
                focusedHint: store.attachmentsSupported
                    ? "Type @ to tag a feature. Hold the mic to talk."
                    : "Update this machine's companion server to attach files. Hold the mic to talk.")
        }
        .dynamicTypeSize(...HerdrTheme.maximumDynamicTypeSize)
        .photosPicker(isPresented: $showsPhotos, selection: $photos,
            maxSelectionCount: AttachmentPolicy.maximumCount, matching: .images)
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard let ticket = importTicket else { return }
            do {
                let urls = try result.get()
                guard current(ticket) else { return }
                let candidates = try urls.map { try AttachmentPolicy.candidate(for: $0, ownership: .userSelected) }
                ticket.material.enqueue(candidates, store: ticket.store, context: ticket.context,
                    generation: ticket.generation, canUpload: { current(ticket) })
            } catch { if current(ticket) { ticket.material.error = error.localizedDescription } }
        }
        .onChange(of: photos) { _, items in importPhotos(items) }
        .sheet(item: $sheet) { item in
            if item.kind == .model {
                FirstMateMobileModelControls(store: store, context: item.context, canControl: ownerAvailable)
            } else {
                FirstMateMobileContextSheet(store: store, context: item.context)
            }
        }
        .onChange(of: covered) { _, covered in
            presentationChanged(covered)
            if covered { voice.cancel(preserveRecognizedText: true) }
        }
        .onChange(of: ownerAvailable) { _, available in if !available { invalidate() } }
        .onChange(of: store.lifecycle) { _, _ in invalidate() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { invalidate() } }
        .onChange(of: voice.capture.recorderStatus) { _, status in
            if status == .finished { voice.finish(explicitSend: false) }
        }
        .onDisappear { invalidate(); presentationChanged(false) }
        .sensoryFeedback(.impact(weight: .light), trigger: voice.startPulse)
    }

    /// One compact line above the pill, like the Mac composer's context line
    /// and model pill: the context ring, then model and thinking.
    private var accessories: some View {
        HStack(spacing: 8) {
            contextButton.fixedSize(horizontal: true, vertical: false)
            modelButton
            Spacer(minLength: 0)
        }
        .herdrFont(.caption).foregroundStyle(HerdrTheme.secondaryText)
    }

    @ViewBuilder private var contextButton: some View {
        if let contextPresentation {
            Button { sheet = .init(kind: .context, context: store.operationContext) } label: {
                HStack(spacing: 6) {
                    ZStack {
                        Circle().stroke(HerdrTheme.strongOutline, lineWidth: 2)
                        if let fraction = contextPresentation.fraction {
                            Circle().trim(from: 0, to: fraction).stroke(contextPresentation.pressureReached ? HerdrTheme.warning : HerdrTheme.accent, lineWidth: 2)
                                .rotationEffect(.degrees(-90))
                        }
                    }.frame(width: 13, height: 13).accessibilityHidden(true)
                    Text(contextPresentation.chipLine).lineLimit(1)
                        .foregroundStyle(contextPresentation.pressureReached ? HerdrTheme.warning : HerdrTheme.secondaryText)
                }
                .padding(.horizontal, 10).frame(minHeight: 30).herdrControlGlass(in: .capsule)
                .frame(minHeight: 44).contentShape(.rect)
            }
            .buttonStyle(.plain).accessibilityLabel(contextPresentation.summary)
            .accessibilityIdentifier("first-mate-context")
        }
    }

    private var modelButton: some View {
        Button { sheet = .init(kind: .model, context: store.operationContext) } label: {
            HStack(spacing: 5) {
                Image(systemName: "bolt").font(.system(size: 11, weight: .semibold)).foregroundStyle(HerdrTheme.iconTint)
                Text(modelLabel).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(HerdrTheme.iconTint)
            }
            .padding(.horizontal, 10).frame(minHeight: 30).herdrControlGlass(in: .capsule)
            .frame(minHeight: 44).contentShape(.rect)
        }
        .buttonStyle(.plain).accessibilityLabel("Model and thinking, \(modelLabel)")
        .accessibilityIdentifier("first-mate-model-controls")
    }

    private var modelLabel: String {
        guard let snapshot = store.snapshots[target.featureID] else { return "Model settings unavailable" }
        let feature = FirstMateMobileModelPolicy.featureWithObservedSettings(snapshot)
        let model = feature.nativeSessionID == nil ? feature.coordinatorModel : feature.modelSelection?.actualModel
        let thinking = feature.nativeSessionID == nil ? feature.coordinatorThinking : feature.modelSelection?.actualThinking
        // The Mac pill shows the model's last path component, never a full
        // provider route that would wrap onto a second line.
        let name = model.map { $0.components(separatedBy: "/").last ?? $0 }
        return [name ?? (feature.nativeSessionID == nil ? "Host default" : "Session model not reported"), thinking?.capitalized].compactMap { $0 }.joined(separator: " · ")
    }

    private var sampleAttachmentAction: (() -> Void)? {
        #if DEBUG
        guard store.isDemo, ProcessInfo.processInfo.arguments.contains("-HerdrFirstMateComposerScenarios") else { return nil }
        return {
            let ticket = captureImport()
            do {
                let folder = FileManager.default.temporaryDirectory.appending(path: "herdr-synthetic-\(UUID())")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appending(path: "Sample.txt")
                try Data("Synthetic attachment. No agents launched.".utf8).write(to: url)
                let candidate = try AttachmentPolicy.candidate(for: url, ownership: .appTemporary)
                material.enqueue([candidate], store: store, context: ticket.context, generation: ticket.generation,
                                 canUpload: { current(ticket) })
            } catch { material.error = error.localizedDescription }
        }
        #else
        return nil
        #endif
    }

    private func captureImport() -> ImportTicket {
        .init(store: store, material: material, target: target, context: store.operationContext,
              generation: material.generation, navigation: fleet.chat.currentNavigationIntent)
    }
    private func current(_ ticket: ImportTicket) -> Bool {
        ticket.material.generation == ticket.generation && ticket.material.lifecycle == ticket.store.lifecycle
            && ticket.store.operationContext == ticket.context && fleet.store(for: ticket.target) === ticket.store
            && fleet.selectedTarget == ticket.target && fleet.chat.isCurrentNavigation(ticket.navigation)
            && model.firstMateCanControl(machineID: ticket.target.machineID) && ticket.store.controlAvailable
            && model.selectedTab == .firstMate
    }
    private func beginVoice(_ locked: Bool) {
        let ticket = captureImport()
        guard ownerAvailable, !busy, !preparation.isPreparing else { return }
        voice.begin(store: store, material: material, locked: locked,
            isCurrent: { current(ticket) && !FirstMateMobileTranscriptPolicy.isClosed(ticket.store.snapshot(for: ticket.context)) },
            submit: send)
    }
    private func invalidate() {
        voice.cancel(preserveRecognizedText: true)
        photoTask?.cancel(); photoTask = nil; preparation.cancel(); photos = []
        showsPhotos = false; showsFiles = false; importTicket = nil; sheet = nil
    }
    private func importPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty, let ticket = importTicket else { return }
        photoTask?.cancel()
        let token = preparation.begin(photoCount: items.count)
        photoTask = Task {
            var candidates: [AttachmentCandidate] = []
            defer {
                for candidate in candidates { try? FileManager.default.removeItem(at: candidate.sourceURL) }
                if preparation.finish(token) { photos = []; photoTask = nil }
            }
            do {
                try AttachmentPolicy.validateCount(existingCount: ticket.material.attachments.count, incomingCount: items.count)
                for item in items {
                    try Task.checkCancellation()
                    guard current(ticket), preparation.owns(token) else { throw CancellationError() }
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw APIError.invalidResponse }
                    try Task.checkCancellation()
                    guard current(ticket), preparation.owns(token) else { throw CancellationError() }
                    let type = item.supportedContentTypes.first ?? .jpeg
                    let url = FileManager.default.temporaryDirectory.appending(path: "herdr-first-mate-\(UUID()).\(type.preferredFilenameExtension ?? "jpg")")
                    let candidate = AttachmentCandidate(sourceURL: url, filename: url.lastPathComponent, byteCount: Int64(data.count), ownership: .appTemporary)
                    try AttachmentPolicy.validate(existingAttachments: ticket.material.attachments, incomingCandidates: candidates + [candidate])
                    candidates.append(candidate)
                    try data.write(to: url, options: [.atomic, .completeFileProtection])
                }
                try Task.checkCancellation()
                guard current(ticket), preparation.owns(token) else { throw CancellationError() }
                ticket.material.enqueue(candidates, store: ticket.store, context: ticket.context,
                    generation: ticket.generation, canUpload: { current(ticket) })
                candidates = []
            } catch is CancellationError { }
            catch { if current(ticket), preparation.owns(token) { ticket.material.error = error.localizedDescription } }
        }
    }
}

struct FirstMateMobileContextSheet: View {
    @Bindable var store: FirstMateStore
    let context: FirstMateStore.OperationContext
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                if let snapshot = store.snapshot(for: context) {
                    let value = FirstMateCoordinatorContextPresentation(feature: snapshot.feature, capabilityAvailable: store.contextSupported)
                    VStack(alignment: .leading, spacing: 16) {
                        Text(value.summary).herdrFont(.body, weight: .semibold)
                        if let pressure = value.pressure { Text(pressure).foregroundStyle(value.pressureReached ? HerdrTheme.warning : HerdrTheme.secondaryText) }
                        if let measured = value.measurement { Text(measured).foregroundStyle(HerdrTheme.secondaryText) }
                        Text(value.policy)
                    }.fixedSize(horizontal: false, vertical: true).padding(16).frame(maxWidth: 640, alignment: .leading)
                } else { ContentUnavailableView("Context unavailable", systemImage: "info.circle") }
            }.frame(maxWidth: .infinity)
                .herdrSheetSurface()
                .navigationTitle("Context").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { HerdrSheetCloseButton { dismiss() } } }
        }.herdrAppChrome(separateSurface: true)
            .accessibilityIdentifier("first-mate-context-sheet")
    }
}
