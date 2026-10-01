import SwiftUI

/// A step's agents or documents as a small chip (the Mac's `.chipdoc`):
/// glyph and count on the chip fill, 28 pt visual in a 44 pt hit target.
struct FirstMateResourceChip: View {
    let title: String
    let systemImage: String
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.system(size: 12, weight: .medium)).foregroundStyle(HerdrTheme.iconTint)
            Text(title).herdrFont(.footnote).foregroundStyle(HerdrTheme.secondaryText)
        }
        .padding(.horizontal, 9)
        .frame(minHeight: 28)
        .background(HerdrTheme.chipFill, in: .rect(cornerRadius: 8))
        .opacity(enabled ? 1 : 0.5)
        .frame(minHeight: HerdrTheme.minHitTarget)
        .contentShape(.rect)
    }
}
