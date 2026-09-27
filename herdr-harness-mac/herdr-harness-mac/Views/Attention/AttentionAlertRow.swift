import SwiftUI

struct AttentionAlertRow: View {
    @Bindable var model: HerdrAppModel
    let alert: HerdrAlert
    let pane: HerdrPane?
    let selectPane: (HerdrPane, HerdrAlert?) -> Void
    @State private var isHovering = false

    var body: some View {
        Group {
            if let pane {
                Button {
                    selectPane(pane, alert)
                } label: {
                    AlertCardView(alert: alert, pane: pane)
                }
                .buttonStyle(.plain)
                .overlay(alignment: .topTrailing) {
                    if isHovering { clearButton }
                }
                .onHover { isHovering = $0 }
            } else {
                // Full strength: the closed-pane label and the missing chevron
                // mark the state, and dimming the card would drop its text under 4.5:1.
                AlertCardView(alert: alert, pane: nil)
                    .overlay(alignment: .topTrailing) {
                        clearButton
                    }
            }
        }
        .contextMenu {
            Button("Clear notification", systemImage: "xmark.circle") {
                clear()
            }
        }
    }

    private var clearButton: some View {
        Button {
            clear()
        } label: {
            Image(systemName: "xmark")
                .herdrFont(.caption, weight: .bold)
                .foregroundStyle(HerdrTheme.mist)
                .frame(width: HerdrTheme.minHitTarget, height: HerdrTheme.minHitTarget)
                .background(HerdrTheme.elevated, in: Circle())
        }
        .buttonStyle(.plain)
        .padding(8)
        .help("Clear notification")
        .accessibilityLabel("Clear notification")
    }

    private func clear() {
        Task { await model.markAlertRead(alert) }
    }
}
