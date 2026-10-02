import SwiftUI

/// Restyles the existing sections without replacing their controls or bindings.
struct SettingsGlassFormStyle: FormStyle {
    func makeBody(configuration: Configuration) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsDesign.sectionSpacing) {
                ForEach(sections: configuration.content) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        section.header
                            .padding(.horizontal, 2)
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(section.content) { row in
                                row
                                    .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                                    .padding(.horizontal, SettingsDesign.rowInset)
                                    .padding(.vertical, 7)
                                if row.id != section.content.last?.id {
                                    HerdrTheme.rowDivider.frame(height: 1)
                                        .padding(.horizontal, SettingsDesign.rowInset)
                                }
                            }
                        }
                        .background(HerdrTheme.cardFill, in: .rect(cornerRadius: HerdrTheme.Radius.card))
                        .overlay {
                            RoundedRectangle(cornerRadius: HerdrTheme.Radius.card)
                                .strokeBorder(HerdrTheme.outline)
                                .allowsHitTesting(false)
                        }
                        section.footer
                            .padding(.horizontal, 2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: SettingsDesign.readingWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsDesign.pageInset)
            .padding(.bottom, 28)
        }
        .labeledContentStyle(SettingsLabeledContentStyle())
        .toggleStyle(SettingsToggleStyle())
        .tint(HerdrTheme.controlAccent)
        .scrollContentBackground(.hidden)
    }
}

private struct SettingsLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            configuration.label
            Spacer(minLength: 12)
            configuration.content
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct SettingsToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 20) {
            configuration.label
            Spacer(minLength: 12)
            Toggle(configuration)
                .labelsHidden()
                .toggleStyle(.switch)
                .fixedSize()
        }
    }
}
