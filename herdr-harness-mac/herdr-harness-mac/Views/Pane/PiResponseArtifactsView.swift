import SwiftUI

struct PiResponseArtifactsView: View {
    let model: HerdrAppModel
    let artifacts: [AgentResultArtifact]
    var isUnassociated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(isUnassociated ? "Other session attachments" : "Response attachments", systemImage: "paperclip")
                .herdrFont(size: HerdrTheme.TextSize.caption, weight: .medium)
                .foregroundStyle(HerdrTheme.secondaryText)
            if isUnassociated {
                Text("The original response is not available in this transcript.")
                    .herdrFont(size: HerdrTheme.TextSize.small)
                    .foregroundStyle(HerdrTheme.tertiaryText)
            }
            ForEach(artifacts) { artifact in
                PaneResultArtifactView(model: model, artifact: artifact)
            }
        }
        .accessibilityIdentifier(isUnassociated ? "pi-session-other-attachments" : "pi-response-attachments")
    }
}
