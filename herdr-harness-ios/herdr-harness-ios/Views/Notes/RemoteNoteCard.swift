import SwiftUI

struct RemoteNoteCard: View {
    let note: RemoteNote
    let machineName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(note.displayTitle)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if !note.body.isEmpty {
                Text(note.body)
                    .font(.subheadline)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .firstTextBaseline) {
                Label(machineName, systemImage: "desktopcomputer")
                Spacer(minLength: 8)
                Text(note.updatedAt, format: .dateTime.month(.abbreviated).day())
            }
            .font(.caption)
            .foregroundStyle(HerdrTheme.crust.opacity(0.8))
            if note.statusLabel != "Saved note" {
                Text(note.statusLabel)
                    .font(.caption.weight(.semibold))
            }
        }
        .foregroundStyle(HerdrTheme.crust)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(note.color.fill, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the full note")
    }
}
