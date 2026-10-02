import SwiftUI

struct SettingsSidebar: View {
    @Binding var selection: SettingsPane
    @State private var hoveredPane: SettingsPane?

    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(SettingsPane.allCases) { pane in
                    let selected = selection == pane
                    Button { selection = pane } label: {
                        HStack(spacing: 10) {
                            Image(systemName: pane.systemImage)
                                .herdrFont(size: 15)
                                .foregroundStyle(selected ? HerdrTheme.accent : HerdrTheme.secondaryText)
                                .frame(width: 22)
                                .accessibilityHidden(true)
                            Text(pane.title)
                                .herdrFont(size: HerdrTheme.TextSize.body, weight: selected ? .semibold : .medium)
                                .foregroundStyle(selected ? HerdrTheme.primaryText : HerdrTheme.secondaryText)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 38)
                        .background(selected ? HerdrTheme.accent.opacity(0.13)
                                    : hoveredPane == pane ? HerdrTheme.hoverFill : .clear,
                                    in: .rect(cornerRadius: 9))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9)
                                .strokeBorder(selected ? HerdrTheme.accent.opacity(0.24) : .clear)
                        }
                        .contentShape(.rect(cornerRadius: 9))
                    }
                    .buttonStyle(.herdrPlain)
                    .onHover { hoveredPane = $0 ? pane : nil }
                    .accessibilityLabel(pane.title)
                    .accessibilityIdentifier(pane.accessibilityIdentifier)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(12)
        }
        .frame(width: SettingsDesign.railWidth)
        .frame(maxHeight: .infinity)
        .background { HerdrGlassBackground(level: HerdrTheme.Glass.sidebar, base: HerdrTheme.railBackground) }
        .herdrHairline(.trailing)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-sidebar")
    }
}
