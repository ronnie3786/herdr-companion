import SwiftUI

/// Captured identity for one open feedback editor. The context freezes the
/// companion lifecycle and selected feature so a delayed save can never
/// retarget another response, host, or connection.
struct FirstMateFeedbackEditorTarget: Identifiable, Equatable {
    let featureID: String
    let messageID: String
    let responseText: String
    let expectedContext: FirstMateStore.OperationContext

    var id: String { "\(featureID)|\(messageID)" }
}

extension FirstMateFeedbackDraft {
    /// Category selection is independent per reason and preserves pick order,
    /// so the request keeps exactly what the user chose.
    static func togglingCategory(_ categoryID: String, in categoryIDs: [String]) -> [String] {
        if let index = categoryIDs.firstIndex(of: categoryID) {
            var updated = categoryIDs
            updated.remove(at: index)
            return updated
        }
        return categoryIDs + [categoryID]
    }
}

/// Pure editor state derived from the store for one captured target. `make` is
/// the only place the editor decides availability, so a stale feature, a
/// reconnected lifecycle, a read-only workspace, a pending save, an unloaded
/// record, and a missing capability all disable writing without hiding a saved
/// rating.
struct FirstMateFeedbackEditorState: Equatable {
    var draft: FirstMateFeedbackDraft
    var isTargetAlive: Bool
    var isWritable: Bool
    var isFeedbackLoaded: Bool
    var isSaving: Bool
    var isAddingCategory: Bool
    var isCategoriesLoaded: Bool
    var isLoadingCategories: Bool
    var showsUpgradeNotice: Bool
    var ratingErrorMessage: String?
    var categoryErrorMessage: String?
    var saveErrorMessage: String?
    var hasConflict: Bool

    /// Input is frozen while a save is in flight and until the retained record
    /// has loaded; the submitted draft stays exactly as typed.
    var isEditable: Bool {
        isTargetAlive && isWritable && isFeedbackLoaded && !isSaving
    }

    /// A stale-revision conflict must be explicitly resolved by reloading the
    /// latest record before a retry can be submitted.
    var canSave: Bool {
        isEditable && !isAddingCategory && !showsUpgradeNotice && !hasConflict
    }

    @MainActor
    static func make(store: FirstMateStore, target: FirstMateFeedbackEditorTarget) -> FirstMateFeedbackEditorState {
        let isTargetAlive = target.expectedContext == store.operationContext
        let supported = store.feedbackSupported
        return FirstMateFeedbackEditorState(
            // The stored draft is the single source of truth: a failed save
            // keeps it, and discarding it restores the saved record prefill.
            // Until the first record load completes it is never seeded from
            // the empty cache.
            draft: store.feedbackDraft(for: target.featureID, messageID: target.messageID),
            isTargetAlive: isTargetAlive,
            isWritable: isTargetAlive && supported && store.controlAvailable,
            isFeedbackLoaded: store.hasLoadedFeedback(for: target.featureID),
            isSaving: store.isSavingFeedback(featureID: target.featureID, messageID: target.messageID),
            isAddingCategory: store.isAddingFeedbackCategory,
            isCategoriesLoaded: store.feedbackCategoriesLoaded,
            isLoadingCategories: store.isLoadingFeedbackCategories,
            showsUpgradeNotice: !supported,
            ratingErrorMessage: store.feedbackError(for: target.featureID),
            categoryErrorMessage: store.feedbackCategoriesError,
            saveErrorMessage: store.feedbackSaveError(featureID: target.featureID, messageID: target.messageID),
            hasConflict: store.feedbackConflict(featureID: target.featureID, messageID: target.messageID)
        )
    }
}

/// The compact thumbs-down editor: the three starting reasons, reusable custom
/// reasons with an explicit Add action, and an optional bounded multiline note.
/// Save records a negative rating even with nothing selected. Cancel (or any
/// dismissal) discards the edit and leaves the saved rating unchanged.
struct FirstMateFeedbackEditor: View {
    @Bindable var store: FirstMateStore
    let target: FirstMateFeedbackEditorTarget

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var newCategoryLabel = ""

    private var palette: FirstMatePalette { FirstMatePalette(scheme: scheme) }
    private var editorState: FirstMateFeedbackEditorState { .make(store: store, target: target) }

