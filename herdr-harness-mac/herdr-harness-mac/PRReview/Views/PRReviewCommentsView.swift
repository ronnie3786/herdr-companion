import AppKit
import SwiftUI

/// The review-wide list of local comments.
///
/// The list is scoped to the current machine/review pair and remains available
/// from every review tab. Each row keeps the saved excerpt, the exact saved
/// text, and the manual GitHub handoff actions; nothing here posts a comment.
struct PRReviewCommentsView: View {
    @Bindable var session: PRReviewCommentsSession
    var review: PRReviewSummary?
    var currentFilePaths: Set<String>?
    var edit: (PRReviewComment) -> Void = { _ in }
    var showInDiff: (PRReviewComment) -> Void = { _ in }

    @State private var expandedPreviewIDs: Set<UUID> = []

    private static let previewLineLimit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(HerdrTheme.separator).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let message = session.store?.loadError?.errorDescription {
                        banner(message, systemImage: "exclamationmark.triangle", tint: HerdrTheme.alert)
                            .accessibilityIdentifier("pr-review-comments-storage-error")
                    }
                    if let message = session.saveError {
                        banner(message, systemImage: "exclamationmark.triangle", tint: HerdrTheme.alert)
                            .accessibilityIdentifier("pr-review-comments-error")
                    }
                    if let message = session.navigationMessage {
                        banner(message, systemImage: "info.circle", tint: HerdrTheme.working)
                            .accessibilityIdentifier("pr-review-comments-navigation-note")
                    }
                    if session.visibleComments.isEmpty {
                        emptyState
                    } else {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(session.visibleComments) { comment in
                                commentCard(comment)
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(HerdrTheme.separator).frame(height: 1)
            footer
        }
        .frame(minWidth: 540, idealWidth: 640, minHeight: 420)
        .background(HerdrTheme.graphite)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pr-review-comments")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Review comments")
                .herdrFont(size: 16, weight: .semibold, relativeTo: .headline)
            Text("\(session.visibleComments.count)")
                .herdrFont(.caption, monospacedDigit: true)
                .foregroundStyle(HerdrTheme.mist)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(HerdrTheme.elevated, in: .capsule)
            Spacer()
            if let review {
                Text(PRReviewHeaderText.label(for: review))
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.mist)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No saved comments", systemImage: "text.bubble")
        } description: {
            Text("Select code in a diff and choose Add comment. Saved comments stay private to this Mac and are never posted.")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .accessibilityIdentifier("pr-review-comments-empty")
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "lock")
            Text("Saved only on this Mac. Copy a comment, then add it on GitHub yourself; Herdr never posts or marks it published.")
                .herdrFont(.caption2)
                .foregroundStyle(HerdrTheme.mist)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button("Done") { session.dismissCommentsSheet() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("pr-review-comments-done")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func commentCard(_ comment: PRReviewComment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(comment.anchor.path)
                    .herdrFont(.subheadline, weight: .semibold)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .help(comment.anchor.path)
                Spacer(minLength: 8)
                statusBadge(comment)
            }
            Text(PRReviewCommentText.locationLabel(for: comment.anchor))
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.mist)
            codePreview(comment)
            Text(comment.body)
                .herdrFont(.callout)
                .foregroundStyle(HerdrTheme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("pr-review-comment-body-\(comment.id.uuidString)")
            actions(comment)
        }
        .padding(12)
        .background(HerdrTheme.elevated, in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pr-review-comment-\(comment.id.uuidString)")
    }

    @ViewBuilder
    private func statusBadge(_ comment: PRReviewComment) -> some View {
        switch session.locationStatus(for: comment, review: review, currentFilePaths: currentFilePaths) {
        case .current:
            EmptyView()
        case .earlierRevision:
            Label("Earlier revision", systemImage: "clock")
                .herdrFont(.caption2)
                .foregroundStyle(HerdrTheme.working)
        case .missingFromCurrentRevision:
            Label("Not in current revision", systemImage: "exclamationmark.triangle")
                .herdrFont(.caption2)
                .foregroundStyle(HerdrTheme.working)
        }
    }

    private func codePreview(_ comment: PRReviewComment) -> some View {
        let expanded = expandedPreviewIDs.contains(comment.id)
        let lineCount = comment.anchor.code.split(separator: "\n", omittingEmptySubsequences: false).count
        return VStack(alignment: .leading, spacing: 4) {
            Text(comment.anchor.code)
                .herdrFont(.caption, monospaced: true)
                .foregroundStyle(HerdrTheme.mist)
                .lineLimit(expanded ? nil : Self.previewLineLimit)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("pr-review-comment-preview-\(comment.id.uuidString)")
            if lineCount > Self.previewLineLimit {
                Button(expanded ? "Show less" : "Show full selection") {
                    if expanded {
                        expandedPreviewIDs.remove(comment.id)
                    } else {
                        expandedPreviewIDs.insert(comment.id)
                    }
                }
                .buttonStyle(.plain)
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.accent)
                .accessibilityIdentifier("pr-review-comment-expand-\(comment.id.uuidString)")
            }
            if session.locationStatus(for: comment, review: review, currentFilePaths: currentFilePaths) != .current {
                Text("\(PRReviewCommentText.revisionLabel(for: comment.anchor)). The current PR may have moved or removed this location.")
                    .herdrFont(.caption2)
                    .foregroundStyle(HerdrTheme.working)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(HerdrTheme.ink, in: .rect(cornerRadius: 6))
    }

    private func actions(_ comment: PRReviewComment) -> some View {
        HStack(spacing: 8) {
            Button("Show in diff") { showInDiff(comment) }
                .accessibilityIdentifier("pr-review-comment-show-in-diff-\(comment.id.uuidString)")
            Button("Edit") { edit(comment) }
                .accessibilityIdentifier("pr-review-comment-edit-\(comment.id.uuidString)")
            Spacer(minLength: 8)
            Button {
                session.copy(comment)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy comment")
            .accessibilityLabel("Copy comment")
            .accessibilityIdentifier("pr-review-comment-copy-\(comment.id.uuidString)")
            Button {
                session.openFileInGitHub(comment)
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .help("Open file in GitHub")
            .accessibilityLabel("Open file in GitHub")
            .accessibilityIdentifier("pr-review-comment-open-github-\(comment.id.uuidString)")
            if comment.anchor.spans.first.flatMap({
                PRReviewCommentLinks.originalRevisionBlobURL(for: comment, side: $0.side, span: $0)
            }) != nil {
                Button {
                    session.openOriginalRevision(comment, span: comment.anchor.spans.first)
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .help("Open original revision")
                .accessibilityLabel("Open original revision")
                .accessibilityIdentifier("pr-review-comment-open-original-\(comment.id.uuidString)")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func banner(_ message: String, systemImage: String, tint: Color) -> some View {
        Label(message, systemImage: systemImage)
            .herdrFont(.caption)
            .foregroundStyle(tint)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HerdrTheme.elevated, in: .rect(cornerRadius: HerdrTheme.compactRadius))
    }
}
