import SwiftUI

struct FirstMateUsageSummaryView: View {
    let usage: FirstMateUsage?
    var title = "Usage and estimated cost"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .summaryFont(.headline)
                .accessibilityAddTraits(.isHeader)
            if let usage {
                HStack(alignment: .firstTextBaseline) {
                    Text(FirstMateUsageFormatting.compactCost(usage))
                        .summaryFont(.title3)
                        .bold()
                        .monospacedDigit()
                    Spacer(minLength: 12)
                    Text(usage.status.replacingOccurrences(of: "_", with: " ").capitalized)
                        .summaryFont(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Pi-reported estimated USD. This is not a provider invoice; subscription providers may report $0.00.")
                    .summaryFont(.footnote)
                    .foregroundStyle(.secondary)
                Text("\(FirstMateUsageFormatting.tokens(usage.totalTokens)) total tokens · \(FirstMateUsageFormatting.tokens(usage.inputTokens)) input · \(FirstMateUsageFormatting.tokens(usage.outputTokens)) output")
                    .summaryFont(.subheadline)
                if usage.cacheReadTokens > 0 || usage.cacheWriteTokens > 0 {
                    Text("Cache · \(FirstMateUsageFormatting.tokens(usage.cacheReadTokens)) read · \(FirstMateUsageFormatting.tokens(usage.cacheWriteTokens)) write")
                        .summaryFont(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(FirstMateUsageFormatting.coverage(usage))
                    .summaryFont(.footnote)
                    .foregroundStyle(.secondary)
                if let warning = FirstMateUsageFormatting.coverageWarning(usage) {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .summaryFont(.footnote)
                        .foregroundStyle(summaryWarning)
                }
                if !usage.models.isEmpty {
                    Divider()
                    ForEach(usage.models) { model in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(FirstMateUsageFormatting.modelName(provider: model.provider, model: model.model))
                                    .summaryFont(.subheadline)
                                    .bold()
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .layoutPriority(1)
                                Spacer(minLength: 12)
                                Text(FirstMateUsageFormatting.cost(model.costUSD, currencyCode: usage.currency))
                                    .summaryFont(.subheadline)
                                    .monospacedDigit()
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            Text("\(FirstMateUsageFormatting.tokens(model.totalTokens)) tokens · \(model.usageRecords) usage records")
                                .summaryFont(.footnote)
                                .foregroundStyle(.secondary)
                            if model.status == "partial" || model.missingCostRecords > 0 {
                                Text("Partial model coverage")
                                    .summaryFont(.footnote)
                                    .foregroundStyle(summaryWarning)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            } else {
                Label("Usage unavailable", systemImage: "questionmark.circle")
                    .summaryFont(.subheadline)
                Text("This companion did not report usage. Update the companion server to inspect Pi-reported estimates.")
                    .summaryFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(FirstMateUsageFormatting.accessibilityDescription(usage))
        .accessibilityIdentifier("first-mate-usage-summary")
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

#if os(macOS)
private let summaryWarning = HerdrTheme.warning
#else
private let summaryWarning = Color.orange
#endif
