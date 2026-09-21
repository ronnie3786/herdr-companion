import SwiftUI

struct FirstMateFeatureCard: View {
    let feature: FirstMateFeature
    let snapshot: FirstMateSnapshot?
    @Environment(\.colorScheme) private var scheme
    private var palette: FirstMatePalette { FirstMatePalette(scheme: scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                FirstMateStatusLabel(status: feature.status)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(feature.workItemID ?? "Idea")
                    Text(FirstMateUsageFormatting.compactCost(feature.usage))
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(feature.title).font(.headline).foregroundStyle(palette.text)
                Text(feature.goal).font(.subheadline).foregroundStyle(palette.secondaryText).lineLimit(2)
            }
            HStack(spacing: 6) {
                Image(systemName: "point.3.connected.trianglepath.dotted").accessibilityHidden(true)
                Text(snapshot?.currentVisit?.title ?? (feature.currentVisitID == nil ? "Ready to shape the plan" : "Open feature"))
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).accessibilityHidden(true)
            }
            .font(.caption)
            .foregroundStyle(palette.accent)
        }
        .multilineTextAlignment(.leading)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface, in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(palette.line, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(feature.title), \(feature.workItemID ?? "Idea"), status \(feature.status.replacingOccurrences(of: "_", with: " ")). Goal: \(feature.goal). \(FirstMateUsageFormatting.taskAccessibilityDescription(feature.usage))")
    }
}
