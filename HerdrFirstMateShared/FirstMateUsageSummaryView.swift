import SwiftUI

struct FirstMateUsageSummaryView: View {
    let usage: FirstMateUsage?
    var title = "Usage and estimated cost"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let usage {
                HStack(alignment: .firstTextBaseline) {
                    Text(FirstMateUsageFormatting.compactCost(usage))
                        .font(.title3)
                        .bold()
                        .monospacedDigit()
                    Spacer(minLength: 12)
                    Text(usage.status.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Pi-reported estimated USD. This is not a provider invoice; subscription providers may report $0.00.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("\(FirstMateUsageFormatting.tokens(usage.totalTokens)) total tokens · \(FirstMateUsageFormatting.tokens(usage.inputTokens)) input · \(FirstMateUsageFormatting.tokens(usage.outputTokens)) output")
                    .font(.subheadline)
                if usage.cacheReadTokens > 0 || usage.cacheWriteTokens > 0 {
                    Text("Cache · \(FirstMateUsageFormatting.tokens(usage.cacheReadTokens)) read · \(FirstMateUsageFormatting.tokens(usage.cacheWriteTokens)) write")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(FirstMateUsageFormatting.coverage(usage))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if usage.status == "partial" || usage.stale == true {
                    Label(usage.stale == true ? "Showing the last reported total; the usage source is temporarily unreadable." : "Some retained usage or cost records are unavailable.", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if !usage.models.isEmpty {
                    Divider()
                    ForEach(usage.models) { model in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(FirstMateUsageFormatting.modelName(provider: model.provider, model: model.model))
                                    .font(.subheadline)
                                    .bold()
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .layoutPriority(1)
                                Spacer(minLength: 12)
                                Text(FirstMateUsageFormatting.cost(model.costUSD, currencyCode: usage.currency))
                                    .font(.subheadline)
                                    .monospacedDigit()
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            Text("\(FirstMateUsageFormatting.tokens(model.totalTokens)) tokens · \(model.usageRecords) usage records")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            if model.status == "partial" || model.missingCostRecords > 0 {
                                Text("Partial model coverage")
                                    .font(.footnote)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            } else {
                Label("Usage unavailable", systemImage: "questionmark.circle")
                    .font(.subheadline)
                Text("This companion did not report usage. Update the companion server to inspect Pi-reported estimates.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(FirstMateUsageFormatting.accessibilityDescription(usage))
        .accessibilityIdentifier("first-mate-usage-summary")
    }
}
