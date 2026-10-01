import SwiftUI

// Stub owned by the Git workstream: replaced with the native First Mate Git
// screen (regular width: list beside diff; compact: list first, diff pushed).

extension View {
    /// Presents First Mate Git full screen for `item`.
    func firstMateGitCover(item: Binding<FirstMateGitTarget?>, model: HerdrAppModel) -> some View {
        fullScreenCover(item: item) { target in
            FirstMateGitScreen(target: target, model: model)
        }
    }
}

struct FirstMateGitScreen: View {
    let target: FirstMateGitTarget
    let model: HerdrAppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Text("Git for \(target.featureTitle)")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .accessibilityIdentifier("first-mate-git")
    }
}
