import SwiftUI

/// Kept outside filtered cards so a successful remote send with a lost receipt
/// cannot hide the only way to inspect its result or retry its original handle.
struct HomeReplyOutcomesView: View {
    let controller: HomeQuickReplyController
    let outcomes: [HomeQuickReplyOutcome]
    let onOpen: (HomeQuickReplyOutcome) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Reply status").herdrFont(size: 13, weight: .semibold)
                .foregroundStyle(HomePalette.ink)
                .accessibilityIdentifier("home-reply-status-heading")
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(outcomes) { outcome in
                        row(outcome)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: min(180, CGFloat(outcomes.count) * 115))
        }
        .padding(14)
        .frame(maxWidth: 760, alignment: .leading)
        .background(HomePalette.color(0x222129), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(HomePalette.border))
    }

    private func row(_ outcome: HomeQuickReplyOutcome) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(outcome.title).herdrFont(size: 12.5, weight: .semibold)
                .foregroundStyle(HomePalette.ink)
            Text(outcome.replyLabel).herdrFont(size: 12)
                .foregroundStyle(HomePalette.prose)
                .lineLimit(2)
                .help(outcome.replyLabel)
            Text(outcome.phase.message ?? "Check this reply in its conversation.")
                .herdrFont(size: 11.5).foregroundStyle(HomePalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Open conversation") { onOpen(outcome) }
                    .disabled(!controller.canOpenOutcome(outcome))
                if outcome.phase.canRetry {
                    Button("Retry reply") { Task { await controller.retry(route: outcome.id) } }
                        .disabled(!controller.canRetry(route: outcome.id))
                }
                if controller.canAcknowledge(outcome) {
                    Button("Checked in conversation") { controller.acknowledge(outcome) }
                        .help("Hides this Home status without confirming delivery or sending another reply.")
                        .accessibilityHint("Hides this status. Delivery remains unconfirmed and no reply is sent.")
                }
            }
            .herdrFont(size: 12, weight: .semibold)
            .foregroundStyle(HomePalette.accent)
            .buttonStyle(HomeButtonStyle())
            if !controller.canOpenOutcome(outcome) {
                Text("The original conversation is unavailable. Its reply status is kept here.")
                    .herdrFont(size: 11.5).foregroundStyle(HomePalette.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
