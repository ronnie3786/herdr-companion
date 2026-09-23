import SwiftUI

/// The documented comment bound. The companion rejects payloads above 4000
/// Unicode scalars, so the editor clamps input at the same boundary and shows
/// the remaining count. Scalars, not UTF-16 offsets, so emoji are never split.
enum FirstMateFeedbackCommentLimit {
    static let maximumScalars = 4000

    static func limited(_ comment: String) -> String {
        guard comment.unicodeScalars.count > maximumScalars else { return comment }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: comment.unicodeScalars.prefix(maximumScalars))
        return String(scalars)
    }

    static func count(_ comment: String) -> Int {
        comment.unicodeScalars.count
    }
}

/// Whether the chat should show the single companion-upgrade notice. A missing
/// First Mate surface and a server that does not host First Mate at all have
/// their own explanations, so this stays quiet for them. Only a confirmed
/// capability response without feedback support qualifies; a failed or
/// unanswered capability check is temporary unavailability and must not claim
/// the companion is old.
enum FirstMateFeedbackSurface {
    static func showsUpgradeNotice(
        hasLoaded: Bool,
        capability: FirstMateFeedbackCapability,
        surfaceUnsupported: Bool
    ) -> Bool {
        hasLoaded && !surfaceUnsupported && capability == .unsupported
    }
}

/// One response footer's complete display state. `make` is the single place
/// that combines response eligibility, capability, control availability, load
/// readiness, in-flight state, conflict state, and the saved record, so the
/// footer cannot accidentally inherit the quote window or depend on workflow
/// closure.
struct FirstMateResponseFeedbackPresentation: Equatable {
    var rating: FirstMateFeedbackRating?
    var isSaving: Bool
    var isWritable: Bool
    var savedReasonCount: Int
    var hasSavedComment: Bool
    var saveErrorMessage: String?
    var hasConflict: Bool

    /// Nil hides the footer entirely. A cached record with a saved rating keeps
    /// its footer visible read-only when the companion connection is offline;
    /// a reachable companion without `first-mate-feedback-v1` never produced
    /// one, so it falls through to the single upgrade notice. Ratings stay
    /// disabled until the first full record load, so a delayed read can never
    /// be silently overwritten by an early click.
    static func make(
        message: FirstMateMessage,
        supported: Bool,
        writable: Bool,
        isSaving: Bool,
        record: FirstMateFeedback?,
        saveErrorMessage: String? = nil,
        hasConflict: Bool = false,
        isFeedbackLoaded: Bool = true
    ) -> FirstMateResponseFeedbackPresentation? {
        guard FirstMateFeedbackEligibility.isEligible(message) else { return nil }
        guard supported || record?.rating != nil else { return nil }
        return FirstMateResponseFeedbackPresentation(
            rating: record?.rating,
            isSaving: isSaving,
            isWritable: supported && writable && isFeedbackLoaded,
            savedReasonCount: record?.categoryIDs.count ?? 0,
            hasSavedComment: !(record?.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
            saveErrorMessage: saveErrorMessage,
            hasConflict: hasConflict
        )
    }

    var isSelectedUp: Bool { rating == .up }
    var isSelectedDown: Bool { rating == .down }
    var hasSavedRating: Bool { rating != nil }

    /// Explicit saved-state wording so a selected rating never relies on tint
    /// alone, and so VoiceOver and UI tests can read it back.
    var statusText: String? {
        switch rating {
        case .up:
            return "Helpful"
        case .down:
            var details: [String] = []
            if savedReasonCount == 1 {
                details.append("1 reason")
            } else if savedReasonCount > 1 {
                details.append("\(savedReasonCount) reasons")
            }
            if hasSavedComment { details.append("note") }
            return details.isEmpty ? "Not helpful" : "Not helpful · " + details.joined(separator: ", ")
        case nil:
            return nil
        }
    }
}

/// The compact footer under one completed assistant response. Thumbs up saves
/// immediately through the caller; thumbs down and Edit open the pinned
/// feedback editor; Remove rating clears the active label only after the
/// caller's save succeeds.
struct FirstMateResponseFeedbackFooter: View {
    let messageID: String
    let presentation: FirstMateResponseFeedbackPresentation
    var onRateUp: @MainActor () -> Void = {}
    var onEditFeedback: @MainActor () -> Void = {}
    var onRemoveRating: @MainActor () -> Void = {}
    var onRetry: @MainActor () -> Void = {}
    var onResolveConflict: @MainActor () -> Void = {}

