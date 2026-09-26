import SwiftUI

/// The composer context line's usage meter: a 14pt ring and "25% · $1.87".
/// Hides itself when the bridge predates context reporting or when Pi has
/// not produced a reading yet (for example right after compaction).
struct PiContextRing: View {
    let usage: PiContextUsage?
    let cost: PiSessionCost?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.herdrFontScale) private var fontScale

    var body: some View {
        if usage?.fraction != nil || cost?.summary != nil {
            HStack(spacing: 6) {
                if let fraction = usage?.fraction {
                    HerdrProgressRing(fraction: fraction, color: meterColor)
                        .help(usage?.summary ?? "Context usage")
                }
                Text(label)
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .monospacedDigit()
                    .foregroundStyle(meterColor)
                    .lineLimit(1)
                    .accessibilityIdentifier("pi-session-cost")
            }
            .fixedSize()
            .help(accessibilityLabel)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: usage?.fraction)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier("pi-context-meter")
        }
    }

    private var label: String {
        [usage?.fraction != nil ? (usage?.percentText ?? "…") : nil, cost?.summary]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// Quiet until the window is filling up.
    private var meterColor: Color {
        guard let fraction = usage?.fraction else { return HerdrTheme.tertiaryText }
        switch fraction {
        case ..<0.6: return HerdrTheme.tertiaryText
        case ..<0.85: return HerdrTheme.working
        default: return HerdrTheme.alert
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

/// MonoCode's 14pt progress ring: a 25% track and a rounded arc. A static
/// shape with no repeating animation, so it is cheap in a streaming chat.
struct HerdrProgressRing: View {
    let fraction: Double
    var color: Color = HerdrTheme.tertiaryText
    @Environment(\.herdrFontScale) private var fontScale

    var body: some View {
        let size = 14 * fontScale.rawValue
        let lineWidth = 1.75 * fontScale.rawValue
        ZStack {
            Circle()
                .stroke(color.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size * 0.75, height: size * 0.75)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
