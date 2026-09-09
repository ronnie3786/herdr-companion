import SwiftUI

/// A compact, always-visible meter for the active model's context usage.
/// Hides itself when the bridge predates context reporting or when Pi has
/// not produced a reading yet (for example right after compaction).
struct PiContextMeterView: View {
    let usage: PiContextUsage?
    let cost: PiSessionCost?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if usage?.fraction != nil || cost?.summary != nil {
            HStack(spacing: 10) {
                if let usage, let fraction = usage.fraction {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(HerdrTheme.subtleSeparator)
                            Capsule()
                                .fill(barColor.opacity(0.7))
                                .frame(width: max(6, proxy.size.width * fraction))
                        }
                    }
                    .frame(height: 2)
                    .help(usage.summary ?? "Context usage")

                    Text(usage.percentText ?? "…")
                        .herdrFont(.caption2, weight: .medium, monospacedDigit: true)
                        .foregroundStyle(barColor)
                        .lineLimit(1)

                    if let costText = cost?.summary {
                        Text("·")
                            .herdrFont(.caption2)
                            .foregroundStyle(HerdrTheme.muted)
                        Text(costText)
                            .herdrFont(.caption2, monospacedDigit: true)
                            .foregroundStyle(HerdrTheme.mist)
                            .lineLimit(1)
                            .accessibilityIdentifier("pi-session-cost")
                    }
                } else if let costText = cost?.summary {
                    Spacer()
                    Text(costText)
                        .herdrFont(.caption2, monospacedDigit: true)
                        .foregroundStyle(HerdrTheme.mist)
                        .lineLimit(1)
                        .accessibilityIdentifier("pi-session-cost")
                }
            }
            .padding(.horizontal, HerdrTheme.pagePadding)
            .padding(.vertical, 5)
            .background(HerdrTheme.graphite)
            .help(accessibilityLabel)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: usage?.fraction)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier("pi-context-meter")
        }
    }

    private var barColor: Color {
        guard let fraction = usage?.fraction else { return HerdrTheme.accent }
        switch fraction {
        case ..<0.6:
            return HerdrTheme.accent
        case ..<0.85:
            return HerdrTheme.working
        default:
            return HerdrTheme.alert
        }
    }

    private func accessibilitySummary(for usage: PiContextUsage) -> String {
        if let tokens = usage.tokens, let window = usage.contextWindow {
            return "Context usage: \(tokens.formatted()) of \(window.formatted()) tokens"
        }
        return "Context usage: \(usage.summary ?? "unknown")"
    }

    private var accessibilityLabel: String {
        if let usage {
            let usageSummary = accessibilitySummary(for: usage)
            if let costSummary = cost?.summary {
                return "\(usageSummary), session cost \(costSummary)"
            }
            return usageSummary
        }
        if let costSummary = cost?.summary {
            return "Session cost \(costSummary)"
        }
        return ""
    }
}
