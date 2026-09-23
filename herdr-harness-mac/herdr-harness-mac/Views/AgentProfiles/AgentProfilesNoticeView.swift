import AppKit
import SwiftUI

struct AgentProfilesNoticeView: View {
    struct Action: Identifiable {
        let title: String
        var isProminent = false
        let perform: () -> Void

        var id: String { title }
    }

    let message: String
    let systemImage: String
    let color: Color
    let actions: [Action]

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .herdrFont(.body, weight: .semibold)
                .accessibilityHidden(true)
            Text(message)
                .herdrFont(.callout)
                .foregroundStyle(HerdrTheme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            ForEach(actions) { action in
                if action.isProminent {
                    Button(action.title, action: action.perform)
                        .herdrProminentButton()
                } else {
                    Button(action.title, action: action.perform)
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: HerdrTheme.compactRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .strokeBorder(color.opacity(0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-profiles-notice")
    }
}

/// The store's pending, conflict and error notices. Shown on the main screen
/// and inside sheets, which would otherwise cover them.
struct AgentProfileStoreNotices: View {
    let store: AgentProfilesStore
    let reload: () -> Void

    var body: some View {
        if let message = store.pendingMutationMessage {
            AgentProfilesNoticeView(
                message: message,
                systemImage: "arrow.clockwise.circle",
                color: HerdrTheme.warning,
                actions: [
                    .init(title: "Stop Retrying", perform: store.stopRetryingPendingMutation),
                    .init(title: "Retry", isProminent: true) { Task { await store.retryPendingMutation() } },
                ]
            )
        } else if let message = store.conflictMessage {
            AgentProfilesNoticeView(
                message: message,
                systemImage: "arrow.triangle.2.circlepath",
                color: HerdrTheme.mauve,
                actions: [
                    .init(title: "Copy Edits", perform: copyEdits),
                    .init(title: "Reload…", perform: reload),
                ]
            )
        } else if let message = store.errorMessage {
            AgentProfilesNoticeView(
                message: message,
                systemImage: "exclamationmark.triangle",
                color: HerdrTheme.alert,
                actions: [.init(title: "Dismiss", perform: store.dismissError)]
            )
        }
    }

    private func copyEdits() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.unsavedEditsText, forType: .string)
    }
}
