import SwiftUI

struct FirstMateMobileFeedbackRequest: Identifiable {
    let id = UUID()
    let target: FirstMateFeatureTarget
    let store: FirstMateStore
    let context: FirstMateStore.OperationContext
    let messageID: String
    var requestedRating: FirstMateFeedbackRating?

    @MainActor static func capture(_ message: FirstMateMessage, target: FirstMateFeatureTarget,
                                   store: FirstMateStore, fleet: FirstMateMobileFleetStore) -> Self? {
        guard fleet.store(for: target) === store, fleet.selectedTarget == target,
              store.selectedFeatureID == target.featureID, !FirstMateOutgoingMessage.isLocalID(message.id),
              message.featureID == target.featureID, store.canRate(messageID: message.id, featureID: target.featureID) else { return nil }
        return .init(target: target, store: store, context: store.operationContext, messageID: message.id)
    }
    @MainActor func isCurrent(fleet: FirstMateMobileFleetStore) -> Bool {
        fleet.store(for: target) === store && fleet.selectedTarget == target && store.operationContext == context
            && store.lifecycle == context.lifecycleIdentity && !FirstMateOutgoingMessage.isLocalID(messageID)
            && store.canRate(messageID: messageID, featureID: target.featureID)
    }
}

struct FirstMateMobileFeedbackEditor: View {
    let request: FirstMateMobileFeedbackRequest
    @Bindable var fleet: FirstMateMobileFleetStore
    @Environment(\.dismiss) private var dismiss
    @State private var newReason = ""
    @State private var didLoad = false
    @State private var appliedRequestedRating = false
    private var store: FirstMateStore { request.store }
    private var featureID: String { request.target.featureID }
    private var saving: Bool { store.isSavingFeedback(featureID: featureID, messageID: request.messageID) }
    private var current: Bool { request.isCurrent(fleet: fleet) }
    private var writable: Bool { current && store.controlAvailable && store.feedbackSupported && store.hasLoadedFeedback(for: featureID) && !saving }
    private var draft: FirstMateFeedbackDraft { store.feedbackDraft(for: featureID, messageID: request.messageID) }
    private var conflict: Bool { store.feedbackConflict(featureID: featureID, messageID: request.messageID) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Rate this response").herdrFont(.body, weight: .semibold)
                    Text("Feedback is saved with this response on its companion. It does not start an agent turn.")
                        .herdrFont(.footnote).foregroundStyle(HerdrTheme.secondaryText)
                    if !current { Text("The owning conversation changed. Reopen feedback from that response.").foregroundStyle(HerdrTheme.warning) }
                    else if !store.controlAvailable { Text("This conversation is read-only. Your feedback draft stays here.").foregroundStyle(HerdrTheme.warning) }
                    else if store.feedbackCapability == .unsupported { Text("Update this companion server to rate responses.").foregroundStyle(HerdrTheme.warning) }
                    else if !store.feedbackSupported { Text("Connect to this response's host to save feedback.").foregroundStyle(HerdrTheme.warning) }
                    if !didLoad || store.isLoadingFeedback(for: featureID) { ProgressView("Loading saved feedback…") }
                    HStack {
                        ratingButton(.up, title: "Helpful", symbol: "hand.thumbsup")
                        ratingButton(.down, title: "Could be better", symbol: "hand.thumbsdown")
                    }
                    if draft.rating == .down {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Reasons (optional)").herdrFont(.caption).foregroundStyle(HerdrTheme.secondaryText)
                            ForEach(store.feedbackCategories) { category in
                                Button {
                                    var value = draft
                                    if value.categoryIDs.contains(category.id) { value.categoryIDs.removeAll { $0 == category.id } }
                                    else { value.categoryIDs.append(category.id) }
                                    update(value)
                                } label: {
                                    HStack {
                                        Image(systemName: draft.categoryIDs.contains(category.id) ? "checkmark.circle.fill" : "circle")
                                        Text(category.label).fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: 0)
                                    }.frame(minHeight: 44)
                                }.buttonStyle(.plain).disabled(!writable || conflict)
                            }
                            TextField("Add a reason", text: $newReason).textFieldStyle(.roundedBorder).disabled(!writable || conflict)
                            Button("Add reason") {
                                let label = newReason
                                Task {
                                    guard writable, !conflict else { return }
                                    if let category = await store.addFeedbackCategory(label: label, expectedContext: request.context), current {
                                        var value = draft
                                        if !value.categoryIDs.contains(category.id) { value.categoryIDs.append(category.id) }
                                        update(value); newReason = ""
                                    }
                                }
                            }.frame(minHeight: 44).disabled(!writable || conflict || newReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        TextField("Comment (optional)", text: Binding(get: { draft.comment }, set: {
                            var value = draft; value.comment = $0; update(value)
                        }), axis: .vertical).lineLimit(3...8).textFieldStyle(.roundedBorder).disabled(!writable || conflict)
                    }
                    if let error = store.feedbackError(for: featureID) ?? store.feedbackCategoriesError {
                        Text(error).foregroundStyle(HerdrTheme.warning)
                        Button("Reload feedback") { Task { await load() } }.frame(minHeight: 44).disabled(!current || saving)
                    }
                    if let error = store.feedbackSaveError(featureID: featureID, messageID: request.messageID) {
                        Text(error).foregroundStyle(HerdrTheme.warning).fixedSize(horizontal: false, vertical: true)
                    }
                    if conflict {
                        Text("Feedback changed on another client. Reload its revision before deciding to save your retained edit.")
                            .foregroundStyle(HerdrTheme.warning)
                        Button("Reload conflict") {
                            Task { if current { _ = await store.resolveFeedbackConflict(messageID: request.messageID, expectedContext: request.context) } }
                        }.buttonStyle(HerdrButtonStyle(kind: .outline)).disabled(!current || saving)
                    }
                    HStack {
                        Button("Save feedback") { save(draft) }.buttonStyle(HerdrButtonStyle(kind: .primary))
                            .disabled(!writable || conflict)
                        if store.feedback(for: featureID, messageID: request.messageID)?.rating != nil {
                            Button("Clear rating") {
                                var value = draft; value.rating = nil; save(value)
                            }.buttonStyle(HerdrButtonStyle(kind: .outline)).disabled(!writable || conflict)
                        }
                    }
                    if saving { ProgressView("Saving feedback…") }
                }.padding(16).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
            }
            .herdrSheetSurface()
            .navigationTitle("Feedback").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { HerdrSheetCloseButton { dismiss() } } }
        }
        .task { await load() }
        .herdrAppChrome(separateSurface: true)
        .accessibilityIdentifier("first-mate-feedback-sheet")
    }

    private func ratingButton(_ rating: FirstMateFeedbackRating, title: String, symbol: String) -> some View {
        Button {
            var value = draft; value.rating = rating; update(value)
        } label: {
            Label(title, systemImage: symbol + (draft.rating == rating ? ".fill" : ""))
                .fixedSize(horizontal: false, vertical: true)
        }.buttonStyle(HerdrButtonStyle(kind: draft.rating == rating ? .primary : .outline)).disabled(!writable || conflict)
    }
    private func update(_ value: FirstMateFeedbackDraft) {
        guard writable, !conflict else { return }
        store.setFeedbackDraft(value, for: featureID, messageID: request.messageID, expectedContext: request.context)
    }
    private func load() async {
        guard current else { return }
        _ = await store.loadFeedback(expectedContext: request.context)
        guard current else { return }
        _ = await store.loadFeedbackCategories(expectedContext: request.context)
        if current {
            didLoad = true
            if !appliedRequestedRating, writable, !conflict, let rating = request.requestedRating {
                var value = draft; value.rating = rating; update(value); appliedRequestedRating = true
            }
        }
    }
    private func save(_ value: FirstMateFeedbackDraft) {
        guard writable, !conflict else { return }
        // Freeze the edited payload before yielding, including its revision pin.
        Task {
            guard writable, !conflict else { return }
            if await store.saveFeedback(value, messageID: request.messageID, expectedContext: request.context), current { dismiss() }
        }
    }
}
