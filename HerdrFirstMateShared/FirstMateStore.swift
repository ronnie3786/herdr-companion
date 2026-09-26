import Foundation
import Observation
import SwiftUI

@MainActor @Observable
final class FirstMateStore {
    struct LifecycleIdentity: Equatable, Hashable, Sendable {
        fileprivate let value: UUID

        /// Safe to use as SwiftUI/task identity. This is a random local lifecycle
        /// marker, never a companion credential or server token.
        var opaqueID: String { value.uuidString.lowercased() }
    }

    struct OperationContext: Equatable, Sendable {
        fileprivate let generation: Int
        fileprivate let featureID: String?
        let lifecycleIdentity: LifecycleIdentity

        func matchesFeature(_ id: String) -> Bool { featureID == id }

        func destinationID(for featureID: String) -> String? {
            guard matchesFeature(featureID) else { return nil }
            return "first-mate:\(featureID):lifecycle:\(lifecycleIdentity.opaqueID)"
        }
    }

    struct ControlLease: Equatable, Sendable {
        fileprivate let id: UUID
        fileprivate let lifecycleIdentity: LifecycleIdentity
    }

    private struct FeedbackKey: Hashable {
        let featureID: String
        let messageID: String

        init(_ featureID: String, _ messageID: String) {
            self.featureID = featureID
            self.messageID = messageID
        }
    }

    /// Capture when the human acts, before scheduling an asynchronous UI task.
    var operationContext: OperationContext {
        .init(generation: generation, featureID: selectedFeatureID, lifecycleIdentity: lifecycleIdentity)
    }
    var lifecycle: LifecycleIdentity { lifecycleIdentity }

    private(set) var features: [FirstMateFeature] = []
    private(set) var snapshots: [String: FirstMateSnapshot] = [:]
    var selectedFeatureID: String?
    var inspector = FirstMateInspector.overview
    /// The Documents inspector's Documents/Links sub-tab. Shared so the
    /// prominent PR section can open the Links collection directly.
    var documentsMode = FirstMateDocumentsMode.documents
    var graphMode = false
    var selectedVisitID: String?
    var draft = ""
    var search = ""
    var showArchived = false
    var isCreating = false
    #if os(macOS)
    var isDark = true
    #else
    var isDark = ProcessInfo.processInfo.arguments.contains("-HerdrFirstMateDark")
    #endif
    private(set) var isDemo = false
    private(set) var isRefreshing = false
    private(set) var isSending = false
    private(set) var hasLoaded = false
    private(set) var error: String?
    private(set) var unsupported = false
    private(set) var archiveSupported = false
    private(set) var attachmentsSupported = false
    private(set) var contextSupported = false
    private(set) var safeModelSettingsSupported = false
    private(set) var linksSupported = false
    private(set) var controlAvailable = false
    // Response feedback is companion data that deliberately stays outside
    // FirstMateSnapshot and composer state. Caches are scoped to this client
    // lifecycle and to the exact feature and response they came from.
    //
    // The capability is tri-state so a failed or unanswered check is never
    // mistaken for a confirmed old server: only a successful capability
    // response without `first-mate-feedback-v1` shows upgrade guidance, while
    // `.unknown` keeps cached ratings readable and an open draft recoverable.
    private(set) var feedbackCapability: FirstMateFeedbackCapability = .unknown
    var feedbackSupported: Bool { feedbackCapability == .supported }
    private(set) var feedbackCategories: [FirstMateFeedbackCategory] = []
    private(set) var feedbackCategoriesLoaded = false
    private(set) var isLoadingFeedbackCategories = false
    private(set) var isAddingFeedbackCategory = false
    private(set) var feedbackCategoriesError: String?
    private var feedbackRecords: [String: [String: FirstMateFeedback]] = [:]
    private var loadedFeedbackFeatures: Set<String> = []
    private var loadingFeedbackFeatures: Set<String> = []
    private var feedbackErrors: [String: String] = [:]
    private var savingFeedbackKeys: Set<FeedbackKey> = []
    private var feedbackSaveErrors: [FeedbackKey: String] = [:]
    private var feedbackConflicts: Set<FeedbackKey> = []
    private var feedbackDrafts: [FeedbackKey: FirstMateFeedbackDraft] = [:]
    private var pendingFeedbackRequests: [FeedbackKey: FirstMateFeedbackSaveRequest] = [:]
    private(set) var isSavingLink = false
    private(set) var linkMutationError: String?
    private(set) var lastUpdated: Date?
    private(set) var runtimeHealth: FirstMateRuntimeHealth?
    var openedResource: FirstMateResource?
    var resourcePresentation: FirstMateResourcePresentation?
    private(set) var resourceText = ""
    private(set) var sessionMessages: [FirstMateSessionMessage]? = nil
    private(set) var resourceLoading = false
    private(set) var resourceError: String?
    private(set) var resourceUsage: FirstMateUsage?
    private(set) var resourceModelSelection: FirstMateModelSelection?
    private(set) var sessionNextBefore: Int?
    private(set) var sessionTotalMessages: Int?
    private(set) var sessionLoadedMessages = 0
    private(set) var isLoadingEarlier = false
    private(set) var sessionPageError: String?
    private var generation = 0
    private var lifecycleIdentity = LifecycleIdentity(value: UUID())
    private var activeControlLease: ControlLease?
    private var resourceGeneration = 0
    private var drafts: [String: String] = [:]
    private var pendingMessages: [String: (text: String, requestID: String)] = [:]
    private var pendingLinkSaves: [String: (draft: FirstMateLinkDraft, requestID: String)] = [:]
    private var pendingLinkVisibility: [String: String] = [:]
    private var demoStep = 0
    @ObservationIgnored private var client: (any FirstMateClient)?
    @ObservationIgnored private var journalEventSnapshotsSupported = false
    #if os(macOS)
    @ObservationIgnored let composerDrafts = FirstMateComposerDraftStore()
    #endif

    var colorScheme: ColorScheme { isDark ? .dark : .light }
    var canManageLinks: Bool { isDemo || linksSupported }
    var canMutateLinks: Bool { isDemo || controlAvailable }
    var snapshot: FirstMateSnapshot? { selectedFeatureID.flatMap { snapshots[$0] } }
    var hasUnsentDrafts: Bool {
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || drafts.values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        #if os(macOS)
        return hasText || composerDrafts.hasStagedContent
        #else
        return hasText
        #endif
    }

    func executionDisplayStatus(for feature: FirstMateFeature) -> String {
        if !isDemo, ["running", "coordinating", "recovering"].contains(feature.status),
           error != nil || runtimeHealth?.warning != nil {
            return "unverified"
        }
        return feature.status
    }

