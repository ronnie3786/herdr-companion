import SwiftUI

struct ToastView: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        Button(action: dismiss) {
            Label(message, systemImage: "checkmark.circle.fill")
                .herdrFont(size: HerdrTheme.TextSize.body, weight: .medium)
                .foregroundStyle(HerdrTheme.text)
                .padding(.horizontal, 12)
                .frame(minHeight: HerdrTheme.ControlHeight.bar)
                .herdrCard(fill: HerdrTheme.base)
                // One floating toast may carry a shadow; lists never do.
                .shadow(color: .black.opacity(0.26), radius: 16, y: 8)
        }
        .buttonStyle(.plain)
        .task {
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }
}
