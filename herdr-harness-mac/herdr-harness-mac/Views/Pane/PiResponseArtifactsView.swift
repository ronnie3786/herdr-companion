import SwiftUI

struct PiResponseArtifactsView: View {
    let model: HerdrAppModel
    let artifacts: [AgentResultArtifact]
    var isUnassociated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(isUnassociated ? "Other session attachments" : "Response attachments", systemImage: "paperclip")
                .herdrFont(.caption, weight: .semibold)
                .foregroundStyle(HerdrTheme.mist)
            if isUnassociated {
                Text("The original response is not available in this transcript.")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.muted)
            }
            ForEach(artifacts) { artifact in
                PaneResultArtifactView(model: model, artifact: artifact)
            }
        }
        .accessibilityIdentifier(isUnassociated ? "pi-session-other-attachments" : "pi-response-attachments")
    }
}
