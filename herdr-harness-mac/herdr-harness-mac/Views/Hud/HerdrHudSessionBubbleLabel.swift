import SwiftUI

/// Chat identity, current activity, and lifecycle status share one bubble.
struct HerdrHudSessionBubbleLabel: View {
    @Environment(\.herdrFontScale) private var fontScale
    let chip: HerdrHudSessionChips.Chip
    var model: HerdrAppModel? = nil
    var metadata: HerdrHudSessionMetadata? = nil
    @State private var fetchedMetadata = HerdrHudSessionMetadata()
    @State private var costSessionKey = ""

    private var displayedMetadata: HerdrHudSessionMetadata { metadata ?? fetchedMetadata }

    private var costRefreshKey: String {
        let pane = model?.pane(id: chip.id)
        return "\(chip.id)|\(pane?.piSemantic?.sessionID ?? "")|\(chip.status)|\(model?.connectionGeneration ?? 0)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(chip.title)
                .herdrFont(.caption, weight: .bold)
                .foregroundStyle(HerdrTheme.text)
                .lineLimit(2)
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
                    .fixedSize(horizontal: true, vertical: false)
                HerdrHudSessionMetadataView(metadata: displayedMetadata)
                    .accessibilityIdentifier("hud-session-metadata-\(chip.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(width: HerdrHudPlacement.chipWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(HerdrTheme.elevated, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(chip.status.color.opacity(0.25), lineWidth: 1)
        }
        .shadow(color: chip.status == .working ? chip.status.color.opacity(0.16) : .clear, radius: 4)
        .contentShape(.rect(cornerRadius: 10))
        .task(id: costRefreshKey) { await refreshCost() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Open \(chip.title), \(chip.activity), \(chip.statusLabel), \(displayedMetadata.accessibilitySummary)")
    }

    private func refreshCost() async {
        guard let model, let pane = model.pane(id: chip.id), pane.supportsPiSemanticChat else { return }
        let identity = "\(pane.id)|\(pane.piSemantic?.sessionID ?? "")"
        if costSessionKey != identity {
            fetchedMetadata = HerdrHudSessionMetadata()
            costSessionKey = identity
        }
        while !Task.isCancelled {
            do {
                let snapshot = try await model.fetchPiConversationSnapshot(for: pane)
                guard !Task.isCancelled else { return }
                let sessionID = snapshot.session?.string(for: "id", "sessionId", "session_id")
                    ?? snapshot.session?.stringValue
                guard pane.piSemantic?.sessionID == nil || pane.piSemantic?.sessionID == sessionID else {
                    fetchedMetadata = HerdrHudSessionMetadata()
                    return
                }
                if snapshot.available {
                    fetchedMetadata = HerdrHudSessionMetadata(state: snapshot.state)
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
