import SwiftUI

/// Chat identity, current activity, and lifecycle status share one bubble.
struct HerdrHudSessionBubbleLabel: View {
    @Environment(\.herdrFontScale) private var fontScale
    let chip: HerdrHudSessionChips.Chip
    var model: HerdrAppModel? = nil
    @State private var costSummary: String?
    @State private var costSessionKey = ""

    private var showsSessionCost: Bool {
        model?.pane(id: chip.id)?.supportsPiSemanticChat == true
    }

    private var costRefreshKey: String {
        let pane = model?.pane(id: chip.id)
        return "\(chip.id)|\(pane?.piSemantic?.sessionID ?? "")|\(chip.status)|\(model?.connectionGeneration ?? 0)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(chip.title)
                .herdrFont(.caption, weight: .bold)
                .foregroundStyle(HerdrTheme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.trailing, 20)

            HStack(spacing: 4) {
                Text(chip.emoji)
                    .herdrFont(.caption2)
                    .accessibilityHidden(true)
                Text(chip.activity)
                    .herdrFont(.caption2)
                    .italic()
                    .foregroundStyle(HerdrTheme.mist)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Label(chip.statusLabel, systemImage: chip.statusSymbol)
                    .herdrFont(.caption2)
                    .foregroundStyle(chip.status.color)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if showsSessionCost {
                    Text(costSummary ?? "Cost …")
                        .herdrFont(.caption2, monospaced: true)
                        .foregroundStyle(HerdrTheme.mist)
                        .fixedSize()
                        .padding(.horizontal, 4)
                        .background(HerdrTheme.graphite.opacity(0.8), in: .capsule)
                        .layoutPriority(1)
                        .help(costSummary.map { "Cumulative session cost: \($0)" } ?? "Session cost has not been reported by Pi yet")
                        .accessibilityLabel(costSummary.map { "Session cost \($0)" } ?? "Session cost unavailable")
                        .accessibilityIdentifier("hud-session-cost-\(chip.id)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(
            width: HerdrHudPlacement.chipWidth,
            height: HerdrHudPlacement.chipHeight(fontScale: fontScale.rawValue)
        )
        .background(HerdrTheme.elevated, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(chip.status.color.opacity(0.25), lineWidth: 1)
        }
        .shadow(color: chip.status == .working ? chip.status.color.opacity(0.16) : .clear, radius: 4)
        .contentShape(.rect(cornerRadius: 10))
        .task(id: costRefreshKey) { await refreshCost() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Open \(chip.title), \(chip.activity), \(chip.statusLabel)\(costSummary.map { ", session cost \($0)" } ?? "")")
    }

    private func refreshCost() async {
        guard let model, let pane = model.pane(id: chip.id), pane.supportsPiSemanticChat else { return }
        let identity = "\(pane.id)|\(pane.piSemantic?.sessionID ?? "")"
        if costSessionKey != identity {
            costSummary = nil
            costSessionKey = identity
        }
        while !Task.isCancelled {
            do {
                let snapshot = try await model.fetchPiConversationSnapshot(for: pane)
                guard !Task.isCancelled else { return }
                let sessionID = snapshot.session?.string(for: "id", "sessionId", "session_id")
                    ?? snapshot.session?.stringValue
                guard pane.piSemantic?.sessionID == nil || pane.piSemantic?.sessionID == sessionID else {
                    costSummary = nil
                    return
                }
                if snapshot.available {
                    costSummary = PiSessionCost(from: snapshot.state?["cost"])?.summary ?? costSummary
                }
            } catch {
                guard !Task.isCancelled else { return }
                // Retain the last reported total for this same session while
                // reconnecting, instead of making its cost disappear.
            }
            do { try await Task.sleep(for: .seconds(15)) }
            catch { return }
        }
    }
}
