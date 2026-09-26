import SwiftUI

struct FirstMateModelSelectionSummaryView: View {
    let selection: FirstMateModelSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Model selection", systemImage: "cpu")
                .summaryFont(.headline)
            LabeledContent("Profile", value: selection.profileDisplayName)
            LabeledContent("Requested", value: selection.requestedDisplayName)
            LabeledContent("Actual", value: selection.actualDisplayName)
        }
        .summaryFont(.footnote)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(selection.fullDisplayName)
        .accessibilityIdentifier("first-mate-model-selection-summary")
    }
}

/// Mono sizes on the Mac (through the font-scale preference); iOS keeps its
/// text styles.
private extension View {
    func summaryFont(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> some View {
        #if os(macOS)
        let size: CGFloat = switch style {
        case .title3: 14
        case .headline: 13
        case .subheadline: 12
        default: 11
        }
        return herdrFont(size: size, weight: weight ?? (style == .headline ? .semibold : nil))
        #else
        return font(weight.map { Font.system(style).weight($0) } ?? Font.system(style))
        #endif
    }
}
