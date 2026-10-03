import SwiftUI

struct FirstMateArchiveLogRow: View {
    let entry: FirstMateCleanupLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .foregroundStyle(color).frame(width: 28, height: 28)
                .background(color.opacity(0.08), in: .rect(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(entry.outcome.capitalized + " · " + entry.kind.replacingOccurrences(of: "_", with: " "))
                        .herdrFont(size: 12, weight: .medium)
                    Spacer()
                    if let date = timestamp {
                        Text(date, format: .dateTime.hour().minute().second())
                            .herdrFont(size: 11).monospacedDigit().foregroundStyle(HerdrTheme.secondaryText)
                    } else {
                        Text(entry.createdAt).herdrFont(size: 11).foregroundStyle(HerdrTheme.secondaryText)
                    }
                }
                Text(entry.reason).herdrFont(size: 12).fixedSize(horizontal: false, vertical: true)
                Text(entry.path).herdrFont(size: 11, monospaced: true)
                    .foregroundStyle(HerdrTheme.secondaryText)
                    .lineLimit(1).truncationMode(.middle).help(entry.path)
            }.textSelection(.enabled)
        }
    }

    private var timestamp: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: entry.createdAt) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: entry.createdAt)
    }

    private var color: Color {
        switch entry.outcome {
        case "failed": HerdrTheme.alert
        case "removed", "cataloged": HerdrTheme.success
        default: HerdrTheme.secondaryText
        }
    }

    private var symbol: String {
        switch entry.outcome {
        case "removed": "checkmark"
        case "retained": "lock"
        case "cataloged": "archivebox"
        case "failed": "exclamationmark.triangle"
        default: "arrow.trianglehead.2.clockwise"
        }
    }
}
