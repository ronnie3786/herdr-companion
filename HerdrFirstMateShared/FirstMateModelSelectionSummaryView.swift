import SwiftUI

struct FirstMateModelSelectionSummaryView: View {
    let selection: FirstMateModelSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Model selection", systemImage: "cpu")
                .font(.headline)
            LabeledContent("Profile", value: selection.profileDisplayName)
            LabeledContent("Requested", value: selection.requestedDisplayName)
            LabeledContent("Actual", value: selection.actualDisplayName)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(selection.fullDisplayName)
        .accessibilityIdentifier("first-mate-model-selection-summary")
    }
}
