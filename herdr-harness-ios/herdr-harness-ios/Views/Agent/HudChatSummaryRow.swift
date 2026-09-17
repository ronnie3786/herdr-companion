import SwiftUI

struct HudChatSummaryRow: View {
    let chat: HudChatSummary
    let machineID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(chat.title)
                    .font(.headline)
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Label(chat.status.label, systemImage: statusSymbol)
                    .font(.subheadline)
                    .foregroundStyle(statusColor)
            }

            HStack(spacing: 10) {
                Label("\(chat.turnCount) \(chat.turnCount == 1 ? "turn" : "turns")", systemImage: "text.bubble")
                if let cwd = chat.cwd, !cwd.isEmpty {
                    Label(cwd, systemImage: "folder")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.subheadline)
            .foregroundStyle(HerdrTheme.mist)

            if let date = HerdrTimestamp.date(from: chat.updatedAt) {
                Text(date, format: .relative(presentation: .named))
                    .font(.subheadline)
                    .foregroundStyle(HerdrTheme.muted)
            }
        }
        .padding(HerdrTheme.cardPadding)
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .background(HerdrTheme.elevated.opacity(0.55))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.cardRadius)
                .strokeBorder(HerdrTheme.surface, lineWidth: 1)
        }
        .clipShape(.rect(cornerRadius: HerdrTheme.cardRadius))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(chat.title), \(chat.status.label), \(chat.turnCount) turns, \(machineID)")
    }

    private var statusSymbol: String {
        switch chat.status {
        case .queued: "clock"
        case .running: "sparkles"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        case .promoted: "rectangle.and.arrow.up.right"
        }
    }

    private var statusColor: Color {
        switch chat.status {
        case .queued, .running: HerdrTheme.working
        case .completed, .promoted: HerdrTheme.success
        case .failed: HerdrTheme.alert
        case .cancelled: HerdrTheme.mist
        }
    }
}