    @Environment(\.colorScheme) private var scheme

    private var palette: FirstMatePalette { FirstMatePalette(scheme: scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(presentation.statusText ?? "Rate this response")
                    .herdrFont(.caption)
                    .foregroundStyle(presentation.statusText == nil ? Color.secondary.opacity(0.65) : Color.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("first-mate-feedback-status-\(messageID)")

                Spacer(minLength: 6)

                if presentation.isSaving {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityIdentifier("first-mate-feedback-saving-\(messageID)")
                        .accessibilityLabel("Saving rating")
                }

                thumb(up: true)
                thumb(up: false)

                if presentation.isSelectedDown {
                    Button("Edit", action: onEditFeedback)
                        .buttonStyle(.borderless)
                        .herdrFont(.caption)
                        .foregroundStyle(palette.accent)
                        .disabled(!presentation.isWritable || presentation.isSaving)
                        .accessibilityIdentifier("first-mate-feedback-edit-\(messageID)")
                        .accessibilityLabel("Edit response feedback")
                        .help("Edit response feedback")
                }

                if presentation.hasSavedRating {
                    Button("Remove rating", action: onRemoveRating)
                        .buttonStyle(.borderless)
                        .herdrFont(.caption)
                        .foregroundStyle(palette.secondaryText)
                        .disabled(!presentation.isWritable || presentation.isSaving)
                        .accessibilityIdentifier("first-mate-feedback-remove-\(messageID)")
                        .accessibilityLabel("Remove rating")
                        .help("Remove this response's rating")
                }
            }

            if let saveErrorMessage = presentation.saveErrorMessage {
                HStack(spacing: 6) {
                    Label(saveErrorMessage, systemImage: "exclamationmark.triangle")
                        .herdrFont(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .accessibilityIdentifier("first-mate-feedback-error-\(messageID)")
                    if presentation.hasConflict {
                        // The attempted up/clear payload stays in the store; the
                        // explicit action reloads the latest revision and then
                        // retries it with a fresh request identity.
                        Button("Reload and retry", action: onResolveConflict)
                            .buttonStyle(.link)
                            .herdrFont(.caption)
                            .disabled(!presentation.isWritable || presentation.isSaving)
                            .accessibilityIdentifier("first-mate-feedback-conflict-\(messageID)")
                            .accessibilityLabel("Reload the latest rating and retry")
                            .help("Reload the latest rating and retry")
                    } else {
                        Button("Try again", action: onRetry)
                            .buttonStyle(.link)
                            .herdrFont(.caption)
                            .disabled(!presentation.isWritable || presentation.isSaving)
                            .accessibilityIdentifier("first-mate-feedback-retry-\(messageID)")
                            .accessibilityLabel("Retry saving this rating")
                            .help("Retry saving this rating")
                    }
                }
            }
        }
        .padding(.top, 2)
        .accessibilityIdentifier("first-mate-feedback-\(messageID)")
    }

    private func thumb(up: Bool) -> some View {
        let selected = up ? presentation.isSelectedUp : presentation.isSelectedDown
        let title = up ? "Helpful response" : "Not helpful response"
        return Button {
            if up { onRateUp() } else { onEditFeedback() }
        } label: {
            Image(systemName: up
                ? (selected ? "hand.thumbsup.fill" : "hand.thumbsup")
                : (selected ? "hand.thumbsdown.fill" : "hand.thumbsdown"))
                .frame(width: 18, height: 18)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(selected ? palette.accent : palette.secondaryText)
        .disabled(!presentation.isWritable || presentation.isSaving || (up && selected))
        .accessibilityIdentifier("first-mate-feedback-\(up ? "up" : "down")-\(messageID)")
        .accessibilityLabel(selected ? "\(title), selected" : title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(selected ? "\(title) — selected" : title)
    }
}
