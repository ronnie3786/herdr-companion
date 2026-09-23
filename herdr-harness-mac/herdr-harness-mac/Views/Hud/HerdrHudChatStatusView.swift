import SwiftUI

/// Text and symbols accompany color so readiness never depends on green alone.
///
/// This is the HUD chat bubble's copy of the agent-session status row. The
/// label keeps layout priority over its trailing metadata so a long model name
/// or cost can never squeeze it into an overlap, and the one-line label may
/// shrink slightly so an exceptional reconnect message still fits instead of
/// spilling outside the card.
struct HerdrHudChatStatusView: View {
    let session: HerdrHudSession

    var body: some View {
        let status = HerdrHudChatBubblePresentation.status(for: session)
        Label(status.label, systemImage: status.symbol)
            .herdrFont(.caption2)
            .foregroundStyle(status.color)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .layoutPriority(1)
    }
}
