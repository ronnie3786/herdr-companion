import SwiftUI

/// The `@` picker, floating above the composer from its leading edge.
struct FirstMateMentionPicker: View {
    let options: [FirstMateMentionOption]
    let highlighted: Int
    /// "Crew on {title}".
    let crewTitle: String?
    let pick: (FirstMateMentionOption) -> Void
    let hover: (Int) -> Void

    static let width: CGFloat = 320
    static let maximumHeight: CGFloat = 320
    static let rowHeight: CGFloat = 34
    static let labelHeight: CGFloat = 24
    /// The design's float surface (#191820 at 95% over a 20 pt backdrop
    /// blur). Without the blur, 5% lets the transcript's text show through,
    /// so the native surface is opaque.
    static let floatFill = Color(.sRGB, red: 25 / 255, green: 24 / 255, blue: 32 / 255, opacity: 1)

    private var features: [(Int, FirstMateMentionOption)] {
        options.enumerated().filter { $0.element.section == .features }.map { ($0.offset, $0.element) }
    }

    private var crew: [(Int, FirstMateMentionOption)] {
        options.enumerated().filter { $0.element.section == .crew }.map { ($0.offset, $0.element) }
    }

    /// The picker's height for these options: rows and section labels, at
    /// most 320 pt, then it scrolls.
    static func height(for options: [FirstMateMentionOption]) -> CGFloat {
        let sections = Set(options.map(\.section)).count
        return min(CGFloat(options.count) * rowHeight + CGFloat(sections) * labelHeight + 12, maximumHeight)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !features.isEmpty {
                        label("Features")
                        ForEach(features, id: \.1.id) { index, option in row(option, index: index) }
                    }
                    if !crew.isEmpty {
                        label(crewTitle.map { "Crew on \($0)" } ?? "Crew")
                        ForEach(crew, id: \.1.id) { index, option in row(option, index: index) }
                    }
                }
                .padding(6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: highlighted) { _, index in
                guard options.indices.contains(index) else { return }
                proxy.scrollTo(options[index].id)
            }
        }
        .frame(width: Self.width, height: Self.height(for: options))
        .background(Self.floatFill, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(HerdrTheme.outline, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 20, y: 18)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tag a feature or agent")
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .herdrFont(size: HerdrTheme.TextSize.caption, weight: .semibold)
            .foregroundStyle(HerdrTheme.tertiaryText)
            .lineLimit(1)
            .padding(.top, 5)
            .padding(.bottom, 4)
            .padding(.horizontal, 8)
            .frame(height: Self.labelHeight, alignment: .bottomLeading)
    }

    private func row(_ option: FirstMateMentionOption, index: Int) -> some View {
        Button { pick(option) } label: {
            HStack(spacing: 9) {
                FirstMateEmojiDisc(emoji: option.emoji, size: 24, edge: FirstMateChatStatusStyle.dotColor(for: option.status))
                Text(option.candidate.name)
                    .herdrFont(size: 12.5, weight: .semibold)
                    .foregroundStyle(HerdrTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text(option.detail)
                    .herdrFont(size: HerdrTheme.TextSize.caption, weight: option.section == .features && !FirstMateChatStatusStyle.isQuiet(option.status) ? .semibold : .medium)
                    .foregroundStyle(option.section == .features ? FirstMateChatStatusStyle.color(for: option.status) : HerdrTheme.tertiaryText)
                    .lineLimit(1)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .frame(height: Self.rowHeight)
            .background(index == highlighted ? HerdrTheme.inkFill(0.10) : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.herdrPlain)
        .onHover { if $0 { hover(index) } }
        .id(option.id)
        .accessibilityLabel("\(option.candidate.name), \(option.detail)")
        .accessibilityAddTraits(index == highlighted ? .isSelected : [])
    }
}
