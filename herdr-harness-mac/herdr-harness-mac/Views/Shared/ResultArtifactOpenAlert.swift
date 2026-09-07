import SwiftUI

private struct ResultArtifactOpenAlert: ViewModifier {
    @Binding var failure: ResultArtifactOpenFailure?
    let model: HerdrAppModel

    func body(content: Content) -> some View {
        content.alert(
            failure?.title ?? "Couldn’t open document",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
            presenting: failure
        ) { failure in
            if failure.allowsBrowserFallback {
                Button("Open in Browser") {
                    Task {
                        self.failure = await model.openResultArtifact(failure.artifact, allowUnverifiedLink: true)
                    }
                }
            }
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(failure.message)
        }
    }
}

extension View {
    func resultArtifactOpenAlert(failure: Binding<ResultArtifactOpenFailure?>, model: HerdrAppModel) -> some View {
        modifier(ResultArtifactOpenAlert(failure: failure, model: model))
    }
}
