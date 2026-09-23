import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("First Mate response feedback presentation")
@MainActor
struct FirstMateFeedbackPresentationTests {
    @Test("Eligibility, capability, and saved state decide the footer without quote limits")
    func footerPresentation() throws {
        let eligible = syntheticMessage(id: "eligible", role: "assistant", status: "done", text: "A completed answer")

        // A reachable companion without the capability and no cached record
        // hides the per-response footer; the one upgrade notice covers it.
        #expect(FirstMateResponseFeedbackPresentation.make(
            message: eligible,
            supported: false,
            writable: true,
            isSaving: false,
            record: nil
        ) == nil)

        let unrated = try #require(FirstMateResponseFeedbackPresentation.make(
            message: eligible,
            supported: true,
            writable: true,
            isSaving: false,
            record: nil
        ))
        #expect(unrated.rating == nil)
        #expect(unrated.statusText == nil)
        #expect(!unrated.hasSavedRating)
        #expect(!unrated.isSelectedUp)
        #expect(!unrated.isSelectedDown)

        let savedRecord = syntheticRecord(
            rating: .down,
            categoryIDs: ["too_long", "unnecessary_message"],
            comment: "Synthetic note"
        )
        let saved = try #require(FirstMateResponseFeedbackPresentation.make(
            message: eligible,
            supported: true,
            writable: false,
            isSaving: true,
            record: savedRecord
        ))
        #expect(saved.statusText == "Not helpful · 2 reasons, note")
        #expect(saved.isSelectedDown)
        #expect(!saved.isWritable)
        #expect(saved.isSaving)

        // A cached saved rating stays readable when the companion connection
        // is offline, but writes are unavailable until capability returns.
        let offline = try #require(FirstMateResponseFeedbackPresentation.make(
            message: eligible,
            supported: false,
            writable: true,
            isSaving: false,
            record: savedRecord
        ))
        #expect(offline.rating == .down)
        #expect(!offline.isWritable)
        #expect(FirstMateResponseFeedbackPresentation.make(
            message: eligible,
            supported: false,
            writable: true,
            isSaving: false,
            record: syntheticRecord(rating: nil, categoryIDs: [], comment: "Cleared", revision: 3)
        ) == nil)

        // Older completed responses remain rateable; the quote window and
        // workflow closure deliberately do not apply.
        let history = (0..<6).map { index in
            syntheticMessage(id: "response-\(index)", role: "assistant", status: "done", text: "Answer \(index)")
        }
        #expect(!FirstMateQuoteEligibility.messageIDs(in: history).contains("response-0"))
        #expect(FirstMateResponseFeedbackPresentation.make(
            message: history[0],
            supported: true,
            writable: true,
            isSaving: false,
            record: nil
        ) != nil)
        var closed = history[0]
        closed.status = "complete"
        #expect(FirstMateResponseFeedbackPresentation.make(
            message: closed,
            supported: true,
            writable: true,
            isSaving: false,
            record: nil
        ) != nil)

        // Human, queued, pending, system, and blank responses never show it.
        for ineligible in [
            syntheticMessage(id: "human", role: "human", status: "done", text: "Direction"),
            syntheticMessage(id: "user", role: "user", status: "done", text: "Direction"),
            syntheticMessage(id: "queued", role: "assistant", status: "queued", text: "Pending"),
            syntheticMessage(id: "pending", role: "assistant", status: "pending", text: "Pending"),
            syntheticMessage(id: "system", role: "system", status: "done", text: "Notice"),
            syntheticMessage(id: "empty", role: "assistant", status: "done", text: " \n\t "),
        ] {
            #expect(FirstMateResponseFeedbackPresentation.make(
                message: ineligible,
                supported: true,
                writable: true,
                isSaving: false,
                record: nil
            ) == nil)
        }
    }

    @Test("Saved status wording never relies on tint alone")
    func statusWording() throws {
        func status(
            rating: FirstMateFeedbackRating?,
            categories: [String],
            comment: String
        ) throws -> String? {
            let record = syntheticRecord(rating: rating, categoryIDs: categories, comment: comment)
            let presentation = try #require(FirstMateResponseFeedbackPresentation.make(
                message: syntheticMessage(id: "wording", role: "assistant", status: "done", text: "Answer"),
                supported: true,
                writable: true,
                isSaving: false,
                record: record
            ))
            return presentation.statusText
        }

        let up = try status(rating: .up, categories: [], comment: "")
        let oneReason = try status(rating: .down, categories: ["one"], comment: "")
        let threeReasons = try status(rating: .down, categories: ["one", "two", "three"], comment: "")
        let noteOnly = try status(rating: .down, categories: [], comment: "Note")
        let blankNote = try status(rating: .down, categories: [], comment: " \n ")
        let combined = try status(rating: .down, categories: ["one"], comment: "Note")
        let cleared = try status(rating: nil, categories: [], comment: "")
        #expect(up == "Helpful")
        #expect(oneReason == "Not helpful · 1 reason")
        #expect(threeReasons == "Not helpful · 3 reasons")
        #expect(noteOnly == "Not helpful · note")
        #expect(blankNote == "Not helpful")
        #expect(combined == "Not helpful · 1 reason, note")
        #expect(cleared == nil)
    }

    @Test("The comment stays verbatim Unicode within the documented scalar limit")
    func commentLimit() {
        let verbatim = "Line one\nLine two — synthetic ✓\n\nLine four"
        #expect(FirstMateFeedbackCommentLimit.limited(verbatim) == verbatim)
        #expect(FirstMateFeedbackCommentLimit.count(verbatim) == verbatim.unicodeScalars.count)

        let exact = String(repeating: "a", count: FirstMateFeedbackCommentLimit.maximumScalars)
        #expect(FirstMateFeedbackCommentLimit.limited(exact) == exact)
        #expect(FirstMateFeedbackCommentLimit.limited(exact + "tail") == exact)

        // Two scalars per flag: truncation stops at whole characters.
        let flags = String(repeating: "🇺🇸", count: 2001)
        let limited = FirstMateFeedbackCommentLimit.limited(flags)
        #expect(limited.unicodeScalars.count == FirstMateFeedbackCommentLimit.maximumScalars)
        #expect(limited.hasSuffix("🇺🇸"))
    }

    @Test("Category selection toggles independently and preserves pick order")
    func categoryToggle() {
        var selected: [String] = []
        selected = FirstMateFeedbackDraft.togglingCategory("too_long", in: selected)
        selected = FirstMateFeedbackDraft.togglingCategory("unnecessary_message", in: selected)
        #expect(selected == ["too_long", "unnecessary_message"])
        selected = FirstMateFeedbackDraft.togglingCategory("too_long", in: selected)
        #expect(selected == ["unnecessary_message"])
        selected = FirstMateFeedbackDraft.togglingCategory("too_long", in: selected)
        #expect(selected == ["unnecessary_message", "too_long"])

        var draft = FirstMateFeedbackDraft(rating: .down)
        draft.categoryIDs = selected
        #expect(draft.forRequest.categoryIDs == ["unnecessary_message", "too_long"])
        #expect(draft.forRequest.rating == .down)
    }

    @Test("Editor state stays pinned to the feature lifecycle and disables unwritable saves")
    func editorState() async throws {
        let store = FirstMateStore()
        store.configure(client: nil, demo: true)
        let lease = store.acquireControlLease(available: true)
        let featureID = try #require(store.selectedFeatureID)
        let context = store.operationContext
        let target = FirstMateFeedbackEditorTarget(
            featureID: featureID,
            messageID: "demo-mate-0",
            responseText: "Synthetic answer",
            expectedContext: context
        )

        var state = FirstMateFeedbackEditorState.make(store: store, target: target)
        #expect(state.isTargetAlive)
        #expect(state.isWritable)
        #expect(state.canSave)
        #expect(!state.showsUpgradeNotice)
        #expect(state.draft.rating == .down)
        #expect(state.draft.categoryIDs.isEmpty)
        #expect(state.draft.comment.isEmpty)
        #expect(state.saveErrorMessage == nil)

        // A saved negative record prefills its reasons and verbatim note.
        #expect(await store.saveFeedback(
            FirstMateFeedbackDraft(
                rating: .down,
                categoryIDs: [FirstMateFeedbackDefaults.tooLongID],
                comment: "Line one\nLine two"
            ),
            messageID: "demo-mate-0",
            expectedContext: context
        ))
        state = .make(store: store, target: target)
        #expect(state.draft.categoryIDs == [FirstMateFeedbackDefaults.tooLongID])
        #expect(state.draft.comment == "Line one\nLine two")

        // A positive rating starts a fresh negative draft on reopen.
        #expect(await store.rateFeedback(.up, messageID: "demo-mate-0", expectedContext: context))
        #expect(store.feedbackDraft(for: featureID, messageID: "demo-mate-0").rating == .up)
        if store.feedback(for: featureID, messageID: "demo-mate-0")?.rating != .down {
            store.setFeedbackDraft(
                FirstMateFeedbackDraft(rating: .down),
                for: featureID,
                messageID: "demo-mate-0",
                expectedContext: context
            )
        }
        state = .make(store: store, target: target)
        #expect(state.draft.rating == .down)
        #expect(state.draft.categoryIDs.isEmpty)

        // Releasing control keeps the saved rating readable but blocks a save.
        store.releaseControlLease(lease)
        state = .make(store: store, target: target)
        #expect(state.isTargetAlive)
        #expect(!state.isWritable)
        #expect(!state.canSave)
        #expect(store.feedback(for: featureID, messageID: "demo-mate-0")?.rating == .up)

        // Selecting another feature invalidates the captured target.
        let otherID = try #require(store.features.first { $0.id != featureID }?.id)
        store.select(otherID)
        state = .make(store: store, target: target)
        #expect(!state.isTargetAlive)
        #expect(!state.canSave)

        // Reconfiguring to a lifecycle without the capability keeps one
        // upgrade path and never offers a write.
        store.configure(client: nil, demo: false)
        state = .make(store: store, target: target)
        #expect(state.showsUpgradeNotice)
        #expect(!state.canSave)
    }

    @Test("The upgrade notice appears once for a reachable old companion only")
    func upgradeNotice() {
        #expect(FirstMateFeedbackSurface.showsUpgradeNotice(hasLoaded: true, unsupported: false, supported: false))
        #expect(!FirstMateFeedbackSurface.showsUpgradeNotice(hasLoaded: false, unsupported: false, supported: false))
        #expect(!FirstMateFeedbackSurface.showsUpgradeNotice(hasLoaded: true, unsupported: true, supported: false))
        #expect(!FirstMateFeedbackSurface.showsUpgradeNotice(hasLoaded: true, unsupported: false, supported: true))
        #expect(!FirstMateFeedbackSurface.showsUpgradeNotice(hasLoaded: true, unsupported: true, supported: true))
    }

    @Test("A failed rating save keeps the previous state and offers an explicit retry")
    func failedSaveRetry() async throws {
        let message = syntheticMessage(id: "failed-save", role: "assistant", status: "done", text: "Answer")
        let saved = syntheticRecord(rating: .down, categoryIDs: ["too_long"], comment: "Note")
        let failed = try #require(FirstMateResponseFeedbackPresentation.make(
            message: message,
            supported: true,
            writable: true,
            isSaving: false,
            record: saved,
            saveErrorMessage: "Connect to this feature's host to save feedback."
        ))
        #expect(failed.rating == .down)
        #expect(failed.hasSavedRating)
        #expect(failed.isWritable)
        #expect(failed.saveErrorMessage == "Connect to this feature's host to save feedback.")

        // The next successful render clears the compact error row.
        let recovered = try #require(FirstMateResponseFeedbackPresentation.make(
            message: message,
            supported: true,
            writable: true,
            isSaving: false,
            record: saved
        ))
        #expect(recovered.saveErrorMessage == nil)

        // The error row only appears when a failure is reported.
        for scheme in [ColorScheme.light, .dark] {
            let withError = NSHostingView(
                rootView: FirstMateResponseFeedbackFooter(messageID: message.id, presentation: failed)
                    .environment(\.colorScheme, scheme)
                    .environment(\.herdrFontScale, .xxxLarge)
                    .frame(width: 420)
            )
            let withoutError = NSHostingView(
                rootView: FirstMateResponseFeedbackFooter(messageID: message.id, presentation: recovered)
                    .environment(\.colorScheme, scheme)
                    .environment(\.herdrFontScale, .xxxLarge)
                    .frame(width: 420)
            )
            withError.layoutSubtreeIfNeeded()
            withoutError.layoutSubtreeIfNeeded()
            #expect(withError.fittingSize.height > withoutError.fittingSize.height)
        }

        // A real store failure keeps the attempted draft for retry and never
        // invents a saved rating over the previous state.
        let store = FirstMateStore()
        store.configure(client: nil, demo: false)
        _ = store.acquireControlLease(available: true)
        store.selectedFeatureID = "synthetic-feature"
        let context = store.operationContext
        let attempted = FirstMateFeedbackDraft(rating: .up)
        #expect(!(await store.saveFeedback(attempted, messageID: message.id, expectedContext: context)))
        #expect(store.feedbackSaveError(featureID: "synthetic-feature", messageID: message.id) != nil)
        var pinnedAttempt = attempted
        pinnedAttempt.baseRevision = 0
        #expect(store.feedbackDraft(for: "synthetic-feature", messageID: message.id) == pinnedAttempt)
        #expect(store.feedback(for: "synthetic-feature", messageID: message.id) == nil)
    }

    @Test("The footer defers writes until the record loads and shows conflict recovery")
    func loadReadinessAndConflictPresentation() throws {
        let message = syntheticMessage(id: "conflict", role: "assistant", status: "done", text: "Answer")
        let saved = syntheticRecord(rating: .down, categoryIDs: ["too_long"], comment: "Note")

        // A delayed read keeps the cached rating visible but disables writes,
        // so an early click can never overwrite a record that has not loaded.
        let beforeLoad = try #require(FirstMateResponseFeedbackPresentation.make(
            message: message,
            supported: true,
            writable: true,
            isSaving: false,
            record: saved,
            isFeedbackLoaded: false
        ))
        #expect(!beforeLoad.isWritable)
        #expect(beforeLoad.rating == .down)
        #expect(beforeLoad.statusText == "Not helpful · 1 reason, note")

        let conflict = try #require(FirstMateResponseFeedbackPresentation.make(
            message: message,
            supported: true,
            writable: true,
            isSaving: false,
            record: saved,
            saveErrorMessage: "Feedback changed. Reload it before saving.",
            hasConflict: true
        ))
        #expect(conflict.hasConflict)
        #expect(conflict.isWritable)
        #expect(conflict.hasSavedRating)
        #expect(conflict.saveErrorMessage != nil)

        for scheme in [ColorScheme.light, .dark] {
            let view = NSHostingView(
                rootView: FirstMateResponseFeedbackFooter(messageID: message.id, presentation: conflict)
                    .environment(\.colorScheme, scheme)
                    .environment(\.herdrFontScale, .xxxLarge)
                    .frame(width: 420)
            )
            view.layoutSubtreeIfNeeded()
            #expect(view.fittingSize.height > 10)
        }
    }

    @Test("Editor state freezes saving while loading, saving, or conflicted")
    func editorStateGating() {
        func state(
            loaded: Bool = true,
            saving: Bool = false,
            conflict: Bool = false,
            categorySaving: Bool = false
        ) -> FirstMateFeedbackEditorState {
            FirstMateFeedbackEditorState(
                draft: FirstMateFeedbackDraft(),
                isTargetAlive: true,
                isWritable: true,
                isFeedbackLoaded: loaded,
                isSaving: saving,
                isAddingCategory: categorySaving,
                isCategoriesLoaded: true,
                isLoadingCategories: false,
                showsUpgradeNotice: false,
                ratingErrorMessage: nil,
                categoryErrorMessage: nil,
                saveErrorMessage: nil,
                hasConflict: conflict
            )
        }

        #expect(state().canSave)
        #expect(!state(loaded: false).canSave)
        #expect(!state(loaded: false).isEditable)
        #expect(!state(saving: true).isEditable)
        #expect(!state(saving: true).canSave)
        #expect(!state(conflict: true).canSave)
        #expect(state(conflict: true).hasConflict)
        #expect(!state(categorySaving: true).canSave)
        #expect(!state().isLoadingCategories)
        #expect(state().isCategoriesLoaded)
    }

    @Test("The footer, message row, and pinned editor host in both appearances at the largest text size")
    func rendering() throws {
        let message = syntheticMessage(id: "render", role: "assistant", status: "done", text: "A **completed** synthetic answer.")
        let presentation = try #require(FirstMateResponseFeedbackPresentation.make(
            message: message,
            supported: true,
            writable: true,
            isSaving: false,
            record: syntheticRecord(
                rating: .down,
                categoryIDs: ["too_long", "incorrect_assumption"],
                comment: "Synthetic note"
            )
        ))

        for scheme in [ColorScheme.light, .dark] {
            let footer = NSHostingView(
                rootView: FirstMateResponseFeedbackFooter(messageID: message.id, presentation: presentation)
                    .environment(\.colorScheme, scheme)
                    .environment(\.herdrFontScale, .xxxLarge)
                    .frame(width: 420)
            )
            footer.layoutSubtreeIfNeeded()
            #expect(footer.fittingSize.width > 0)
            #expect(footer.fittingSize.height > 10)
        }

        let withFooter = NSHostingView(rootView: FirstMateMessageView(message: message, feedback: presentation).frame(width: 420))
        let withoutFooter = NSHostingView(rootView: FirstMateMessageView(message: message).frame(width: 420))
        withFooter.layoutSubtreeIfNeeded()
        withoutFooter.layoutSubtreeIfNeeded()
        #expect(withFooter.fittingSize.height > withoutFooter.fittingSize.height)

        let store = FirstMateStore()
        store.configure(client: nil, demo: true)
        let featureID = try #require(store.selectedFeatureID)
        let target = FirstMateFeedbackEditorTarget(
            featureID: featureID,
            messageID: "demo-mate-0",
            responseText: "Synthetic response with a **markdown** shape.",
            expectedContext: store.operationContext
        )
        for scheme in [ColorScheme.light, .dark] {
            let editor = NSHostingView(
                rootView: FirstMateFeedbackEditor(store: store, target: target)
                    .environment(\.colorScheme, scheme)
                    .environment(\.herdrFontScale, .xxxLarge)
                    .frame(width: 480)
            )
            editor.layoutSubtreeIfNeeded()
            #expect(editor.fittingSize.height > 200)
        }
    }
}

private func syntheticMessage(
    id: String,
    role: String,
    status: String,
    text: String
) -> FirstMateMessage {
    FirstMateMessage(
        id: id,
        featureID: "synthetic-feature",
        role: role,
        text: text,
        status: status,
        createdAt: "2030-01-01T00:00:00Z"
    )
}

private func syntheticRecord(
    rating: FirstMateFeedbackRating?,
    categoryIDs: [String],
    comment: String,
    revision: Int = 1
) -> FirstMateFeedback {
    FirstMateFeedback(
        messageID: "synthetic-message",
        featureID: "synthetic-feature",
        rating: rating,
        categoryIDs: categoryIDs,
        comment: comment,
        revision: revision,
        createdAt: "2030-01-01T00:00:00Z",
        updatedAt: "2030-01-01T00:00:00Z",
        provenance: FirstMateFeedbackProvenance(
            responseText: "A completed answer",
            responseCreatedAt: "2030-01-01T00:00:00Z",
            sourceKind: "reply",
            inReplyTo: nil,
            visitID: nil,
            featureRevision: 1,
            coordinatorSessionID: "synthetic-coordinator",
            sessionProvenance: "verified"
        )
    )
}
