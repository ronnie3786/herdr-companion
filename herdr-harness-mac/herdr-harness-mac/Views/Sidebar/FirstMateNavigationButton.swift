import SwiftUI

/// The Chat navigator's First Mate entry with its global attention badge.
///
/// The badge appears only while at least one feature on any configured host is
/// waiting on a human decision (`awaiting_direction` or `blocked`). It reports
/// outstanding work rather than unread messages, so opening First Mate never
/// clears it; only a later successful status refresh that resolves the feature
/// does. The count is global: the selected chat, machine scope, and search text
/// never change it.
struct FirstMateNavigationButton: View {
    /// The exact number of features waiting on a human across every configured
    /// host. Zero hides the badge.
    var attentionCount: Int = 0
    let action: () -> Void

    /// The largest count the compact badge spells out. Larger totals render as
    /// `99+`, while accessibility and hover help keep the exact number.
    static let badgeMaximum = 99

    /// Human-attention orange, matching ``FirstMateStatusLabel``.
    static let badgeColor = Color.orange

    /// The compact visible text, or `nil` while there is nothing to report.
    static func badgeText(for count: Int) -> String? {
        guard count > 0 else { return nil }
        return count > badgeMaximum ? "\(badgeMaximum)+" : "\(count)"
    }

    /// The full spoken count and its meaning. VoiceOver hears the exact total
    /// even when the visible badge is capped at `99+`.
    static func accessibilityValue(for count: Int) -> String {
        switch count {
        case ..<1: "No features waiting on your direction"
        case 1: "1 feature waiting on your direction"
        default: "\(count) features waiting on your direction"
        }
    }

    /// Hover help with the exact count and the freshness caveat: a host that is
    /// temporarily unreachable keeps its last reported status.
    static func helpText(for count: Int) -> String {
        switch count {
        case ..<1:
            "Open First Mate. No features are waiting on your direction."
        case 1:
            "Open First Mate. 1 feature is waiting on your direction, based on the latest status from every machine."
        default:
            "Open First Mate. \(count) features are waiting on your direction, based on the latest status from every machine."
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Label("First Mate", systemImage: "sailboat")
                    .herdrFont(.headline)
                Spacer(minLength: 8)
                if let badgeText = Self.badgeText(for: attentionCount) {
                    Text(badgeText)
                        .herdrFont(.caption2, weight: .bold, monospacedDigit: true)
                        .foregroundStyle(HerdrTheme.ink)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Self.badgeColor, in: .capsule)
                        // The button's value already announces the exact
                        // count, so the decorative capsule stays out of the
                        // accessibility tree.
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(HerdrTheme.accent)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 10)
        .accessibilityIdentifier("open-first-mate")
        .accessibilityValue(Self.accessibilityValue(for: attentionCount))
        .help(Self.helpText(for: attentionCount))
    }
}

extension FirstMateAttention {
    /// Counts attention in a store-owned feature list, such as the demo store's.
    ///
    /// The live fleet index already counts host-scoped lists. The demo store
    /// keeps one list for its single synthetic host, so this wraps it in one
    /// `FirstMateFleetHost` and reuses the same distinct-feature predicate as
    /// the fleet path.
    static func count(features: [FirstMateFeature], machineID: String) -> Int {
        count(hosts: [
            FirstMateFleetHost(
                machineID: machineID,
                machineName: machineID,
                features: features,
                isLoading: false,
                error: nil,
                unsupported: false,
                lastUpdated: nil
            )
        ])
    }
}
