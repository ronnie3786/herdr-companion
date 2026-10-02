import SwiftUI

/// Automatic-discovery roles can still browse and read the local catalog.
/// Only the selection indicator dims while the selection is not editable.
struct AgentRoleSkillTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
