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
    /// The reply's text, for the copy control that sits beside the thumbs.
    var copyText: String? = nil
    var onRateUp: @MainActor () -> Void = {}
    var onEditFeedback: @MainActor () -> Void = {}
    var onRemoveRating: @MainActor () -> Void = {}
    var onRetry: @MainActor () -> Void = {}
    var onResolveConflict: @MainActor () -> Void = {}

    @Environment(\.colorScheme) private var scheme

    private var palette: FirstMatePalette { FirstMatePalette(scheme: scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // MonoCode's `.fm-fb`: thumbs and copy first, then the rating state.
            HStack(spacing: 2) {
                thumb(up: true)
                thumb(up: false)
                if let copyText {
                    PiCopyButton(text: copyText, label: "Copy response", accessibilityIdentifier: "first-mate-copy-\(messageID)")
                }

                Text(presentation.statusText ?? "Rate this response")
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(palette.tertiaryText)
                    .lineLimit(1)
                    .padding(.leading, 6)
                    .accessibilityIdentifier("first-mate-feedback-status-\(messageID)")

                if presentation.isSaving {
                    ProgressView()
                        .controlSize(.mini)
                        .padding(.leading, 4)
                        .accessibilityIdentifier("first-mate-feedback-saving-\(messageID)")
                        .accessibilityLabel("Saving rating")
                }

                if presentation.isSelectedDown {
                    Button("Edit", action: onEditFeedback)
                        .buttonStyle(.herdrPlain)
                        .herdrFont(size: HerdrTheme.TextSize.caption, weight: .medium)
                        .foregroundStyle(palette.accent)
                        .frame(minHeight: HerdrTheme.minHitTarget)
                        .contentShape(.rect)
                        .padding(.leading, 8)
                        .disabled(!presentation.isWritable || presentation.isSaving)
                        .accessibilityIdentifier("first-mate-feedback-edit-\(messageID)")
                        .accessibilityLabel("Edit response feedback")
                        .help("Edit response feedback")
                }

                if presentation.hasSavedRating {
                    Button("Remove rating", action: onRemoveRating)
                        .buttonStyle(.herdrPlain)
                        .herdrFont(size: HerdrTheme.TextSize.caption, weight: .medium)
                        .foregroundStyle(palette.secondaryText)
                        .frame(minHeight: HerdrTheme.minHitTarget)
                        .contentShape(.rect)
                        .padding(.leading, 8)
                        .disabled(!presentation.isWritable || presentation.isSaving)
                        .accessibilityIdentifier("first-mate-feedback-remove-\(messageID)")
                        .accessibilityLabel("Remove rating")
                        .help("Remove this response's rating")
                }

                Spacer(minLength: 0)
            }

            if let saveErrorMessage = presentation.saveErrorMessage {
                HStack(spacing: 6) {
                    Label(saveErrorMessage, systemImage: "exclamationmark.triangle")
                        .herdrFont(size: HerdrTheme.TextSize.caption)
                        .foregroundStyle(HerdrTheme.warning)
                        .lineLimit(2)
                        .accessibilityIdentifier("first-mate-feedback-error-\(messageID)")
                    if presentation.hasConflict {
                        // The attempted up/clear payload stays in the store; the
                        // explicit action reloads the latest revision and then
                        // retries it with a fresh request identity.
                        Button("Reload and retry", action: onResolveConflict)
                            .buttonStyle(.link)
                            .herdrFont(size: HerdrTheme.TextSize.caption)
                            .disabled(!presentation.isWritable || presentation.isSaving)
                            .accessibilityIdentifier("first-mate-feedback-conflict-\(messageID)")
                            .accessibilityLabel("Reload the latest rating and retry")
                            .help("Reload the latest rating and retry")
                    } else {
                        Button("Try again", action: onRetry)
                            .buttonStyle(.link)
                            .herdrFont(size: HerdrTheme.TextSize.caption)
                            .disabled(!presentation.isWritable || presentation.isSaving)
                            .accessibilityIdentifier("first-mate-feedback-retry-\(messageID)")
                            .accessibilityLabel("Retry saving this rating")
                            .help("Retry saving this rating")
                    }
                }
                .padding(.leading, 4)
            }
        }
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
        }
        .buttonStyle(FirstMateActionButtonStyle(isSelected: selected))
        .disabled(!presentation.isWritable || presentation.isSaving || (up && selected))
        .accessibilityIdentifier("first-mate-feedback-\(up ? "up" : "down")-\(messageID)")
        .accessibilityLabel(selected ? "\(title), selected" : title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(selected ? "\(title) — selected" : title)
    }
}

/// A 24pt icon action in a transcript row: a 10% wash when selected or
/// pressed, and no hover tracking (transcript rows never observe the pointer).
struct FirstMateActionButtonStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        FirstMateActionButtonBody(configuration: configuration, isSelected: isSelected)
    }
}

private struct FirstMateActionButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let isSelected: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .herdrFont(size: 13)
            .foregroundStyle(isSelected ? HerdrTheme.primaryText : HerdrTheme.iconTint)
            .frame(width: HerdrTheme.ControlHeight.small, height: HerdrTheme.ControlHeight.small)
            .background(
                isSelected || configuration.isPressed ? HerdrTheme.selectedFill : .clear,
                in: .rect(cornerRadius: HerdrTheme.Radius.control)
            )
            // A selected rating stays legible when it cannot be changed.
            .opacity(isEnabled || isSelected ? 1 : 0.42)
            .frame(minWidth: HerdrTheme.minHitTarget, minHeight: HerdrTheme.minHitTarget)
            .contentShape(.rect)
    }
}