    var body: some View {
        let state = editorState
        VStack(alignment: .leading, spacing: 16) {
            header
            if !state.isTargetAlive {
                staleNotice
                closeOnly
            } else if state.showsUpgradeNotice {
                upgradeNotice
                closeOnly
            } else {
                reasonsSection(state: state)
                addCategorySection(state: state)
                commentSection(state: state)
                if let error = state.saveErrorMessage {
                    HStack(spacing: 8) {
                        errorLabel(error, identifier: "first-mate-feedback-error")
                        if state.hasConflict {
                            // The pinned draft is kept exactly as submitted;
                            // reloading rebases it to the latest revision so
                            // the deliberate retry cannot silently overwrite.
                            Button("Reload latest") {
                                Task { await store.resolveFeedbackConflict(
                                    messageID: target.messageID,
                                    expectedContext: target.expectedContext
                                ) }
                            }
                            .buttonStyle(.link)
                            .accessibilityIdentifier("first-mate-feedback-reload")
                        }
                    }
                }
                actionBar(state: state)
            }
        }
        .padding(22)
        .frame(width: 480)
        .background(palette.background)
        .accessibilityIdentifier("first-mate-feedback-editor")
        .interactiveDismissDisabled(editorState.isSaving)
        .task {
            await store.loadFeedback(expectedContext: target.expectedContext)
            guard !store.feedbackCategoriesLoaded else { return }
            await store.loadFeedbackCategories(expectedContext: target.expectedContext)
        }
        .onDisappear {
            // Dismissal, Escape, Cancel, and a feature/connection switch all
            // discard only the unsaved edit. A successful save already cleared
            // it, and a failed save keeps the editor open for retry. While a
            // save is in flight the draft is the submitted payload, so it is
            // never discarded out from under the request.
            guard !store.isSavingFeedback(featureID: target.featureID, messageID: target.messageID) else { return }
            store.discardFeedbackDraft(for: target.featureID, messageID: target.messageID)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Response feedback", systemImage: "hand.thumbsdown")
                .herdrFont(.title3, weight: .semibold)
            Text(target.responseText)
                .herdrFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
                .accessibilityIdentifier("first-mate-feedback-context")
        }
    }

    private func reasonsSection(state: FirstMateFeedbackEditorState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Why was this response not helpful?")
                .herdrFont(.subheadline, weight: .semibold)
            Text("Optional. Select any that apply, then add your own if needed.")
                .herdrFont(.caption)
                .foregroundStyle(.secondary)

            if !state.isFeedbackLoaded {
                HStack(spacing: 6) {
                    if state.ratingErrorMessage == nil {
                        ProgressView().controlSize(.small)
                    }
                    Text(state.ratingErrorMessage ?? "Loading the saved rating…")
                        .herdrFont(.caption)
                        .foregroundStyle(.secondary)
                    if state.ratingErrorMessage != nil {
                        Button("Try again") {
                            Task { await store.loadFeedback(expectedContext: target.expectedContext) }
                        }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("first-mate-feedback-load-retry")
                    }
                }
                .accessibilityIdentifier("first-mate-feedback-loading")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(store.feedbackCategories) { category in
                        categoryRow(category)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 190)

            if store.isLoadingFeedbackCategories, store.feedbackCategories.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading reasons…")
                        .herdrFont(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("first-mate-feedback-categories-loading")
            }
            if let error = state.categoryErrorMessage {
                errorLabel(error, identifier: "first-mate-feedback-category-error")
            }
            if !state.isCategoriesLoaded, !state.isLoadingCategories {
                HStack(spacing: 8) {
                    Text("The full reason list has not loaded yet.")
                        .herdrFont(.caption)
                        .foregroundStyle(.secondary)
                    Button("Reload reasons") {
                        Task { await store.loadFeedbackCategories(expectedContext: target.expectedContext) }
                    }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("first-mate-feedback-categories-retry")
                }
            }
        }
    }

    private func categoryRow(_ category: FirstMateFeedbackCategory) -> some View {
        let selected = editorState.draft.categoryIDs.contains(category.id)
        return Button {
            guard editorState.isEditable else { return }
            var updated = editorState.draft
            updated.rating = .down
            updated.categoryIDs = FirstMateFeedbackDraft.togglingCategory(category.id, in: updated.categoryIDs)
            setDraft(updated)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? palette.accent : Color.secondary)
                Text(category.label)
                    .foregroundStyle(palette.text)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!editorState.isEditable)
        .accessibilityIdentifier("first-mate-feedback-category-\(category.id)")
        .accessibilityLabel(category.label)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func addCategorySection(state: FirstMateFeedbackEditorState) -> some View {
        HStack(spacing: 8) {
            TextField("Add a reusable reason", text: $newCategoryLabel)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("first-mate-feedback-add-category-field")
                .disabled(!state.isEditable || state.isAddingCategory)
                .onSubmit { addCategory() }
            Button("Add") { addCategory() }
                .disabled(!canAddCategory(state: state))
                .accessibilityIdentifier("first-mate-feedback-add-category")
            if state.isAddingCategory {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Adding reason")
                    .accessibilityIdentifier("first-mate-feedback-adding-category")
            }
        }
    }

