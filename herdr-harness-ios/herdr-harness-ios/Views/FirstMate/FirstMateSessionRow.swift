import SwiftUI

struct FirstMateSessionRow: View {
    @Bindable var store: FirstMateStore
    let session: FirstMateSession
    var isSelected = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button {
            Task { await store.open(.history(session)) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "bubble.left.and.bubble.right")
                    .foregroundStyle(FirstMatePalette(scheme: scheme).accent)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 7) {
                    Text("\(session.kindDisplayName) · generation \(session.generation)")
                        .font(.subheadline.weight(.semibold))
                    Text(session.ownershipStatus.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(FirstMateUsageFormatting.inlineSummary(session.usage))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    FirstMateStatusLabel(status: session.status)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Opens the saved session for this generation")
        .accessibilityIdentifier("first-mate-saved-session-\(session.nativeSessionID)")
    }
}
