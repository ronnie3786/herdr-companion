import SwiftUI

extension View {
    /// macOS draws native prominent labels in white. A deeper lavender fill
    /// preserves contrast while keeping the native button's behavior.
    func herdrProminentButton() -> some View {
        buttonStyle(.borderedProminent)
            .tint(HerdrTheme.controlAccent)
    }
}