    private func commentSection(state: FirstMateFeedbackEditorState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes")
                .herdrFont(.subheadline, weight: .semibold)
            Text("Optional. Saved exactly as typed, up to \(FirstMateFeedbackCommentLimit.maximumScalars) characters.")
                .herdrFont(.caption)
                .foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                TextEditor(text: commentBinding)
                    .herdrFont(.body)
                    .scrollContentBackground(.hidden)
                    .padding(2)
                    .frame(minHeight: 74, maxHeight: 130)
                    .background(palette.surface, in: .rect(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).stroke(palette.line) }
                    .accessibilityIdentifier("first-mate-feedback-comment")
                    .accessibilityLabel("Personal reason")
                    .disabled(!state.isEditable)
                if state.draft.comment.isEmpty {
                    Text("Add your own reason…")
                        .herdrFont(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            HStack {
                Spacer()
                Text("\(FirstMateFeedbackCommentLimit.count(state.draft.comment)) / \(FirstMateFeedbackCommentLimit.maximumScalars)")
                    .herdrFont(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("first-mate-feedback-comment-count")
            }
        }
    }

    private func actionBar(state: FirstMateFeedbackEditorState) -> some View {
        HStack {
            Spacer()
            Button("Cancel") {
                guard !editorState.isSaving else { return }
                store.discardFeedbackDraft(for: target.featureID, messageID: target.messageID)
                dismiss()
            }
                .keyboardShortcut(.cancelAction)
                .disabled(state.isSaving)
                .accessibilityIdentifier("first-mate-feedback-cancel")
            Button(state.saveErrorMessage == nil ? "Save feedback" : "Retry save") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!state.canSave)
                .accessibilityIdentifier("first-mate-feedback-save")
        }
    }

    private var closeOnly: some View {
        HStack {
            Spacer()
            Button("Close") {
                guard !editorState.isSaving else { return }
                store.discardFeedbackDraft(for: target.featureID, messageID: target.messageID)
                dismiss()
            }
                .keyboardShortcut(.cancelAction)
                .disabled(editorState.isSaving)
                .accessibilityIdentifier("first-mate-feedback-cancel")
        }
    }

    private var staleNotice: some View {
        Label(
            "This response is no longer selected. Reopen its rating from the response.",
            systemImage: "arrow.uturn.backward"
        )
        .herdrFont(.subheadline)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("first-mate-feedback-stale")
    }

    private var upgradeNotice: some View {
        Label(
            "Update this feature's companion server to rate responses.",
            systemImage: "arrow.down.circle"
        )
        .herdrFont(.subheadline)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("first-mate-feedback-editor-upgrade")
    }

    private func errorLabel(_ message: String, identifier: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .herdrFont(.caption)
            .foregroundStyle(.orange)
            .accessibilityIdentifier(identifier)
    }

    private var commentBinding: Binding<String> {
        Binding(
            get: { editorState.draft.comment },
            set: { value in
                // Typing during a pending save must never change the payload
                // that is already in flight or discard it on completion.
                guard editorState.isEditable else { return }
                var updated = editorState.draft
                updated.comment = FirstMateFeedbackCommentLimit.limited(value)
                setDraft(updated)
            }
        )
    }

    private func setDraft(_ draft: FirstMateFeedbackDraft) {
        store.setFeedbackDraft(
            draft,
            for: target.featureID,
            messageID: target.messageID,
            expectedContext: target.expectedContext
        )
    }

    private func canAddCategory(state: FirstMateFeedbackEditorState) -> Bool {
        state.isEditable
            && !state.isAddingCategory
            && !newCategoryLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func addCategory() {
        guard editorState.isEditable else { return }
        let label = newCategoryLabel
        Task {
            guard let category = await store.addFeedbackCategory(
                label: label,
                expectedContext: target.expectedContext
            ) else { return }
            var updated = editorState.draft
            updated.rating = .down
            if !updated.categoryIDs.contains(category.id) {
                updated.categoryIDs.append(category.id)
            }
            setDraft(updated)
            newCategoryLabel = ""
        }
    }

    private func save() {
        guard editorState.canSave else { return }
        var draft = editorState.draft
        draft.rating = .down
        draft.comment = FirstMateFeedbackCommentLimit.limited(draft.comment)
        Task {
            if await store.saveFeedback(
                draft,
                messageID: target.messageID,
                expectedContext: target.expectedContext
            ) {
                dismiss()
            }
        }
    }
}
