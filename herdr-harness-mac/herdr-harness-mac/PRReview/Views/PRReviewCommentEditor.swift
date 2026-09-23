import AppKit
import SwiftUI

/// The multiline local comment editor.
///
/// Save and Cancel are explicit; a dirty Cancel asks before discarding. A
/// failed save keeps the exact draft text and the reason on screen so the
/// reviewer can retry without retyping.
struct PRReviewCommentEditor: View {
    @Bindable var session: PRReviewCommentsSession
    @FocusState private var isBodyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            location
            editor
            if let message = session.saveError {
                errorBanner(message)
            }
            footer
        }
        .padding(20)
        .frame(minWidth: 540, idealWidth: 620, minHeight: 420, alignment: .topLeading)
        .background(HerdrTheme.graphite)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pr-review-comment-editor")
        .onAppear {
            isBodyFocused = true
        }
        .alert(
            "Discard this comment?",
            isPresented: Binding(
                get: { session.isConfirmingDiscard },
                set: { presented in
                    if !presented { session.keepEditing() }
                }
            )
        ) {
            Button("Keep Editing", role: .cancel) { session.keepEditing() }
            Button("Discard", role: .destructive) { session.confirmDiscard() }
                .accessibilityIdentifier("pr-review-comment-confirm-discard")
        } message: {
            Text("The text in this editor has not been saved and will be lost.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(composition?.isNew == false ? "Edit comment" : "Add comment")
                .herdrFont(size: 16, weight: .semibold, relativeTo: .headline)
            Spacer()
            if let reviewLabel = composition?.reviewLabel, !reviewLabel.isEmpty {
                Text(reviewLabel)
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.mist)
                    .lineLimit(1)
            }
        }
    }

    private var location: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(composition?.anchor.path ?? "Selected code", systemImage: "text.line.first.and.arrowtriangle.forward")
                .herdrFont(.subheadline, weight: .medium)
                .lineLimit(2)
                .truncationMode(.head)
                .help(composition?.anchor.path ?? "")
            if let anchor = composition?.anchor {
                HStack(spacing: 10) {
                    Text(PRReviewCommentText.locationLabel(for: anchor))
                    Text(PRReviewCommentText.revisionLabel(for: anchor))
                }
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.mist)
                codeExcerpt(anchor.code)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func codeExcerpt(_ code: String) -> some View {
        Text(code)
            .herdrFont(.caption, monospaced: true)
            .foregroundStyle(HerdrTheme.mist)
            .lineLimit(4)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(HerdrTheme.ink, in: .rect(cornerRadius: 6))
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $session.draftBody)
                .font(.system(.body, design: .default))
                .foregroundStyle(HerdrTheme.text)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(HerdrTheme.ink, in: .rect(cornerRadius: 8))
                .focused($isBodyFocused)
                .accessibilityIdentifier("pr-review-comment-body")
                .accessibilityLabel("Comment")
            if session.draftBody.isEmpty {
                Text("Leave a review comment…")
                    .font(.system(.body, design: .default))
                    .foregroundStyle(HerdrTheme.muted)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 14)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: 160)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Markdown is saved exactly as typed and stays on this Mac.")
                .herdrFont(.caption2)
                .foregroundStyle(HerdrTheme.mist)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button("Cancel") { session.cancelComposition() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("pr-review-comment-cancel")
            Button(session.isSaving ? "Saving…" : "Save") { session.save() }
                .disabled(!session.canSave)
                .accessibilityIdentifier("pr-review-comment-save")
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .herdrFont(.caption)
            .foregroundStyle(HerdrTheme.alert)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HerdrTheme.elevated, in: .rect(cornerRadius: HerdrTheme.compactRadius))
            .accessibilityIdentifier("pr-review-comment-save-error")
    }

    private var composition: PRReviewCommentComposition? { session.composition }
}