    var filteredFeatures: [FirstMateFeature] {
        features.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.goal.localizedCaseInsensitiveContains(search) }
    }
    var activeFeatures: [FirstMateFeature] { filteredFeatures.filter { !$0.isArchived } }
    var archivedFeatures: [FirstMateFeature] { filteredFeatures.filter(\.isArchived) }

    func configure(client: (any FirstMateClient)?, demo: Bool) {
        generation += 1
        lifecycleIdentity = LifecycleIdentity(value: UUID())
        resourceGeneration += 1
        self.client = client
        isDemo = demo
        features = []
        snapshots = [:]
        selectedFeatureID = nil
        selectedVisitID = nil
        draft = ""
        drafts = [:]
        pendingMessages = [:]
        openedResource = nil
        resourcePresentation = nil
        resourceText = ""
        sessionMessages = nil
        resourceLoading = false
        resourceError = nil
        resourceUsage = nil
        resourceModelSelection = nil
        resetSessionPagination()
        error = nil
        unsupported = false
        archiveSupported = demo
        attachmentsSupported = demo
        contextSupported = demo
        safeModelSettingsSupported = demo
        feedbackCapability = demo ? .supported : .unknown
        feedbackCategories = demo ? FirstMateFeedbackDefaults.categories.map {
            FirstMateFeedbackCategory(id: $0.id, label: $0.label, createdAt: FirstMateDemo.timestamp)
        } : []
        feedbackCategoriesLoaded = demo
        isLoadingFeedbackCategories = false
        isAddingFeedbackCategory = false
        feedbackCategoriesError = nil
        feedbackRecords = [:]
        loadedFeedbackFeatures = []
        loadingFeedbackFeatures = []
        feedbackErrors = [:]
        savingFeedbackKeys = []
        feedbackSaveErrors = [:]
        feedbackConflicts = []
        feedbackDrafts = [:]
        pendingFeedbackRequests = [:]
        linksSupported = demo
        isSavingLink = false
        linkMutationError = nil
        pendingLinkSaves = [:]
        pendingLinkVisibility = [:]
        activeControlLease = nil
        controlAvailable = demo
        isRefreshing = false
        isSending = false
        isCreating = false
        showArchived = false
        documentsMode = .documents
        hasLoaded = false
        lastUpdated = nil
        #if os(macOS)
        composerDrafts.discardAll()
        #endif
        runtimeHealth = nil
        if demo {
            demoStep = 0
            for value in FirstMateDemo.features(step: 0) { receive(value) }
            selectedFeatureID = features.first?.id
            hasLoaded = true
        }
    }

    func acquireControlLease(available: Bool) -> ControlLease {
        let lease = ControlLease(id: UUID(), lifecycleIdentity: lifecycleIdentity)
        activeControlLease = lease
        controlAvailable = available
        return lease
    }

    func updateControlLease(_ lease: ControlLease, available: Bool) {
        guard activeControlLease == lease, lease.lifecycleIdentity == lifecycleIdentity else { return }
        controlAvailable = available
    }

    func releaseControlLease(_ lease: ControlLease) {
        guard activeControlLease == lease, lease.lifecycleIdentity == lifecycleIdentity else { return }
        activeControlLease = nil
        controlAvailable = false
    }

    func select(_ id: String) {
        if let old = selectedFeatureID { drafts[old] = draft }
        selectedFeatureID = id
        draft = drafts[id] ?? ""
        selectedVisitID = snapshots[id]?.feature.currentVisitID
        error = nil
        linkMutationError = nil
        closeResource()
    }

    /// Navigates from Overview to the Documents inspector's Links collection.
    func showLinksCollection() {
        inspector = .documents
        documentsMode = .links
    }

    func composerDraft(for context: OperationContext) -> String {
        guard context.generation == generation,
              context.lifecycleIdentity == lifecycleIdentity,
              let featureID = context.featureID else { return "" }
        return selectedFeatureID == featureID ? draft : drafts[featureID] ?? ""
    }

    func setComposerDraft(_ value: String, for context: OperationContext) {
        guard context.generation == generation,
              context.lifecycleIdentity == lifecycleIdentity,
              let featureID = context.featureID else { return }
        if selectedFeatureID == featureID {
            draft = value
        } else {
            drafts[featureID] = value
        }
    }

    func receive(_ value: FirstMateSnapshot) {
        guard value.ok else { return }
        if let existing = snapshots[value.feature.id],
           existing.feature.revision > value.feature.revision ||
           (existing.feature.modelSettingsRevision ?? 0) > (value.feature.modelSettingsRevision ?? 0) { return }
        if value.hasDetails, let existing = snapshots[value.feature.id], existing.feature.revision == value.feature.revision,
           existing.latestEventSequence > value.latestEventSequence { return }
        if let health = value.runtimeHealth, health != runtimeHealth { runtimeHealth = health }
        // An identical poll changes nothing on screen. Dictionary and array
        // element writes notify observers even when the value is unchanged.
        if value.hasDetails, snapshots[value.feature.id] == value,
           features.contains(where: { $0.id == value.feature.id && $0 == value.feature }) { return }
        if !value.hasDetails, var existing = snapshots[value.feature.id] {
            // Mutations acknowledge the feature; their omitted arrays and usage are not deletions.
            // A delayed mutation may have the same feature/settings revisions as a
            // newer full session-rotation snapshot. Only valid, strictly ordered
            // timestamps fence its stale session identity; equal or unparseable
            // synthetic timestamps retain the compatible merge behavior.
            var feature = value.feature
            let hasStaleIdentityMetadata = Self.isStrictlyOlderTimestamp(
                feature.updatedAt,
                than: existing.feature.updatedAt
            )
            if feature.usage == nil { feature.usage = existing.feature.usage }
            feature.verification = Self.retainedVerification(
                incoming: feature.verification,
                includesField: feature.includesVerification,
                cached: existing.feature.verification,
                incomingIsStale: hasStaleIdentityMetadata,
                authoritative: false
            )
            feature.includesVerification = feature.includesVerification || existing.feature.includesVerification
            if hasStaleIdentityMetadata {
                feature.updatedAt = existing.feature.updatedAt
                feature.nativeSessionID = existing.feature.nativeSessionID
                feature.includesNativeSessionID = existing.feature.includesNativeSessionID
                feature.coordinatorContext = existing.feature.coordinatorContext
                feature.modelSelection = existing.feature.modelSelection
            } else {
                // An explicit native_session_id:null is a managed rotation and
                // must not resurrect its predecessor. Only genuinely omitted
                // old-server metadata inherits the cached identity and context.
                if !feature.includesNativeSessionID {
                    feature.nativeSessionID = existing.feature.nativeSessionID
                }
                if feature.coordinatorContext == nil,
                   feature.nativeSessionID == existing.feature.nativeSessionID {
                    feature.coordinatorContext = existing.feature.coordinatorContext
                }
                if feature.modelSelection == nil { feature.modelSelection = existing.feature.modelSelection }
            }
            existing.feature = feature
            if value.includesLinks { existing.links = value.links }
            snapshots[value.feature.id] = existing
        } else {
            var incoming = value
            if let existing = snapshots[incoming.feature.id] {
                // A delayed full snapshot can carry an older assessment than
                // the one already cached. Keep the newer verdict so a stale
                // verified state cannot be resurrected.
                incoming.feature.verification = Self.retainedVerification(
                    incoming: incoming.feature.verification,
                    includesField: incoming.feature.includesVerification,
                    cached: existing.feature.verification,
                    incomingIsStale: Self.isStrictlyOlderTimestamp(
                        incoming.feature.updatedAt,
                        than: existing.feature.updatedAt
                    ),
                    authoritative: true
                )
                incoming.feature.includesVerification = incoming.feature.includesVerification
                    || existing.feature.includesVerification
            }
            if !incoming.includesLinks, let existing = snapshots[incoming.feature.id] {
                // A server without the additive links field is not evidence
                // that previously cached links were removed.
                incoming.links = existing.links
            }
            snapshots[incoming.feature.id] = incoming
        }
        let acceptedFeature = snapshots[value.feature.id]?.feature ?? value.feature
        if let index = features.firstIndex(where: { $0.id == value.feature.id }) {
            features[index] = acceptedFeature
        } else { features.append(acceptedFeature) }
        lastUpdated = .now
    }

    func refresh() async {
        guard !isRefreshing else { return }
        if isDemo {
            features = snapshots.values.map(\.feature)
                .filter { showArchived || !$0.isArchived }
                .sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
            reconcileSelection()
            return
        }
        guard let client else { return }
        let capturedGeneration = generation
        isRefreshing = true
        defer { if capturedGeneration == generation { isRefreshing = false } }
        do {
            do {
                let capabilities = try await client.fetchFirstMateCapabilities()
                guard capturedGeneration == generation else { return }
                archiveSupported = capabilities.ok && capabilities.supportsArchive
                attachmentsSupported = capabilities.ok && capabilities.supportsAttachments
                contextSupported = capabilities.ok && capabilities.supportsContext
                safeModelSettingsSupported = capabilities.ok && capabilities.supportsSafeModelSettings
                let journalOnly = capabilities.ok && capabilities.supportsJournalEventSnapshots
                if journalEventSnapshotsSupported != journalOnly { journalEventSnapshotsSupported = journalOnly }
                feedbackCapability = capabilities.ok
                    ? (capabilities.supportsFeedback ? .supported : .unsupported)
                    : .unknown
                linksSupported = capabilities.ok && capabilities.supportsLinks
            } catch {
                guard capturedGeneration == generation else { return }
                archiveSupported = false
                attachmentsSupported = false
                contextSupported = false
                safeModelSettingsSupported = false
                journalEventSnapshotsSupported = false
                feedbackCapability = .unknown
                // A transient capability failure is not proof that this
                // companion lacks first-mate-links-v1, so keep the last known
                // answer instead of showing upgrade guidance mid-outage.
            }
            let list = try await client.fetchFirstMateFeatures(scope: showArchived ? .all : .active)
            guard capturedGeneration == generation else { return }
            guard list.ok else { throw APIError.invalidResponse }
            runtimeHealth = list.runtimeHealth
            features = list.features.map { feature in
                guard let cached = snapshots[feature.id]?.feature else { return feature }
                if cached.revision > feature.revision || cached.updatedAt > feature.updatedAt {
                    var retained = cached
                    if let usage = feature.usage { retained.usage = usage }
                    return retained
                }
                var refreshed = feature
                if refreshed.usage == nil { refreshed.usage = cached.usage }
                refreshed.verification = Self.retainedVerification(
                    incoming: refreshed.verification,
                    includesField: refreshed.includesVerification,
                    cached: cached.verification,
                    incomingIsStale: Self.isStrictlyOlderTimestamp(refreshed.updatedAt, than: cached.updatedAt),
                    authoritative: true
                )
                refreshed.includesVerification = refreshed.includesVerification || cached.includesVerification
                return refreshed
            }
            reconcileSelection()
            if let id = selectedFeatureID {
                // Pi telemetry is most of a long-running feature's events and no
                // First Mate screen shows it.
                let value = try await client.fetchFirstMateFeature(id, journalEventsOnly: journalEventSnapshotsSupported)
                guard capturedGeneration == generation else { return }
                guard value.ok, value.feature.id == id else { throw APIError.invalidResponse }
                receive(value)
            }
            hasLoaded = true
            unsupported = false
            error = nil
            lastUpdated = .now
        } catch is CancellationError { return }
        catch {
            guard capturedGeneration == generation else { return }
            hasLoaded = true
            record(error)
        }
    }

    func create(title: String, goal: String, cwd: String, requestID: String, expectedContext: OperationContext? = nil) async -> Bool {
        if let expectedContext, expectedContext != operationContext { return false }
        guard !isSending else { return false }
        let capturedGeneration = generation
        isSending = true
        defer { if capturedGeneration == generation { isSending = false } }
        if isDemo {
            let feature = FirstMateDemo.newFeature(title: title, goal: goal, cwd: cwd)
            receive(feature)
            select(feature.feature.id)
            return true
        }
        guard let client else { error = "Connect to a companion server to create a feature."; return false }
        do {
            let value = try await client.createFirstMateFeature(title: title, goal: goal, cwd: cwd, requestID: requestID)
            guard capturedGeneration == generation else { return false }
            guard value.ok, !value.feature.id.isEmpty else { throw APIError.invalidResponse }
            receive(value)
            select(value.feature.id)
            await refresh()
            return true
        } catch {
            guard capturedGeneration == generation else { return false }
            record(error)
            return false
        }
    }

    func send(expectedContext: OperationContext? = nil, expectedText: String? = nil) async {
        if let expectedContext, expectedContext != operationContext { return }
        if let expectedText, expectedText != draft { return }
        let originalDraft = draft
        let text = originalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let context = expectedContext ?? operationContext
        guard await sendPreparedMessage(text, expectedContext: context),
              let id = context.featureID else { return }
        if context == operationContext, draft == originalDraft { draft = "" }
        if drafts[id] == originalDraft { drafts[id] = nil }
    }

    /// Sends a fully serialized composer payload. Callers own draft, attachment,
    /// and quote clearing so only the exact accepted items are removed.
    func sendPreparedMessage(_ text: String, expectedContext: OperationContext) async -> Bool {
        guard expectedContext == operationContext,
              let id = expectedContext.featureID,
              !isSending,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if isDemo {
            sendDemo(text, featureID: id)
            return true
        }
        guard let client else {
            error = "Connect to send your direction."
            return false
        }
        let pending = pendingMessages[id].flatMap { $0.text == text ? $0 : nil }
            ?? (text: text, requestID: UUID().uuidString)
        pendingMessages[id] = pending
        let capturedGeneration = generation
        isSending = true
        defer { if capturedGeneration == generation { isSending = false } }
        do {
            let value = try await client.sendFirstMateMessage(featureID: id, text: text, requestID: pending.requestID)
            guard capturedGeneration == generation, expectedContext.generation == generation else { return false }
            guard value.ok, value.feature.id == id else { throw APIError.invalidResponse }
            receive(value)
            pendingMessages[id] = nil
            error = nil
            await refresh()
            return capturedGeneration == generation && expectedContext.generation == generation
        } catch {
            guard capturedGeneration == generation else { return false }
            record(error)
            return false
        }
    }

    func uploadAttachment(
        at fileURL: URL,
        contentType: String,
        expectedContext: OperationContext
    ) async throws -> UploadedAttachment {
        guard expectedContext == operationContext,
              let featureID = expectedContext.featureID,
              attachmentsSupported,
              let client else { throw APIError.invalidResponse }
        let capturedGeneration = generation
        let response = try await client.uploadFirstMateAttachment(
            featureID: featureID,
            fileURL: fileURL,
            contentType: contentType
        )
        guard capturedGeneration == generation,
              expectedContext.generation == generation,
              response.ok,
              let attachment = response.attachment else { throw APIError.invalidResponse }
        return attachment
    }

    func transcribeVoice(
        at fileURL: URL,
        expectedContext: OperationContext
    ) async throws -> VoiceTranscriptionResponse {
        guard expectedContext == operationContext, let client else { throw APIError.invalidResponse }
        let capturedGeneration = generation
        let response = try await client.transcribeFirstMateVoice(fileURL: fileURL)
        guard capturedGeneration == generation, expectedContext.generation == generation, response.ok else {
            throw APIError.invalidResponse
        }
        return response
    }

    func isDestinationAlive(_ context: OperationContext) -> Bool {
        guard context.generation == generation,
              context.lifecycleIdentity == lifecycleIdentity,
              let featureID = context.featureID else { return false }
        return snapshots[featureID] != nil || features.contains { $0.id == featureID }
    }

    func snapshot(for context: OperationContext) -> FirstMateSnapshot? {
        guard context.generation == generation,
              context.lifecycleIdentity == lifecycleIdentity,
              let featureID = context.featureID else { return nil }
        return snapshots[featureID]
    }

    func feature(for context: OperationContext) -> FirstMateFeature? {
        guard context.generation == generation,
              context.lifecycleIdentity == lifecycleIdentity else { return nil }
        return snapshot(for: context)?.feature
            ?? features.first { context.matchesFeature($0.id) }
    }

    func perform(_ action: String, expectedContext: OperationContext? = nil) async {
        if let expectedContext, expectedContext != operationContext { return }
        guard let id = selectedFeatureID, !isSending else { return }
        if isDemo {
            guard var value = snapshot else { return }
            value.feature.status = action == "pause" ? "paused" : action == "cancel" ? "cancelled" : "awaiting_direction"
            value.feature.revision += 1
            receive(value)
            return
        }
        guard let client else { return }
        let capturedGeneration = generation
        isSending = true
        defer { if capturedGeneration == generation { isSending = false } }
        do {
            let value = try await client.performFirstMateAction(featureID: id, action: action, requestID: UUID().uuidString)
            guard capturedGeneration == generation else { return }
            guard value.ok, value.feature.id == id else { throw APIError.invalidResponse }
            receive(value)
            error = nil
            await refresh()
        } catch { if capturedGeneration == generation { record(error) } }
    }

    func setArchived(featureID: String, archived: Bool, reason: FirstMateArchiveReason? = nil) async -> Bool {
        guard !isSending else { return false }
        if isDemo {
            guard var value = snapshots[featureID] else { return false }
            value.feature.archivedAt = archived ? FirstMateDemo.timestamp : nil
            value.feature.archiveReason = archived ? reason?.rawValue : nil
            receive(value)
            if archived && !showArchived { features.removeAll { $0.id == featureID } }
            reconcileSelection()
            return true
        }
        guard archiveSupported else {
            error = "Update this companion server to archive First Mate features."
            return false
        }
        guard let client else { error = "Connect to archive this feature."; return false }
        let capturedGeneration = generation
        isSending = true
        defer { if capturedGeneration == generation { isSending = false } }
        do {
            let value = try await client.setFirstMateArchived(
                featureID: featureID,
                archived: archived,
                reason: archived ? reason : nil,
                requestID: UUID().uuidString
            )
            guard capturedGeneration == generation, value.ok, value.feature.id == featureID else {
                throw APIError.invalidResponse
            }
            receive(value)
            if archived && !showArchived {
                features.removeAll { $0.id == featureID }
                reconcileSelection()
            }
            error = nil
            await refresh()
            return true
        } catch {
            if capturedGeneration == generation { record(error) }
            return false
        }
    }

    /// Explicitly saves one PR or general HTTP(S) link to this feature.
    ///
    /// The caller's captured context fences the whole operation: a delayed
    /// response can only update the feature it was requested for, never a
    /// newly selected feature or a replacement host. A failed attempt keeps
    /// its request identity so an explicit retry is idempotent.
    @discardableResult
    func saveLink(_ draft: FirstMateLinkDraft, expectedContext: OperationContext? = nil) async -> Bool {
        if let expectedContext, expectedContext != operationContext { return false }
        let context = expectedContext ?? operationContext
        guard let featureID = context.featureID, !isSavingLink else { return false }
        guard let normalized = FirstMateLinkClassifier.normalize(url: draft.url, title: draft.title, kind: draft.kind) else {
            if context == operationContext {
                linkMutationError = "Enter an absolute http or https URL without credentials."
            }
            return false
        }
        if isDemo {
            applyDemoLink(normalized, featureID: featureID)
            if context == operationContext { linkMutationError = nil }
            return true
        }
        guard controlAvailable else {
            if context == operationContext { linkMutationError = "This First Mate view does not currently control this feature." }
            return false
        }
        guard linksSupported else {
            if context == operationContext { linkMutationError = Self.linksUpgradeMessage }
            return false
        }
        guard let client else {
            if context == operationContext { linkMutationError = "Connect to this companion to save links." }
            return false
        }
        let pending = pendingLinkSaves[featureID].flatMap { $0.draft == draft ? $0 : nil }
            ?? (draft: draft, requestID: UUID().uuidString)
        pendingLinkSaves[featureID] = pending
        let capturedGeneration = generation
        isSavingLink = true
        defer { if capturedGeneration == generation { isSavingLink = false } }
        do {
            let response = try await client.saveFirstMateLink(
                featureID: featureID,
                url: normalized.url,
                title: normalized.titleSupplied ? normalized.title : nil,
                kind: draft.kind,
                requestID: pending.requestID
            )
            guard capturedGeneration == generation,
                  response.ok,
                  response.snapshot.feature.id == featureID else { throw APIError.invalidResponse }
            receive(response.snapshot)
            pendingLinkSaves[featureID] = nil
            if context == operationContext { linkMutationError = nil }
            return capturedGeneration == generation
        } catch {
            guard capturedGeneration == generation else { return false }
            if context == operationContext { linkMutationError = Self.linkFailureMessage(error) }
            return false
        }
    }

    /// Reversibly hides or restores one feature-owned link.
    @discardableResult
    func setLinkHidden(_ linkID: String, hidden: Bool, expectedContext: OperationContext? = nil) async -> Bool {
        if let expectedContext, expectedContext != operationContext { return false }
        let context = expectedContext ?? operationContext
        guard let featureID = context.featureID, !isSavingLink,
              let link = snapshots[featureID]?.link(linkID),
              link.featureID == featureID else { return false }
        if isDemo {
            applyDemoVisibility(linkID, hidden: hidden, featureID: featureID)
            if context == operationContext { linkMutationError = nil }
            return true
        }
        guard controlAvailable else {
            if context == operationContext { linkMutationError = "This First Mate view does not currently control this feature." }
            return false
        }
        guard linksSupported else {
            if context == operationContext { linkMutationError = Self.linksUpgradeMessage }
            return false
        }
        guard let client else {
            if context == operationContext { linkMutationError = "Connect to this companion to change links." }
            return false
        }
        let pendingKey = "\(featureID)|\(linkID)|\(hidden)"
        let requestID = pendingLinkVisibility[pendingKey] ?? UUID().uuidString
        pendingLinkVisibility[pendingKey] = requestID
        let capturedGeneration = generation
        isSavingLink = true
        defer { if capturedGeneration == generation { isSavingLink = false } }
        do {
            let response = try await client.setFirstMateLinkVisibility(
                featureID: featureID,
                linkID: linkID,
                hidden: hidden,
                requestID: requestID
            )
            guard capturedGeneration == generation,
                  response.ok,
                  response.snapshot.feature.id == featureID else { throw APIError.invalidResponse }
            receive(response.snapshot)
            pendingLinkVisibility[pendingKey] = nil
            if context == operationContext { linkMutationError = nil }
            return capturedGeneration == generation
        } catch {
            guard capturedGeneration == generation else { return false }
            if context == operationContext { linkMutationError = Self.linkFailureMessage(error) }
            return false
        }
    }

    static let linksUpgradeMessage = "Saving links needs a companion server advertising first-mate-links-v1. Update and restart the companion, then Refresh."

    private static func linkFailureMessage(_ error: Error) -> String {
        if case let APIError.server(status, _) = error, status == 404 || status == 501 {
            return linksUpgradeMessage
        }
        return error.localizedDescription
    }

    private func applyDemoLink(_ normalized: FirstMateNormalizedLink, featureID: String) {
        guard var value = snapshots[featureID] else { return }
        if let index = value.links.firstIndex(where: { $0.url == normalized.url }) {
            if normalized.titleSupplied, value.links[index].titleSource != "user" {
                value.links[index].title = normalized.title
                value.links[index].titleSource = "user"
                receive(value)
            }
            return
        }
        value.links.append(FirstMateLink(
            id: "demo-link-\(UUID().uuidString.lowercased())",
            featureID: featureID,
            url: normalized.url,
            kind: normalized.kind,
            title: normalized.title,
            titleSource: normalized.titleSupplied ? "user" : "",
            source: "user",
            provenance: .init(),
            hidden: false,
            createdAt: FirstMateDemo.timestamp,
            updatedAt: FirstMateDemo.timestamp
        ))
        receive(value)
    }

    private func applyDemoVisibility(_ linkID: String, hidden: Bool, featureID: String) {
        guard var value = snapshots[featureID],
              let index = value.links.firstIndex(where: { $0.id == linkID }) else { return }
        value.links[index].hidden = hidden
        value.links[index].updatedAt = FirstMateDemo.timestamp
        receive(value)
    }

    func fetchModelCatalog(expectedContext: OperationContext) async throws -> FirstMateModelCatalog {
        guard expectedContext == operationContext, !isDemo, let client else { throw APIError.invalidResponse }
        let catalog = try await client.fetchFirstMateModels()
        guard expectedContext == operationContext, catalog.ok else { throw APIError.invalidResponse }
        return catalog
    }

    func reportComposerError(_ message: String) {
        error = message
    }

    func saveModelSettings(
        _ settings: FirstMateModelSettings,
        expectedContext: OperationContext,
        expectedSessionID: String? = nil,
        expectedSettingsRevision: Int? = nil
    ) async throws {
        guard expectedContext == operationContext, let id = selectedFeatureID,
              !isDemo, !isSending, let client else { throw APIError.invalidResponse }
        if let expectedSettingsRevision {
            guard let current = feature(for: expectedContext),
                  current.nativeSessionID == expectedSessionID,
                  current.modelSettingsRevision == expectedSettingsRevision else {
                throw APIError.invalidResponse
            }
        }
        let capturedGeneration = generation
        isSending = true
        defer { if generation == capturedGeneration { isSending = false } }
        let value = try await client.setFirstMateModel(featureID: id, settings: settings)
        guard generation == capturedGeneration,
              expectedContext.generation == generation,
              value.ok,
              value.feature.id == id else { throw APIError.invalidResponse }
        receive(value)
    }

    // MARK: - Response feedback

    /// A companion's low-quality reason catalog, loaded only from a server that
    /// advertises `first-mate-feedback-v1`. Categories are append-only, so a
    /// delayed read merges by stable ID instead of replacing newer additions,
    /// and `feedbackCategoriesLoaded` becomes true only after a full fetch.
    @discardableResult
    func loadFeedbackCategories(expectedContext: OperationContext) async -> Bool {
        guard isCurrentFeedbackContext(expectedContext), feedbackSupported, !isDemo,
              !isLoadingFeedbackCategories, let client else { return false }
        isLoadingFeedbackCategories = true
        feedbackCategoriesError = nil
        defer { if isCurrentFeedbackContext(expectedContext) { isLoadingFeedbackCategories = false } }
        do {
            let response = try await client.fetchFirstMateFeedbackCategories()
            guard isCurrentFeedbackContext(expectedContext) else { return false }
            guard response.ok, response.categories.allSatisfy({ !$0.id.isEmpty && !$0.label.isEmpty }) else {
                throw APIError.invalidResponse
            }
            for category in response.categories { mergeFeedbackCategory(category) }
            feedbackCategoriesLoaded = true
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard isCurrentFeedbackContext(expectedContext) else { return false }
            feedbackCategoriesError = error.localizedDescription
            return false
        }
    }

    /// Loads every retained rating for one exact feature. A delayed completion
    /// updates only the feature it was captured for, and a lower revision can
    /// never replace a newer local record. Returns false when the full fetch
    /// did not succeed so callers can distinguish loaded from partial state.
    @discardableResult
    func loadFeedback(expectedContext: OperationContext) async -> Bool {
        guard let featureID = expectedContext.featureID,
              isCurrentFeedbackContext(expectedContext), feedbackSupported, !isDemo,
              !loadingFeedbackFeatures.contains(featureID), let client else { return false }
        loadingFeedbackFeatures.insert(featureID)
        feedbackErrors[featureID] = nil
        defer { if isCurrentFeedbackContext(expectedContext) { loadingFeedbackFeatures.remove(featureID) } }
        do {
            let response = try await client.fetchFirstMateFeedback(featureID: featureID)
            guard isCurrentFeedbackContext(expectedContext) else { return false }
            guard response.ok, response.featureID == featureID,
                  response.records.allSatisfy({ $0.featureID == featureID && !$0.messageID.isEmpty }) else {
                throw APIError.invalidResponse
            }
            for record in response.records { receiveFeedback(record, featureID: featureID) }
            loadedFeedbackFeatures.insert(featureID)
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard isCurrentFeedbackContext(expectedContext) else { return false }
            feedbackErrors[featureID] = error.localizedDescription
            return false
        }
    }

    /// Saves the editor draft for one exact response. The draft's pinned base
    /// revision is the only base used, so a refresh that arrives mid-edit can
    /// never silently authorize an overwrite; a stale revision is surfaced as
    /// a conflict for explicit reload-and-retry recovery. Safe retries reuse
    /// the failed request identity, and a failure keeps both the known record
    /// and the editable draft intact.
    @discardableResult
    func saveFeedback(
        _ draft: FirstMateFeedbackDraft,
        messageID: String,
        expectedContext: OperationContext
    ) async -> Bool {
        guard let featureID = expectedContext.featureID,
              isCurrentFeedbackContext(expectedContext),
              !messageID.isEmpty else { return false }
        let key = FeedbackKey(featureID, messageID)
        guard !savingFeedbackKeys.contains(key) else { return false }
        // The typed draft is retained before any write attempt so a rejection or
        // failure can restore the editable explanation with a visible retry.
        // Editor drafts already carry the pin their load established; a nil
        // base revision means a quick action, which is pinned once at
        // submission time from the record the user could see.
        var retainedDraft = draft
        if retainedDraft.baseRevision == nil {
            retainedDraft.baseRevision = feedbackRecords[featureID]?[messageID]?.revision ?? 0
        }
        feedbackDrafts[key] = retainedDraft
        feedbackSaveErrors[key] = nil
        feedbackConflicts.remove(key)
        let requestDraft = retainedDraft.forRequest
        switch feedbackCapability {
        case .unsupported:
            feedbackSaveErrors[key] = "Update this companion server to rate First Mate responses."
            return false
        case .unknown:
            // A failed or unanswered capability check is a temporary
            // connection problem: keep the draft and retry path, and never
            // claim the server needs an update it may already have.
            feedbackSaveErrors[key] = "Connect to this feature's host to save feedback."
            return false
        case .supported:
            break
        }
        // Writes revalidate the control grant; reads do not need it.
        guard controlAvailable else {
            feedbackSaveErrors[key] = "This workspace is read-only right now."
            return false
        }
        if isDemo {
            feedbackDrafts[key] = nil
            feedbackSaveErrors[key] = nil
            feedbackConflicts.remove(key)
            receiveFeedback(demoFeedback(from: requestDraft, featureID: featureID, messageID: messageID), featureID: featureID)
            return true
        }
        guard let client else {
            feedbackSaveErrors[key] = "Connect to this feature's host to save feedback."
            return false
        }
        let expectedRevision = retainedDraft.baseRevision ?? 0
        var request = FirstMateFeedbackSaveRequest(
            rating: requestDraft.rating,
            categoryIDs: requestDraft.categoryIDs,
            comment: requestDraft.comment,
            expectedRevision: expectedRevision,
            requestID: ""
        )
        if let pending = pendingFeedbackRequests[key], pending.hasSamePayload(as: request) {
            request = pending
        } else {
            request.requestID = UUID().uuidString
            pendingFeedbackRequests[key] = request
        }
        let capturedGeneration = generation
        let capturedLifecycle = lifecycleIdentity
        savingFeedbackKeys.insert(key)
        defer {
            if capturedGeneration == generation, capturedLifecycle == lifecycleIdentity {
                savingFeedbackKeys.remove(key)
            }
        }
        do {
            let response = try await client.saveFirstMateFeedback(
                featureID: featureID,
                messageID: messageID,
                request: request
            )
            guard capturedGeneration == generation, capturedLifecycle == lifecycleIdentity else { return false }
            guard response.ok, response.featureID == featureID,
                  response.feedback.featureID == featureID,
                  response.feedback.messageID == messageID else { throw APIError.invalidResponse }
            receiveFeedback(response.feedback, featureID: featureID)
            pendingFeedbackRequests[key] = nil
            feedbackDrafts[key] = nil
            feedbackSaveErrors[key] = nil
            feedbackConflicts.remove(key)
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard capturedGeneration == generation, capturedLifecycle == lifecycleIdentity else { return false }
            // The known record and the typed draft stay available for an
            // explicit retry; the saved rating is never optimistically changed.
            feedbackSaveErrors[key] = error.localizedDescription
            if Self.isStaleRevisionError(error) { feedbackConflicts.insert(key) }
            return false
        }
    }

    /// Explicit resolution for a stale-revision rejection. Reloads the exact
    /// feature's retained ratings, then rebases only the preserved local draft
    /// onto the newly loaded revision so a deliberate retry uses the new
    /// revision and a fresh request identity. The attempted up/clear payload
    /// is kept exactly as submitted.
    @discardableResult
    func resolveFeedbackConflict(
        messageID: String,
        expectedContext: OperationContext
    ) async -> Bool {
        guard let featureID = expectedContext.featureID,
              isCurrentFeedbackContext(expectedContext),
              !messageID.isEmpty else { return false }
        guard await loadFeedback(expectedContext: expectedContext) else { return false }
        guard isCurrentFeedbackContext(expectedContext) else { return false }
        let key = FeedbackKey(featureID, messageID)
        var draft = feedbackDrafts[key] ?? feedbackDraft(for: featureID, messageID: messageID)
        draft.baseRevision = feedbackRecords[featureID]?[messageID]?.revision ?? 0
        feedbackDrafts[key] = draft
        feedbackSaveErrors[key] = nil
        feedbackConflicts.remove(key)
        return true
    }

    /// Immediate positive rating, used by the thumbs-up control.
    @discardableResult
    func rateFeedback(
        _ rating: FirstMateFeedbackRating,
        messageID: String,
        expectedContext: OperationContext
    ) async -> Bool {
        await saveFeedback(
            FirstMateFeedbackDraft(rating: rating),
            messageID: messageID,
            expectedContext: expectedContext
        )
    }

    /// Adds a reusable reason and returns it, reusing an equivalent category.
    @discardableResult
    func addFeedbackCategory(
        label rawLabel: String,
        expectedContext: OperationContext
    ) async -> FirstMateFeedbackCategory? {
        guard isCurrentFeedbackContext(expectedContext) else { return nil }
        switch feedbackCapability {
        case .unsupported:
            feedbackCategoriesError = "Update this companion server to add feedback reasons."
            return nil
        case .unknown:
            feedbackCategoriesError = "Connect to this feature's host to add a reason."
            return nil
        case .supported:
            break
        }
        guard controlAvailable else {
            feedbackCategoriesError = "This workspace is read-only right now."
            return nil
        }
        let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, !label.contains(where: { $0.isNewline }),
              label.unicodeScalars.count <= 80 else {
            feedbackCategoriesError = "Enter a single-line reason of 80 characters or fewer."
            return nil
        }
        if isDemo { return demoCategory(named: label) }
        guard !isAddingFeedbackCategory, let client else {
            feedbackCategoriesError = "Connect to this feature's host to add a reason."
            return nil
        }
        let capturedGeneration = generation
        let capturedLifecycle = lifecycleIdentity
        isAddingFeedbackCategory = true
        defer {
            if capturedGeneration == generation, capturedLifecycle == lifecycleIdentity {
                isAddingFeedbackCategory = false
            }
        }
        do {
            let response = try await client.createFirstMateFeedbackCategory(
                label: label,
                requestID: UUID().uuidString
            )
            guard capturedGeneration == generation, capturedLifecycle == lifecycleIdentity else { return nil }
            guard response.ok, !response.category.id.isEmpty, !response.category.label.isEmpty else {
                throw APIError.invalidResponse
            }
            mergeFeedbackCategory(response.category)
            // A single-category response is not a full catalog: keep the
            // loaded flag reserved for a successful full fetch so the editor
            // can offer a category reload until the complete list is known.
            feedbackCategoriesError = nil
            return response.category
        } catch is CancellationError {
            return nil
        } catch {
            guard capturedGeneration == generation, capturedLifecycle == lifecycleIdentity else { return nil }
            feedbackCategoriesError = error.localizedDescription
            return nil
        }
    }

    func feedback(for featureID: String, messageID: String) -> FirstMateFeedback? {
        feedbackRecords[featureID]?[messageID]
    }

    /// The editor's starting point: an unsaved draft if one exists, otherwise
    /// the loaded record pinned to its retained revision, otherwise an
    /// unselected negative rating. A draft is never seeded from the empty cache
    /// before the first load completes, and a completed fetch that found no
    /// record pins revision zero so a delayed first rating conflicts instead of
    /// authorizing a silent overwrite.
    func feedbackDraft(for featureID: String, messageID: String) -> FirstMateFeedbackDraft {
        let key = FeedbackKey(featureID, messageID)
        if let draft = feedbackDrafts[key] { return draft }
        guard hasLoadedFeedback(for: featureID) else { return FirstMateFeedbackDraft() }
        if let record = feedbackRecords[featureID]?[messageID] {
            return FirstMateFeedbackDraft(
                rating: record.rating ?? .down,
                categoryIDs: record.categoryIDs,
                comment: record.comment,
                baseRevision: record.revision
            )
        }
        return FirstMateFeedbackDraft(baseRevision: 0)
    }

    func setFeedbackDraft(
        _ draft: FirstMateFeedbackDraft,
        for featureID: String,
        messageID: String,
        expectedContext: OperationContext
    ) {
        guard let contextFeature = expectedContext.featureID,
              contextFeature == featureID,
              isCurrentFeedbackContext(expectedContext) else { return }
        let key = FeedbackKey(featureID, messageID)
        // The editor freezes while a save is in flight; the store keeps that
        // invariant even if a view task races the submission, and an editor
        // cannot seed a draft before the first record load completes.
        guard !savingFeedbackKeys.contains(key),
              hasLoadedFeedback(for: featureID) else { return }
        // An edit never loses the revision it was pinned to: a caller that
        // supplies a fresh struct inherits the existing draft's pin, then the
        // visible record, then the loaded-but-absent zero pin. A refresh that
        // arrives mid-edit can therefore never authorize an overwrite.
        var pinnedDraft = draft
        if pinnedDraft.baseRevision == nil {
            pinnedDraft.baseRevision = feedbackDrafts[key]?.baseRevision
                ?? feedbackRecords[featureID]?[messageID]?.revision
                ?? 0
        }
        feedbackDrafts[key] = pinnedDraft
        feedbackSaveErrors[key] = nil
        feedbackConflicts.remove(key)
    }

    /// Cancelling an edit discards only that edit, never the saved rating.
    func discardFeedbackDraft(for featureID: String, messageID: String) {
        let key = FeedbackKey(featureID, messageID)
        feedbackDrafts[key] = nil
        feedbackSaveErrors[key] = nil
        feedbackConflicts.remove(key)
    }

    /// True once the retained ratings for this feature have loaded completely.
    /// The synthetic demo and legacy fixture features are always loaded.
    func hasLoadedFeedback(for featureID: String) -> Bool {
        isDemo || loadedFeedbackFeatures.contains(featureID)
    }

    func canRate(messageID: String, featureID: String) -> Bool {
        guard let message = snapshots[featureID]?.messages.first(where: { $0.id == messageID }) else { return false }
        return FirstMateFeedbackEligibility.isEligible(message)
    }

    func isLoadingFeedback(for featureID: String) -> Bool { loadingFeedbackFeatures.contains(featureID) }
    func feedbackError(for featureID: String) -> String? { feedbackErrors[featureID] }
    func isSavingFeedback(featureID: String, messageID: String) -> Bool {
        savingFeedbackKeys.contains(FeedbackKey(featureID, messageID))
    }
    func feedbackSaveError(featureID: String, messageID: String) -> String? {
        feedbackSaveErrors[FeedbackKey(featureID, messageID)]
    }
    /// True when the last save failed because another client advanced the
    /// retained revision. Recovery reloads the record before retrying.
    func feedbackConflict(featureID: String, messageID: String) -> Bool {
        feedbackConflicts.contains(FeedbackKey(featureID, messageID))
    }

    private func isCurrentFeedbackContext(_ context: OperationContext) -> Bool {
        context.generation == generation && context.lifecycleIdentity == lifecycleIdentity
    }

    private static func isStaleRevisionError(_ error: Error) -> Bool {
        if case APIError.server(let status, _) = error { return status == 409 }
        return false
    }

    /// A lower revision is a delayed read or a delayed receipt; the newer
    /// locally known record always wins.
    private func receiveFeedback(_ record: FirstMateFeedback, featureID: String) {
        guard record.featureID == featureID, !record.messageID.isEmpty, record.revision >= 0 else { return }
        var records = feedbackRecords[featureID] ?? [:]
        if let existing = records[record.messageID], existing.revision > record.revision { return }
        records[record.messageID] = record
        feedbackRecords[featureID] = records
    }

    /// Categories are append-only user data. A delayed full fetch adds or
    /// refreshes entries by stable ID and never removes a newer local addition.
    private func mergeFeedbackCategory(_ category: FirstMateFeedbackCategory) {
        if let index = feedbackCategories.firstIndex(where: { $0.id == category.id }) {
            feedbackCategories[index] = category
        } else {
            feedbackCategories.append(category)
        }
    }

    private func demoFeedback(
        from draft: FirstMateFeedbackDraft,
        featureID: String,
        messageID: String
    ) -> FirstMateFeedback {
        let existing = feedbackRecords[featureID]?[messageID]
        let message = snapshots[featureID]?.messages.first { $0.id == messageID }
        return FirstMateFeedback(
            messageID: messageID,
            featureID: featureID,
            rating: draft.rating,
            categoryIDs: draft.categoryIDs,
            comment: draft.comment,
            revision: (existing?.revision ?? 0) + 1,
            createdAt: existing?.createdAt ?? FirstMateDemo.timestamp,
            updatedAt: FirstMateDemo.timestamp,
            provenance: FirstMateFeedbackProvenance(
                responseText: message?.text ?? "",
                responseCreatedAt: message?.createdAt,
                sourceKind: "legacy",
                inReplyTo: nil,
                visitID: nil,
                featureRevision: snapshots[featureID]?.feature.revision,
                coordinatorSessionID: nil,
                sessionProvenance: "unavailable"
            )
        )
    }

    private func demoCategory(named label: String) -> FirstMateFeedbackCategory {
        let normalized = Self.normalizedCategoryLabel(label)
        if let existing = feedbackCategories.first(where: { Self.normalizedCategoryLabel($0.label) == normalized }) {
            return existing
        }
        let collapsed = label.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let category = FirstMateFeedbackCategory(
            id: "fmc-demo-\(feedbackCategories.count + 1)",
            label: collapsed,
            createdAt: FirstMateDemo.timestamp
        )
        feedbackCategories.append(category)
        feedbackCategoriesLoaded = true
        feedbackCategoriesError = nil
        return category
    }

    private static func normalizedCategoryLabel(_ label: String) -> String {
        label.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    func open(_ resource: FirstMateResource) async {
        resourceGeneration += 1
        let token = resourceGeneration
        openedResource = resource
        if resourcePresentation == nil { resourcePresentation = FirstMateResourcePresentation() }
        resourceText = ""
        sessionMessages = nil
        resourceError = nil
        resourceUsage = resource.usage(in: snapshot)
        resourceModelSelection = resource.modelSelection(in: snapshot)
        resetSessionPagination()
        resourceLoading = true
        defer { if token == resourceGeneration { resourceLoading = false } }
        if isDemo {
            sessionMessages = FirstMateDemo.sessionMessages(for: resource)
            resourceText = FirstMateDemo.content(for: resource, snapshot: snapshot)
            return
        }
        guard let client else { resourceError = "Reconnect to this feature's host to read its saved resource."; return }
        do {
            let content: String
            switch resource {
            case .document(let document):
                let response = try await client.fetchFirstMateDocument(document.id)
                guard response.ok, response.document.id == document.id else { throw APIError.invalidResponse }
                content = response.document.content ?? response.content ?? "This document has no text preview."
            case .session, .history:
                guard let sessionID = resource.nativeSessionID else { throw APIError.invalidResponse }
                let response = try await client.fetchFirstMateSession(sessionID, before: nil)
                guard response.ok, response.nativeSessionID == sessionID else { throw APIError.invalidResponse }
                guard token == resourceGeneration else { return }
                sessionMessages = response.messages
                sessionNextBefore = response.nextBefore
                sessionTotalMessages = response.totalMessages
                sessionLoadedMessages = response.messages?.count ?? 0
                if let usage = response.usage { resourceUsage = usage }
                if let selection = response.modelSelection { resourceModelSelection = selection }
                content = response.messages?.map { "\($0.role.capitalized)\n\($0.text)" }.joined(separator: "\n\n")
                    ?? response.content ?? "The saved session does not have any messages yet."
            }
            guard token == resourceGeneration else { return }
            resourceText = content
        } catch { if token == resourceGeneration { resourceError = error.localizedDescription } }
    }

    func closeResource() {
        resourceGeneration += 1
        openedResource = nil
        resourcePresentation = nil
        resourceLoading = false
        sessionMessages = nil
        resourceUsage = nil
        resourceModelSelection = nil
        resetSessionPagination()
    }

    func loadEarlierSessionMessages() async {
        guard !isLoadingEarlier, let before = sessionNextBefore,
              let sessionID = openedResource?.nativeSessionID, let client else { return }
        let token = resourceGeneration
        isLoadingEarlier = true
        sessionPageError = nil
        defer { if token == resourceGeneration { isLoadingEarlier = false } }
        do {
            let response = try await client.fetchFirstMateSession(sessionID, before: before)
            guard token == resourceGeneration else { return }
            guard response.ok, response.nativeSessionID == sessionID else { throw APIError.invalidResponse }
            if let next = response.nextBefore, next < 0 || next >= before { throw APIError.invalidResponse }
            let earlier = response.messages ?? []
            if let sessionMessages { self.sessionMessages = earlier + sessionMessages }
            let text = earlier.map { "\($0.role.capitalized)\n\($0.text)" }.joined(separator: "\n\n")
            if !text.isEmpty { resourceText = text + (resourceText.isEmpty ? "" : "\n\n" + resourceText) }
            sessionLoadedMessages += earlier.count
            sessionNextBefore = response.nextBefore
            sessionTotalMessages = response.totalMessages ?? sessionTotalMessages
            if let usage = response.usage { resourceUsage = usage }
            if let selection = response.modelSelection { resourceModelSelection = selection }
        } catch { if token == resourceGeneration { sessionPageError = error.localizedDescription } }
    }

    private static func isStrictlyOlderTimestamp(_ candidate: String, than existing: String) -> Bool {
        guard let candidateDate = HerdrTimestamp.date(from: candidate),
              let existingDate = HerdrTimestamp.date(from: existing) else { return false }
        return candidateDate < existingDate
    }

    /// Conservative verification merge for partial acknowledgements and
    /// delayed full snapshots.
    ///
    /// - A partial acknowledgement (mutation response) that omits the field
    ///   inherits the cached assessment.
    /// - An authoritative full snapshot that omits, nulls, or malforms the
    ///   field reports unavailable evidence: the cached verdict is downgraded
    ///   so an old green never remains current.
    /// - An explicit empty assessment never erases retained evidence for a
    ///   partial acknowledgement.
    /// - A strictly older feature timestamp keeps the cached assessment.
    /// - Otherwise the assessment with the newer feature revision and
    ///   computation timestamp wins, so a delayed verified response cannot
    ///   overwrite a newer partial or failed verdict.
    private static func retainedVerification(
        incoming: FirstMateVerification?,
        includesField: Bool,
        cached: FirstMateVerification?,
        incomingIsStale: Bool,
        authoritative: Bool
    ) -> FirstMateVerification? {
        if incomingIsStale { return cached }
        guard let cached else { return includesField ? incoming : nil }
        guard includesField, let incoming else {
            // An omitted or malformed field is evidence of absence only in an
            // authoritative full snapshot; a mutation acknowledgement merely
            // did not carry the assessment.
            return authoritative ? Self.unavailableVerification() : cached
        }
        return incoming.isAtLeastAsFresh(as: cached) ? incoming : cached
    }

    private static func unavailableVerification() -> FirstMateVerification {
        FirstMateVerification(
            status: .unavailable,
            coverageReasons: ["The companion did not report structured suite evidence for this feature."],
            evidencePresent: true
        )
    }

    private func resetSessionPagination() {
        sessionNextBefore = nil
        sessionTotalMessages = nil
        sessionLoadedMessages = 0
        isLoadingEarlier = false
        sessionPageError = nil
    }

    private func reconcileSelection() {
        guard selectedFeatureID == nil || !features.contains(where: { $0.id == selectedFeatureID }) else { return }
        if let first = features.first {
            select(first.id)
        } else {
            if let old = selectedFeatureID { drafts[old] = draft }
            selectedFeatureID = nil
            selectedVisitID = nil
            draft = ""
            closeResource()
        }
    }

    func advanceDemo() {
        guard isDemo else { return }
        demoStep = (demoStep + 1) % FirstMateDemo.stepTitles.count
        for value in FirstMateDemo.features(step: demoStep) {
            snapshots[value.feature.id] = nil
            receive(value)
        }
        selectedVisitID = snapshot?.feature.currentVisitID
    }
    var demoStepTitle: String { FirstMateDemo.stepTitles[demoStep] }

    private func sendDemo(_ text: String, featureID: String) {
        guard var value = snapshot else { return }
        value.messages.append(.init(id: UUID().uuidString, featureID: featureID, role: "user", text: text, status: "delivered", createdAt: FirstMateDemo.timestamp))
        value.messages.append(.init(id: UUID().uuidString, featureID: featureID, role: "assistant", text: "Your direction is recorded in this synthetic demo. Use Next scenario to inspect the planned implementation, review, checkpoint, and handoff states.", status: "delivered", createdAt: FirstMateDemo.timestamp))
        value.feature.revision += 1
        receive(value)
    }

    private func record(_ failure: Error) {
        if case APIError.server(let status, _) = failure, status == 404 || status == 501 {
            unsupported = true
            error = "This companion server needs First Mate support. Update the server to a version with first-mate-v1."
        } else { error = failure.localizedDescription }
    }
}

/// Owns the UI-control grant for one visible workspace. Moving this lease to a
/// different store or lifecycle revokes the previous grant first. Store-issued
/// tokens make delayed cleanup harmless after a newer view has taken ownership.
@MainActor
final class FirstMateWorkspaceControlLease {
    private weak var store: FirstMateStore?
    private var token: FirstMateStore.ControlLease?

    func update(store newStore: FirstMateStore, available: Bool) {
        if store === newStore,
           let token,
           token.lifecycleIdentity == newStore.lifecycle {
            newStore.updateControlLease(token, available: available)
            return
        }

        release()
        store = newStore
        token = newStore.acquireControlLease(available: available)
    }

    func release() {
        if let store, let token {
            store.releaseControlLease(token)
        }
        store = nil
        token = nil
    }

    func release(storeID: ObjectIdentifier, lifecycleIdentity: FirstMateStore.LifecycleIdentity) {
        guard let store,
              let token,
              ObjectIdentifier(store) == storeID,
              token.lifecycleIdentity == lifecycleIdentity else { return }
        release()
    }
}
