import SwiftUI

struct FleetSummaryView: View {
    @Bindable var model: HerdrAppModel

    var body: some View {
        GlassCard {
            HStack(spacing: 0) {
                metric(value: model.workspaces.count, label: "spaces", symbol: "rectangle.3.group")
                divider
                metric(value: model.workingCount, label: "working", symbol: "waveform.path.ecg")
                divider
                metric(value: model.attentionPanes.count, label: "need you", symbol: "hand.raised.fill")
            }
            .padding(.vertical, 15)
        }
    }

    private func metric(value: Int, label: String, symbol: String) -> some View {
        VStack(spacing: 5) {
            Label("\(value)", systemImage: symbol)
                .herdrFont(.headline, weight: .semibold)
                .foregroundStyle(value > 0 && label == "need you" ? HerdrTheme.alert : HerdrTheme.text)
            Text(label)
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.mist)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var divider: some View {
        Rectangle()
            .fill(HerdrTheme.separator)
            .frame(width: 1, height: 34)
    }
}
