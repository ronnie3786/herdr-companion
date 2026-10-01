import SwiftUI

/// Whose inspector this is: the app model (for the owning machine's client),
/// the feature's identity and title, and how to open First Mate Git for it.
/// The workspace sets it around the chat and Info screens, so Overview,
/// Workflow, Builds and the simulator chip reach them without threading.
struct FirstMateInspectorContext {
    let model: HerdrAppModel
    let target: FirstMateFeatureTarget
    let featureTitle: String
    var openGit: (FirstMateGitTarget) -> Void
}

extension EnvironmentValues {
    @Entry var firstMateInspectorContext: FirstMateInspectorContext? = nil
}
