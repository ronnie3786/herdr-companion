import SwiftUI

struct AgentProfilesNoticeView: View {
    let message: String
    let systemImage: String
    let color: Color
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(message, systemImage: systemImage)
                .herdrFont(.callout)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(actionTitle, action: action)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(color.opacity(0.09))
        .accessibilityIdentifier("agent-profiles-notice")
    }
}
