import AppKit
import SwiftUI

/// Unlike an expiring notice, this keeps the transcript and the exact retry
/// destination available even when no lead conversation could be loaded.
struct FirstMateHudDeliveryCard: View {
    let controller: FirstMateHudController
    let delivery: FirstMateHudDelivery

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(delivery.isSending ? "Sending…" : "Your message is kept here", systemImage: "text.bubble")
                .font(.system(size: 13, weight: .semibold))
            Text(delivery.destinationLabel)
                .font(.system(size: 11))
                .foregroundStyle(HerdrTheme.secondaryText)
                .lineLimit(2)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let error = delivery.error {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(HerdrTheme.warning)
                    }
                    Text(delivery.transcript)
                        .font(.system(size: 12.5))
                        .foregroundStyle(HerdrTheme.primaryText)
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                Button("Retry send") { Task { await controller.retryDelivery() } }
                    .disabled(controller.isSending)
                    .accessibilityIdentifier("first-mate-hud-retry-send")
                Button("Copy text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(delivery.transcript, forType: .string)
                }
                .accessibilityIdentifier("first-mate-hud-copy-message")
                Spacer(minLength: 0)
                Button("Discard") { controller.discardDelivery() }
                    .disabled(controller.isSending)
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .firstMateHudCard()
        .accessibilityIdentifier("first-mate-hud-kept-message")
    }
}
