import SwiftUI

/// The folder chips under the pinned orbs: All, Needs you, Moving, Done,
/// each with its count. Scrolls sideways when the column is narrow.
struct FirstMateFolderChips: View {
    @Binding var folder: FirstMateListFolder
    let rows: [FirstMateConversation]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 5) {
                ForEach(FirstMateListFolder.allCases) { option in
                    let count = rows.count { option.includes($0) }
                    let selected = option == folder
                    Button { folder = option } label: {
                        HStack(spacing: 5) {
                            Text(option.title).herdrFont(.subheadline, weight: .semibold)
                            Text("\(count)").herdrFont(.caption, weight: .semibold).monospacedDigit()
                                .foregroundStyle(selected ? HerdrTheme.secondaryText : HerdrTheme.tertiaryText)
                        }
                        .foregroundStyle(selected ? HerdrTheme.primaryText : HerdrTheme.secondaryText)
                        .padding(.horizontal, 10).frame(minHeight: 34)
                        .background(selected ? HerdrTheme.inkFill(0.15) : HerdrTheme.inkFill(0.05), in: .capsule)
                        .frame(minHeight: 44).contentShape(.rect)
                    }
                    .buttonStyle(.herdrPlain)
                    .accessibilityLabel("\(option.title), \(count)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("first-mate-folder-\(option.rawValue)")
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-mate-folders")
    }
}
