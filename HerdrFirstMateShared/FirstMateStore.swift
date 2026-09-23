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
    private(set) var controlAvailable = false
    // Response feedback is companion data that deliberately stays outside
    // FirstMateSnapshot and composer state. Caches are scoped to this client
    // lifecycle and to the exact feature and response they came from.
    private(set) var feedbackSupported = false
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
    private(set) var lastUpdated: Date?
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
    private var demoStep = 0
    @ObservationIgnored private var client: (any FirstMateClient)?
    #if os(macOS)
    @ObservationIgnored let composerDrafts = FirstMateComposerDraftStore()
    #endif

    var colorScheme: ColorScheme { isDark ? .dark : .light }
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
        feedbackSupported = demo
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
        activeControlLease = nil
        controlAvailable = demo
        isRefreshing = false
        isSending = false
        isCreating = false
        showArchived = false
        hasLoaded = false
        lastUpdated = nil
        #if os(macOS)
        composerDrafts.discardAll()
        #endif
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
        closeResource()
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
           (existing.events.map(\.sequence).max() ?? 0) > (value.events.map(\.sequence).max() ?? 0) { return }
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
            snapshots[value.feature.id] = existing
        } else { snapshots[value.feature.id] = value }
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
                feedbackSupported = capabilities.ok && capabilities.supportsFeedback
            } catch {
                guard capturedGeneration == generation else { return }
                archiveSupported = false
                attachmentsSupported = false
                contextSupported = false
                safeModelSettingsSupported = false
                feedbackSupported = false
            }
            let list = try await client.fetchFirstMateFeatures(scope: showArchived ? .all : .active)
            guard capturedGeneration == generation else { return }
            guard list.ok else { throw APIError.invalidResponse }
            features = list.features.map { feature in
                guard let cached = snapshots[feature.id]?.feature else { return feature }
                if cached.revision > feature.revision || cached.updatedAt > feature.updatedAt {
                    var retained = cached
                    if let usage = feature.usage { retained.usage = usage }
                    return retained
                }
                var refreshed = feature
                if refreshed.usage == nil { refreshed.usage = cached.usage }
                return refreshed
            }
            reconcileSelection()
            if let id = selectedFeatureID {
                let value = try await client.fetchFirstMateFeature(id)
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
        guard feedbackSupported else {
            feedbackSaveErrors[key] = "Update this companion server to rate First Mate responses."
            return false
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
        guard feedbackSupported else {
            feedbackCategoriesError = "Update this companion server to add feedback reasons."
            return nil
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
